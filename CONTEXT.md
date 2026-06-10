# Weekly ART Report — Контекст проекта

## Что это

Еженедельный HTML-отчёт по затраченному времени ART-отдела PSV Studio.
Данные берутся из Asana через Personal Access Token (PAT).

---

## Файлы в этой папке

| Файл | Назначение |
|---|---|
| `asana_pat.txt` | Personal Access Token Asana (одна строка) |
| `ART_report_YYYY-MM.html` | Готовые отчёты по месяцам |
| `may_time_data.json` | Кэш time_tracking_entries за май 2026 (129 задач) |
| `CONTEXT.md` | Этот файл |

---

## Как генерировать отчёт

1. Прочитать PAT из `asana_pat.txt`
2. Для каждого из 10 ART-проектов получить задачи: `GET /projects/{gid}/tasks?opt_fields=gid,name,memberships,memberships.project.gid,memberships.project.name`
3. Для фильтрации по периоду использовать PowerShell + PAT:
   ```powershell
   $headers = @{ Authorization = "Bearer <PAT>" }
   Invoke-RestMethod "https://app.asana.com/api/1.0/tasks/<GID>/time_tracking_entries?opt_fields=duration_minutes,entered_on" -Headers $headers
   ```
   Фильтровать по `entered_on` в нужном диапазоне дат.
4. Применить логику атрибуции (см. ниже)
5. Записать HTML: `ART_report_YYYY-MM.html`

---

## Портфель ART

**GID портфеля:** `1213829329062998`

### 10 проектов (проверенные GID)

| Проект | GID |
|---|---|
| 2D Art / UX/UI Design: Backlog | `1213598068805254` |
| 3D Art: Backlog | `1213598068805258` |
| VFX Art: Backlog | `1213599181255288` |
| Animations Art: Backlog | `1213599181255292` |
| ASO Icons | `1213910439454138` |
| ASO Screenshots | `1213910439713691` |
| ASO Custom Product Pages (CPP) | `1213911620513682` |
| ASO In App Events (Promo) | `1213911895502718` |
| Banner ADS | `1213993120177405` |
| CAS Requests | `1213879913329451` |

> ⚠️ Старые GID для ASO Icons (1213911620513680), ASO Screenshots (1213911620513681), Banner ADS (1213911620513683), CAS Requests (1213911620513684) — **не работают**, возвращают "not_found".

---

## Логика атрибуции задач

Задачи в Asana могут быть одновременно в нескольких проектах (multi-home).

**Правило:** учётный проект = первый проект задачи, который **НЕ входит** в ART-портфель.

**Примеры:**
- Задача в `2D Art Backlog` + `Brain Puzzle` → учитывается как **Brain Puzzle**
- Задача только в `ASO Icons` → **ASO Icons**
- Задача только в `3D Art Backlog` без внешнего проекта → смотреть имя задачи и родительскую задачу

**Особые случаи (выявлены в мае 2026):**

| Ситуация | Атрибуция |
|---|---|
| Подзадачи Level 1–6 в 2D Art Backlog | → **Brain Puzzle** (родитель: "Новые уровни брейнов (6 штук)") |
| Подзадачи Level 16–24 в 2D Art Backlog | → **Brain Puzzle** (родитель: "Подготовить для переноса уровни сторисов в брейн") |
| 3D Art Backlog задачи с родителем "Обновление Ночной карты" | → **Custom Club** |
| 3D Art Backlog задачи с `< DriveCSX >:` в имени | → **DriveCSX** |

---

## Формат отчёта (обязательный)

HTML-файл со следующими секциями:

1. **Header** — фиолетовый градиент `#667eea → #764ba2`, 4 stat-карточки: Часов / Задач / Проектов / Направлений ART
2. **Notice** — зелёный (time_tracking_entries, точный период) или жёлтый (накопленное время)
3. **Разбивка по направлениям ART** — dept-grid карточки
4. **Горизонтальная диаграмма** — dist-chart, отсортировано по убыванию часов
5. **Сводная таблица** — колонки: #, Проект, Направления ART (пиллы), **Задач**, Часов, %, Доля (мини-бар)
6. **Детализация** — коллапсируемые `<details>` на каждый проект, таблица: Задача / Направление / Исполнитель / Часов
7. **Footer** — дата генерации, источник, период

**Никаких минут** — только часы везде.

Эталонные файлы: `ART_report_2026-05.html`, `ART_report_2026-06.html`

---

## Итоги за май 2026

Период: 01.05.2026 – 31.05.2026 | Метод: time_tracking_entries API | Файл: `may_time_data.json`

| Проект | Часов | % |
|---|---|---|
| Brain Puzzle | 403.25 | 16.3% |
| Superhero Crime Open World War | 330.0 | 13.3% |
| Traffic Asphalt | 264.0 | 10.7% |
| Custom Club | 184.0 | 7.4% |
| Banner ADS | 169.0 | 6.8% |
| ASO In App Events | 166.0 | 6.7% |
| ASO Screenshots | 162.0 | 6.5% |
| ASO CPP | 147.0 | 5.9% |
| DriveCSX | 130.3 | 5.3% |
| ASO Icons | 124.0 | 5.0% |
| Tanks Merge | 122.0 | 4.9% |
| Business Empire Tycoon | 88.0 | 3.6% |
| Story Puzzle | 56.25 | 2.3% |
| Lazy Apocalipse | 32.0 | 1.3% |
| CAS Requests | 24.0 | 1.0% |
| Sniper Area | 24.0 | 1.0% |
| OverSpace | 20.0 | 0.8% |
| Speed Escape | 16.0 | 0.6% |
| Knockout | 8.0 | 0.3% |
| Alternative Store Release | 8.0 | 0.3% |
| **ИТОГО** | **2 477.8** | **100%** |

---

## Итоги за июнь 2026

Период: 01.06.2026 – 30.06.2026 | Метод: actual_time_minutes (накопленное) | Файл: `ART_report_2026-06.html`

**Итого: 2 687ч** — данные НЕ отфильтрованы по периоду (использовалось поле actual_time_minutes).

---

## Воркфлоу (полуавтомат)

1. Роман говорит: «сделай отчёт за [период]»
2. Claude читает PAT из `asana_pat.txt`
3. PowerShell → Asana API → time_tracking_entries (фильтр по дате)
4. Применить атрибуцию, посчитать часы
5. Записать `ART_report_YYYY-MM.html` в эту папку
6. Загрузить в Google Drive папку: `https://drive.google.com/drive/folders/1WStxZxipjN9vWdvfgHzOZZPGtx-IeSuj` (вручную или через Drive Desktop)
