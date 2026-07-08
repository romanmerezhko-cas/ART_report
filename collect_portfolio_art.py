# -*- coding: utf-8 -*-
"""
Сбор затрат времени по портфелю Active Portfolio Games (1213817629046220):
все проекты из 7 вложенных портфелей продюсеров -> задачи + подзадачи (рекурсивно)
-> time_tracking_entries за период, с автором записи (created_by).
ART-время = записи, внесённые участниками команды Art Team (1213453988877387).
Результат: portfolio_art_share_2026-04_07.json
"""
import json, pathlib, time, threading
import requests
from concurrent.futures import ThreadPoolExecutor, as_completed

BASE = "https://app.asana.com/api/1.0"
PAT = pathlib.Path(r"D:\project\weekly_ART_report\asana_pat.txt").read_text(encoding="utf-8").strip()
HEADERS = {"Authorization": f"Bearer {PAT}"}
ROOT_PORTFOLIO = "1213817629046220"
ART_TEAM = "1213453988877387"
START, END = "2026-04-01", "2026-07-31"
OUT = pathlib.Path(r"D:\project\weekly_ART_report\portfolio_art_share_2026-04_07.json")

_tls = threading.local()
def session():
    if not hasattr(_tls, "s"):
        _tls.s = requests.Session()
        _tls.s.headers.update(HEADERS)
    return _tls.s

def get(url, tries=6):
    for i in range(tries):
        r = session().get(url, timeout=60)
        if r.status_code == 429:
            wait = int(r.headers.get("Retry-After", "5"))
            time.sleep(min(wait, 60) + 1)
            continue
        if r.status_code >= 500:
            time.sleep(2 * (i + 1))
            continue
        r.raise_for_status()
        return r.json()
    raise RuntimeError(f"failed after retries: {url}")

def get_all(path_with_query):
    sep = "&" if "?" in path_with_query else "?"
    items, offset = [], None
    while True:
        url = f"{BASE}{path_with_query}{sep}limit=100"
        if offset:
            url += f"&offset={offset}"
        resp = get(url)
        items += resp["data"]
        nxt = resp.get("next_page")
        if not nxt:
            return items
        offset = nxt["offset"]

# ── 1. Art Team members ──────────────────────────────────────────────────────
art_users = get_all(f"/teams/{ART_TEAM}/users?opt_fields=name")
ART_GIDS = {u["gid"]: u["name"] for u in art_users}
print(f"Art Team: {len(ART_GIDS)} чел.", flush=True)

# ── 2. Проекты из вложенных портфелей ───────────────────────────────────────
projects = []          # {gid, name, producer}
sub_portfolios = get_all(f"/portfolios/{ROOT_PORTFOLIO}/items?opt_fields=name,resource_type")
for sp in sub_portfolios:
    if sp["resource_type"] == "portfolio":
        for it in get_all(f"/portfolios/{sp['gid']}/items?opt_fields=name,resource_type"):
            if it["resource_type"] == "project":
                projects.append({"gid": it["gid"], "name": it["name"], "producer": sp["name"]})
    elif sp["resource_type"] == "project":
        projects.append({"gid": sp["gid"], "name": sp["name"], "producer": "(корень)"})
# дедуп проектов
seen_p = set()
projects = [p for p in projects if not (p["gid"] in seen_p or seen_p.add(p["gid"]))]
print(f"Проектов: {len(projects)}", flush=True)

# ── 3. Задачи проектов + рекурсивно подзадачи ───────────────────────────────
TASK_FIELDS = "opt_fields=name,actual_time_minutes,num_subtasks"
tasks = {}             # gid -> {name, actual, project_gids:set}
tasks_lock = threading.Lock()

def add_task(t, proj_gid):
    with tasks_lock:
        rec = tasks.get(t["gid"])
        if rec is None:
            tasks[t["gid"]] = rec = {"name": t["name"], "actual": t.get("actual_time_minutes") or 0,
                                     "num_subtasks": t.get("num_subtasks") or 0, "projects": set()}
        rec["projects"].add(proj_gid)
        return rec

def fetch_project_tasks(p):
    return p, get_all(f"/projects/{p['gid']}/tasks?{TASK_FIELDS}")

def fetch_subtasks(gid):
    return get_all(f"/tasks/{gid}/subtasks?{TASK_FIELDS}")

with ThreadPoolExecutor(max_workers=6) as ex:
    for fut in as_completed([ex.submit(fetch_project_tasks, p) for p in projects]):
        p, ts = fut.result()
        for t in ts:
            add_task(t, p["gid"])
print(f"Задач верхнего уровня: {len(tasks)}", flush=True)

# рекурсивное раскрытие подзадач волнами
frontier = [g for g, r in tasks.items() if r["num_subtasks"] > 0]
depth = 0
while frontier:
    depth += 1
    new_frontier = []
    with ThreadPoolExecutor(max_workers=6) as ex:
        futs = {ex.submit(fetch_subtasks, g): g for g in frontier}
        for fut in as_completed(futs):
            parent = futs[fut]
            for st in fut.result():
                if st["gid"] in tasks:
                    continue
                # подзадача наследует проекты родителя
                for pg in tasks[parent]["projects"]:
                    add_task(st, pg)
                if (st.get("num_subtasks") or 0) > 0:
                    new_frontier.append(st["gid"])
    print(f"  уровень {depth}: +{len(new_frontier)} с подзадачами, всего задач {len(tasks)}", flush=True)
    frontier = new_frontier
print(f"Всего задач/подзадач: {len(tasks)}", flush=True)

# ── 4. time_tracking_entries для задач с actual_time_minutes > 0 ────────────
ENTRY_FIELDS = "opt_fields=duration_minutes,entered_on,created_by.gid,created_by.name"
with_time = [g for g, r in tasks.items() if r["actual"] > 0]
print(f"Задач с ненулевым временем: {len(with_time)}", flush=True)

entries = []           # {task, min, on, user_gid, user_name}
def fetch_entries(gid):
    out = []
    for e in get_all(f"/tasks/{gid}/time_tracking_entries?{ENTRY_FIELDS}"):
        on = e.get("entered_on")
        if on and START <= on <= END and e.get("duration_minutes"):
            cb = e.get("created_by") or {}
            out.append({"task": gid, "min": e["duration_minutes"], "on": on,
                        "user_gid": cb.get("gid"), "user_name": cb.get("name")})
    return out

done = 0
with ThreadPoolExecutor(max_workers=6) as ex:
    for fut in as_completed([ex.submit(fetch_entries, g) for g in with_time]):
        entries += fut.result()
        done += 1
        if done % 200 == 0:
            print(f"  entries: {done}/{len(with_time)} задач обработано", flush=True)
print(f"Записей времени в периоде {START}..{END}: {len(entries)}", flush=True)

# ── 5. Агрегация ─────────────────────────────────────────────────────────────
proj_by_gid = {p["gid"]: p for p in projects}
months = {}
by_project = {}
by_art_user = {}
for e in entries:
    m = e["on"][:7]
    is_art = e["user_gid"] in ART_GIDS
    mm = months.setdefault(m, {"total_min": 0, "art_min": 0})
    mm["total_min"] += e["min"]
    if is_art:
        mm["art_min"] += e["min"]
        u = by_art_user.setdefault(e["user_gid"], {"name": ART_GIDS[e["user_gid"]], "min": 0})
        u["min"] += e["min"]
    # по проектам: задача может быть в нескольких проектах портфеля — делим поровну не будем,
    # пишем в первый (стабильно по sorted), чтобы сумма по проектам сходилась с итогом
    pg = sorted(tasks[e["task"]]["projects"])[0]
    bp = by_project.setdefault(pg, {"name": proj_by_gid[pg]["name"], "producer": proj_by_gid[pg]["producer"],
                                    "total_min": 0, "art_min": 0})
    bp["total_min"] += e["min"]
    if is_art:
        bp["art_min"] += e["min"]

result = {
    "generated": time.strftime("%Y-%m-%d %H:%M"),
    "period": [START, END],
    "portfolio": {"gid": ROOT_PORTFOLIO, "name": "Active Portfolio Games"},
    "art_team_size": len(ART_GIDS),
    "n_projects": len(projects),
    "n_tasks": len(tasks),
    "n_entries": len(entries),
    "months": months,
    "by_project": by_project,
    "by_art_user": by_art_user,
    "projects": projects,
}
OUT.write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
print("SAVED", OUT, flush=True)
tot = sum(m["total_min"] for m in months.values())
art = sum(m["art_min"] for m in months.values())
print(f"ИТОГО: {tot/60:.1f} ч, из них ART {art/60:.1f} ч ({(art/tot*100 if tot else 0):.1f}%)", flush=True)
