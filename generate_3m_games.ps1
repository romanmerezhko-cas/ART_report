# Games Portfolio time-share report (Roman's correction 14.08.2026):
#   1. Roman Merezhko fully excluded (by GID, before any fetch - not just filtered out later)
#   2. Every member's task search is now bounded (modified_on.after AND .before) and, as a safety
#      net, adaptively splits the date range in half whenever a sub-query returns exactly 100 results
#      (Asana's tasks/search endpoint does not paginate past 100 - see CONTEXT.md). This replaces the
#      earlier "warn about capped data" workaround with an actual fix.
#   3. Portfolio scope switched from the ART department's internal pipeline portfolio to the real
#      Games Portfolio (GID 1213817629046220) - its 8 owner sub-portfolios are expanded into a flat
#      set of ~24 live game projects.
#   4. Subtasks in this workspace come back from search with EMPTY memberships (confirmed by sampling -
#      ~22% of tasks). Their project is inherited by climbing task.parent (cached, up to 5 levels) until
#      a task with non-empty memberships is found.
#
# All Russian UI text lives in labels_ru.json (read with -Encoding UTF8) - do not add literal Cyrillic
# directly to this script; PowerShell 5.1 misreads it (system ANSI codepage, no BOM on this file).

$ErrorActionPreference = "Stop"
$BASE = "D:\project\weekly_ART_report"
$htmlFile   = "$BASE\3m.html"
$jsonFile   = "$BASE\time_share_3m_games_data.json"
$labelsFile = "$BASE\labels_ru.json"

$Start         = "2026-05-01"
$End           = "2026-07-31"
# Task DISCOVERY window is bounded by TODAY, not by $End: a task's modified_on keeps advancing
# whenever anyone touches it (comment, status, reassignment) long after its time was logged, so
# bounding discovery at $End silently drops tasks re-touched after the report period (confirmed:
# it undercounted every employee's total hours by roughly 40-50% on the first run of this script).
# entered_on filtering below still strictly limits which time entries count toward $Start..$End -
# only task DISCOVERY needs the wider window. The >100-per-query cap is instead handled purely by
# the adaptive date-split in Get-TasksInRange.
$EndExclusive  = (Get-Date).AddDays(1).ToString('yyyy-MM-dd')
$Months        = @("2026-05","2026-06","2026-07")

$PAT     = (Get-Content "$BASE\asana_pat.txt" -Raw).Trim()
$headers = @{ Authorization = "Bearer $PAT" }
$apiBase = "https://app.asana.com/api/1.0"
$WS_GID  = "1210983682540893"

$labels = Get-Content $labelsFile -Raw -Encoding UTF8 | ConvertFrom-Json

function Invoke-AsanaGet([string]$url) {
    $maxRetries = 6
    for ($i = 0; $i -lt $maxRetries; $i++) {
        try {
            return Invoke-RestMethod -Uri $url -Headers $headers -Method Get
        } catch {
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -eq 429) {
                $wait = 8 * ($i + 1)
                Write-Host "    429 rate limited, waiting ${wait}s..."
                Start-Sleep -Seconds $wait
                continue
            } elseif (($status -ge 500 -or $null -eq $status) -and $i -lt ($maxRetries - 1)) {
                Start-Sleep -Seconds 3
                continue
            } else {
                throw
            }
        }
    }
}

Write-Host "=== Games Portfolio Time Share: $Start - $End ==="

# ------------------------------------------------------------
# 1. Games Portfolio -> flat set of live projects (2-level: portfolio -> owner sub-portfolios -> projects)
# ------------------------------------------------------------
$GAMES_PORTFOLIO_GID = "1213817629046220"
$projectMap = @{}
$topItems = (Invoke-AsanaGet "$apiBase/portfolios/$GAMES_PORTFOLIO_GID/items?opt_fields=gid,name,resource_type,archived&limit=100").data
foreach ($item in $topItems) {
    if ([bool]$item.archived) { continue }
    if ($item.resource_type -eq "project") {
        $projectMap[$item.gid] = $item.name
    } elseif ($item.resource_type -eq "portfolio") {
        $subItems = (Invoke-AsanaGet "$apiBase/portfolios/$($item.gid)/items?opt_fields=gid,name,resource_type,archived&limit=100").data
        foreach ($si in $subItems) {
            if ([bool]$si.archived) { continue }
            if ($si.resource_type -eq "project") { $projectMap[$si.gid] = $si.name }
        }
    }
}
$GAME_GID_SET = @{}
foreach ($g in $projectMap.Keys) { $GAME_GID_SET[$g] = $true }
Write-Host "[1] Games Portfolio: $($projectMap.Count) live projects"

# ------------------------------------------------------------
# 2. Art Team members, Roman Merezhko excluded by GID
# ------------------------------------------------------------
$TEAM_GID = "1213453988877387"
$EXCLUDED_GIDS = @{ "1213801882936520" = $true }  # Roman Merezhko
$teamMembers = [ordered]@{}
$respTeam = Invoke-AsanaGet "$apiBase/teams/$TEAM_GID/users?opt_fields=name&limit=100"
foreach ($u in $respTeam.data) {
    if ($EXCLUDED_GIDS.ContainsKey($u.gid)) { continue }
    $teamMembers[$u.gid] = $u.name
}
Write-Host "[2] Art Team members (Roman Merezhko excluded): $($teamMembers.Count)"

# ------------------------------------------------------------
# 3. Adaptive date-range task search (guarantees completeness past the 100-result cap)
# ------------------------------------------------------------
function Get-TasksInRange([string]$uGid, [string]$rangeStart, [string]$rangeEndExclusive, [hashtable]$acc, [int]$depth) {
    $url = "$apiBase/workspaces/$WS_GID/tasks/search?assignee.any=$uGid&modified_on.after=$rangeStart&modified_on.before=$rangeEndExclusive&opt_fields=gid,name,memberships.project.gid,memberships.project.name,permalink_url,parent.gid&limit=100"
    $r = Invoke-AsanaGet $url
    $items = @($r.data)
    if ($items.Count -eq 100 -and $depth -lt 12) {
        $sD = [datetime]::ParseExact($rangeStart,'yyyy-MM-dd',$null)
        $eD = [datetime]::ParseExact($rangeEndExclusive,'yyyy-MM-dd',$null)
        $spanDays = ($eD - $sD).Days
        if ($spanDays -le 1) {
            foreach ($t in $items) { $acc[$t.gid] = $t }
            Write-Host "    WARNING: $uGid hit 100 results on a single day ($rangeStart) - accepting as-is"
            return
        }
        $mid = $sD.AddDays([math]::Floor($spanDays / 2)).ToString('yyyy-MM-dd')
        Get-TasksInRange $uGid $rangeStart $mid $acc ($depth + 1)
        Get-TasksInRange $uGid $mid $rangeEndExclusive $acc ($depth + 1)
    } else {
        foreach ($t in $items) { $acc[$t.gid] = $t }
    }
}

# ------------------------------------------------------------
# 4. Subtask -> parent membership inheritance (cached)
# ------------------------------------------------------------
$parentCache = @{}
function Get-EffectiveMemberships($task) {
    if ($task.memberships -and @($task.memberships).Count -gt 0) { return $task.memberships }
    $climbGid = if ($task.parent) { $task.parent.gid } else { $null }
    $depth = 0
    while ($climbGid -and $depth -lt 5) {
        if (-not $parentCache.ContainsKey($climbGid)) {
            try {
                $pt = (Invoke-AsanaGet "$apiBase/tasks/$climbGid?opt_fields=memberships.project.gid,memberships.project.name,parent.gid").data
                $pMems = if ($pt.memberships) { $pt.memberships } else { @() }
                $pParentGid = if ($pt.parent) { $pt.parent.gid } else { $null }
                $parentCache[$climbGid] = @{ memberships = $pMems; parentGid = $pParentGid }
            } catch {
                $parentCache[$climbGid] = @{ memberships = @(); parentGid = $null }
            }
        }
        $cached = $parentCache[$climbGid]
        if (@($cached.memberships).Count -gt 0) { return $cached.memberships }
        $climbGid = $cached.parentGid
        $depth++
    }
    return @()
}

# ------------------------------------------------------------
# 5. Collect per member: tasks -> time_tracking_entries -> monthly buckets
# ------------------------------------------------------------
$perAssignee = [ordered]@{}
foreach ($mgid in $teamMembers.Keys) {
    $name = $teamMembers[$mgid]
    $perAssignee[$name] = [ordered]@{ months = [ordered]@{}; tasks = [System.Collections.Generic.List[object]]::new() }
    foreach ($mk in $Months) { $perAssignee[$name].months[$mk] = @{ total = 0.0; portfolio = 0.0 } }
}

$mi = 0
foreach ($mgid in $teamMembers.Keys) {
    $mi++
    $name = $teamMembers[$mgid]
    Write-Host "[3] ($mi/$($teamMembers.Count)) $name ..."

    $memberTasks = @{}
    Get-TasksInRange $mgid $Start $EndExclusive $memberTasks 0
    Write-Host "    tasks in range: $($memberTasks.Count)"

    $ti = 0
    foreach ($tgid in $memberTasks.Keys) {
        $ti++
        $t = $memberTasks[$tgid]
        $effMems = Get-EffectiveMemberships $t
        $isPortfolio = $false; $portfolioProjName = $null; $otherProjName = $null
        foreach ($m in $effMems) {
            if ($m.PSObject.Properties['project'] -and $m.project -and $GAME_GID_SET.ContainsKey([string]$m.project.gid)) {
                $isPortfolio = $true; $portfolioProjName = [string]$m.project.name; break
            }
        }
        if (-not $isPortfolio) {
            foreach ($m in $effMems) {
                if ($m.PSObject.Properties['project'] -and $m.project) { $otherProjName = [string]$m.project.name; break }
            }
        }
        $projName = if ($isPortfolio) { $portfolioProjName } elseif ($otherProjName) { $otherProjName } else { "" }

        try {
            $te = Invoke-AsanaGet "$apiBase/tasks/$tgid/time_tracking_entries?opt_fields=duration_minutes,entered_on&limit=100"
        } catch { continue }

        $monthMins = @{}
        foreach ($e in $te.data) {
            if (-not $e.entered_on) { continue }
            if ($e.entered_on -lt $Start -or $e.entered_on -gt $End) { continue }
            $mk = $e.entered_on.Substring(0,7)
            if (-not $monthMins.ContainsKey($mk)) { $monthMins[$mk] = 0.0 }
            $monthMins[$mk] += [double]$e.duration_minutes
        }
        foreach ($mk in $monthMins.Keys) {
            $mins = $monthMins[$mk]
            if ($mins -le 0) { continue }
            if (-not $perAssignee[$name].months.Contains($mk)) { continue }
            $perAssignee[$name].months[$mk].total += $mins
            if ($isPortfolio) { $perAssignee[$name].months[$mk].portfolio += $mins }
            [void]$perAssignee[$name].tasks.Add(@{
                name        = $t.name
                url         = $t.permalink_url
                month       = $mk
                project     = $projName
                isPortfolio = $isPortfolio
                hours       = [math]::Round($mins / 60.0, 2)
            })
        }
        if ($ti % 40 -eq 0) { Start-Sleep -Milliseconds 200 }
    }
}
Write-Host "[3] DONE collecting"

$snapshot = [ordered]@{}
foreach ($name in $perAssignee.Keys) {
    $snapshot[$name] = [ordered]@{ months = $perAssignee[$name].months; tasks = $perAssignee[$name].tasks }
}
$snapshot | ConvertTo-Json -Depth 10 | Out-File $jsonFile -Encoding utf8
Write-Host "Saved: $jsonFile"

# ------------------------------------------------------------
# 6. Aggregate + build HTML (Month -> Project -> Employee accordion)
# ------------------------------------------------------------
function Esc([string]$s) { $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
function Fmt([double]$h) { if ($h -eq [math]::Floor($h)) { "$([int]$h)" } else { "$([math]::Round($h,2))" } }
function MonthName([string]$mk) { $labels.monthNames.$mk }

$teamMonthTotal = @{}
foreach ($mk in $Months) { $teamMonthTotal[$mk] = 0.0 }
$employeeMonthTotal = @{}
foreach ($name in $perAssignee.Keys) {
    foreach ($mk in $Months) {
        $mt = $perAssignee[$name].months[$mk].total / 60.0
        $teamMonthTotal[$mk] += $mt
        $employeeMonthTotal["$name|$mk"] = $mt
    }
}

$monthProjects = @{}
foreach ($mk in $Months) { $monthProjects[$mk] = @{} }
$vacationTaskCount = 0
foreach ($name in $perAssignee.Keys) {
    foreach ($tk in $perAssignee[$name].tasks) {
        if ([string]$tk.project -like "*$($labels.vacationKeyword)*") { $vacationTaskCount++ }
        if (-not [bool]$tk.isPortfolio) { continue }
        $mk = [string]$tk.month
        $proj = [string]$tk.project
        if (-not $monthProjects[$mk].ContainsKey($proj)) { $monthProjects[$mk][$proj] = @{ hours = 0.0; employees = @{} } }
        $monthProjects[$mk][$proj].hours += [double]$tk.hours
        if (-not $monthProjects[$mk][$proj].employees.ContainsKey($name)) { $monthProjects[$mk][$proj].employees[$name] = 0.0 }
        $monthProjects[$mk][$proj].employees[$name] += [double]$tk.hours
    }
}

$portfolioEmployees = [System.Collections.Generic.HashSet[string]]::new()
foreach ($mk in $Months) { foreach ($proj in $monthProjects[$mk].Keys) { foreach ($e in $monthProjects[$mk][$proj].employees.Keys) { [void]$portfolioEmployees.Add($e) } } }

$teamTotalAll = 0.0; foreach ($mk in $Months) { $teamTotalAll += $teamMonthTotal[$mk] }
$teamTotalPortfolio = 0.0
foreach ($mk in $Months) { foreach ($proj in $monthProjects[$mk].Keys) { $teamTotalPortfolio += $monthProjects[$mk][$proj].hours } }
$teamOverallPct = if ($teamTotalAll -gt 0) { [math]::Round($teamTotalPortfolio / $teamTotalAll * 100, 1) } else { 0 }

$StartDisp = ([datetime]::ParseExact($Start,'yyyy-MM-dd',$null)).ToString('dd.MM.yyyy')
$EndDisp   = ([datetime]::ParseExact($End,  'yyyy-MM-dd',$null)).ToString('dd.MM.yyyy')

$L = [System.Collections.Generic.List[string]]::new()
[void]$L.Add('<!DOCTYPE html>')
[void]$L.Add('<html lang="ru">')
[void]$L.Add('<head>')
[void]$L.Add('<meta charset="UTF-8">')
[void]$L.Add('<title>' + (Esc $labels.title) + '</title>')
[void]$L.Add('<style>')
[void]$L.Add('* { box-sizing:border-box; margin:0; padding:0; }')
[void]$L.Add('body { font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:#f5f6fa; color:#2d3748; font-size:14px; }')
[void]$L.Add('.container { max-width:1100px; margin:0 auto; padding:24px; }')
[void]$L.Add('.header { background:linear-gradient(135deg,#667eea 0%,#764ba2 100%); color:white; border-radius:12px; padding:28px 32px; margin-bottom:24px; }')
[void]$L.Add('.header h1 { font-size:24px; font-weight:700; margin-bottom:6px; }')
[void]$L.Add('.header .meta { opacity:.85; font-size:13px; }')
[void]$L.Add('.header .stats { display:flex; gap:32px; margin-top:20px; flex-wrap:wrap; }')
[void]$L.Add('.stat { text-align:center; }')
[void]$L.Add('.stat-val { font-size:28px; font-weight:700; }')
[void]$L.Add('.stat-lbl { font-size:12px; opacity:.8; margin-top:2px; }')
[void]$L.Add('.notice-g { background:#f0fff4; border-left:4px solid #38a169; padding:12px 16px; border-radius:6px; margin-bottom:14px; font-size:13px; color:#276749; }')
[void]$L.Add('.notice-y { background:#fffbea; border-left:4px solid #d69e2e; padding:12px 16px; border-radius:6px; margin-bottom:24px; font-size:13px; color:#744210; }')
[void]$L.Add('.notice-y ul { margin:6px 0 0 18px; }')
[void]$L.Add('details.month-block { margin-bottom:12px; background:white; border-radius:12px; box-shadow:0 1px 3px rgba(0,0,0,.08); overflow:hidden; }')
[void]$L.Add('details.month-block > summary { cursor:pointer; padding:18px 24px; background:linear-gradient(135deg,#667eea 0%,#764ba2 100%); color:white; font-weight:700; font-size:17px; list-style:none; display:flex; align-items:center; justify-content:space-between; }')
[void]$L.Add('details.month-block > summary::-webkit-details-marker { display:none; }')
[void]$L.Add('details.month-block > summary .sub { font-size:13px; font-weight:400; opacity:.9; margin-top:4px; display:block; }')
[void]$L.Add('details.month-block > summary::after { content:"\25B8"; font-size:16px; }')
[void]$L.Add('details.month-block[open] > summary::after { content:"\25BE"; }')
[void]$L.Add('.month-body { padding:16px 24px 20px; }')
[void]$L.Add('details.project-block { margin-bottom:8px; border:1px solid #e2e8f0; border-radius:8px; overflow:hidden; }')
[void]$L.Add('details.project-block > summary { cursor:pointer; padding:12px 16px; background:#f7f8fc; font-weight:600; font-size:14px; list-style:none; display:flex; align-items:center; justify-content:space-between; gap:16px; }')
[void]$L.Add('details.project-block > summary::-webkit-details-marker { display:none; }')
[void]$L.Add('details.project-block > summary::after { content:"\25B8"; color:#a0aec0; font-size:12px; }')
[void]$L.Add('details.project-block[open] > summary::after { content:"\25BE"; }')
[void]$L.Add('.proj-name { flex:1; }')
[void]$L.Add('.proj-metrics { display:flex; align-items:center; gap:14px; flex-shrink:0; }')
[void]$L.Add('.proj-bar-wrap { width:140px; background:#edf2f7; border-radius:4px; height:10px; }')
[void]$L.Add('.proj-bar { height:10px; border-radius:4px; background:#667eea; }')
[void]$L.Add('.proj-hours { font-weight:700; color:#2d3748; min-width:70px; text-align:right; }')
[void]$L.Add('.proj-pct { color:#718096; font-weight:600; min-width:56px; text-align:right; }')
[void]$L.Add('.emp-table { width:100%; border-collapse:collapse; }')
[void]$L.Add('.emp-table th { background:#f0f4f8; padding:8px 14px; text-align:left; font-size:11px; color:#718096; text-transform:uppercase; letter-spacing:.4px; }')
[void]$L.Add('.emp-table td { padding:8px 14px; border-bottom:1px solid #f0f2f7; font-size:13px; }')
[void]$L.Add('.emp-table tr:hover td { background:#f7f8fc; }')
[void]$L.Add('.emp-table .hours { font-weight:700; text-align:right; }')
[void]$L.Add('.emp-table .pct { color:#718096; font-weight:600; text-align:right; }')
[void]$L.Add('.total-row td { font-weight:700; background:#f7f8fc; }')
[void]$L.Add('.no-activity { color:#a0aec0; font-size:13px; padding:8px 0; }')
[void]$L.Add('</style>')
[void]$L.Add('</head>')
[void]$L.Add('<body><div class="container">')

[void]$L.Add('<div class="header">')
[void]$L.Add('  <h1>' + (Esc $labels.title) + '</h1>')
[void]$L.Add('  <div class="meta">' + (Esc $labels.period) + ': ' + $StartDisp + ' &#8212; ' + $EndDisp + ' &nbsp;|&nbsp; ' + (Esc $labels.portfolio) + ': Games Portfolio (' + $projectMap.Count + ' ' + (Esc $labels.projectsWord) + ') &nbsp;|&nbsp; ' + (Esc $labels.team) + ': Art Team &nbsp;|&nbsp; ' + (Esc $labels.source) + ': Asana time_tracking_entries</div>')
[void]$L.Add('  <div class="stats">')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + (Fmt $teamTotalPortfolio) + '</div><div class="stat-lbl">' + (Esc $labels.statPortfolioHours) + '</div></div>')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + (Fmt $teamTotalAll) + '</div><div class="stat-lbl">' + (Esc $labels.statTeamHours) + '</div></div>')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + $teamOverallPct + '%</div><div class="stat-lbl">' + (Esc $labels.statShare) + '</div></div>')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + $portfolioEmployees.Count + '</div><div class="stat-lbl">' + (Esc $labels.statEmployees) + '</div></div>')
[void]$L.Add('  </div>')
[void]$L.Add('</div>')

[void]$L.Add('<div class="notice-g">&#9989; ' + (Esc $labels.noticeMethod) + '</div>')
[void]$L.Add('<div class="notice-y">&#9888;&#65039; <strong>' + (Esc $labels.caveatsTitle) + '</strong>')
[void]$L.Add('  <ul>')
[void]$L.Add('    <li><strong>' + $vacationTaskCount + '</strong> ' + (Esc $labels.caveatVacationMiddle) + ' <em>' + (Esc $labels.vacationProjectName) + '</em> &#8212; ' + (Esc $labels.caveatVacationSuffix) + '</li>')
[void]$L.Add('  </ul>')
[void]$L.Add('</div>')

foreach ($mk in $Months) {
    $mTotal = $teamMonthTotal[$mk]
    $projEntries = $monthProjects[$mk].GetEnumerator() | Sort-Object -Property @{Expression={$_.Value.hours}; Descending=$true}
    $mPortfolioHours = 0.0; foreach ($pe in $projEntries) { $mPortfolioHours += $pe.Value.hours }
    $mPct = if ($mTotal -gt 0) { [math]::Round($mPortfolioHours / $mTotal * 100, 1) } else { 0 }

    [void]$L.Add('<details class="month-block">')
    [void]$L.Add('  <summary>' + (MonthName $mk) + ' 2026<span class="sub">' + (Esc $labels.monthPortfolioLabel) + ': ' + (Fmt $mPortfolioHours) + ' &#1095; &mdash; ' + $mPct + '% ' + (Esc $labels.ofTeamTotalLabel) + ' (' + (Fmt $mTotal) + ' &#1095;)</span></summary>')
    [void]$L.Add('  <div class="month-body">')
    if (@($projEntries).Count -eq 0) {
        [void]$L.Add('    <div class="no-activity">' + (Esc $labels.noActivityLabel) + '</div>')
    }
    foreach ($pe in $projEntries) {
        $projName = $pe.Key
        $pHours   = $pe.Value.hours
        $pPct     = if ($mTotal -gt 0) { [math]::Round($pHours / $mTotal * 100, 1) } else { 0 }
        $barW     = if ($mPortfolioHours -gt 0) { [math]::Round($pHours / $mPortfolioHours * 100) } else { 0 }
        if ($barW -lt 3) { $barW = 3 }

        [void]$L.Add('    <details class="project-block">')
        [void]$L.Add('      <summary><span class="proj-name">' + (Esc $projName) + '</span><span class="proj-metrics"><span class="proj-bar-wrap"><span class="proj-bar" style="display:block;width:' + $barW + '%;"></span></span><span class="proj-hours">' + (Fmt $pHours) + ' &#1095;</span><span class="proj-pct">' + $pPct + '%</span></span></summary>')
        [void]$L.Add('      <table class="emp-table">')
        [void]$L.Add('        <thead><tr><th>' + (Esc $labels.colEmployee) + '</th><th style="text-align:right;">' + (Esc $labels.colHours) + '</th><th style="text-align:right;">' + (Esc $labels.colPctPersonal) + '</th></tr></thead>')
        [void]$L.Add('        <tbody>')
        $empEntries = $pe.Value.employees.GetEnumerator() | Sort-Object -Property @{Expression={$_.Value}; Descending=$true}
        foreach ($ee in $empEntries) {
            $eName  = $ee.Key
            $eHours = $ee.Value
            $eTotal = $employeeMonthTotal["$eName|$mk"]
            $ePct   = if ($eTotal -gt 0) { [math]::Round($eHours / $eTotal * 100, 1) } else { $null }
            $ePctDisp = if ($null -ne $ePct) { "$ePct%" } else { '&mdash;' }
            [void]$L.Add('          <tr><td>' + (Esc $eName) + '</td><td class="hours">' + (Fmt $eHours) + '</td><td class="pct">' + $ePctDisp + '</td></tr>')
        }
        [void]$L.Add('          <tr class="total-row"><td>' + (Esc $labels.totalProjectLabel) + '</td><td class="hours">' + (Fmt $pHours) + '</td><td></td></tr>')
        [void]$L.Add('        </tbody></table>')
        [void]$L.Add('    </details>')
    }
    [void]$L.Add('  </div>')
    [void]$L.Add('</details>')
}

$genDate = Get-Date -Format 'dd.MM.yyyy HH:mm'
[void]$L.Add('<div style="text-align:center;color:#a0aec0;font-size:12px;padding:24px 0">' + (Esc $labels.generatedLabel) + ': ' + $genDate + ' &nbsp;|&nbsp; Asana time_tracking_entries &nbsp;|&nbsp; ' + $StartDisp + ' &#8212; ' + $EndDisp + '</div>')
[void]$L.Add('</div></body></html>')

$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllLines($htmlFile, $L, $utf8)
Write-Host "=== DONE ==="
Write-Host "HTML: $htmlFile"
Write-Host "Team overall: $(Fmt $teamTotalPortfolio) / $(Fmt $teamTotalAll) h = $teamOverallPct% | employees with portfolio hours: $($portfolioEmployees.Count)"
