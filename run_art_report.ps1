param(
    [Parameter(Mandatory=$true)]  [string]$Start,
    [Parameter(Mandatory=$true)]  [string]$End,
    [string]$Label = ""
)

$ErrorActionPreference = "Stop"
$BASE = "D:\project\weekly_ART_report"

# Derive filenames and labels
$periodKey = $Start.Substring(0, 7)
$jsonFile  = "$BASE\time_data_$periodKey.json"
$htmlFile  = "$BASE\ART_report_$periodKey.html"

if (-not $Label) {
    $monthNames = @('January','February','March','April','May','June',
                    'July','August','September','October','November','December')
    $d = [datetime]::ParseExact($Start, 'yyyy-MM-dd', $null)
    $Label = "$($monthNames[$d.Month - 1]) $($d.Year)"
}
$StartDisp = ([datetime]::ParseExact($Start,'yyyy-MM-dd',$null)).ToString('dd.MM.yyyy')
$EndDisp   = ([datetime]::ParseExact($End,  'yyyy-MM-dd',$null)).ToString('dd.MM.yyyy')

Write-Host "=== ART Report: $Label ($StartDisp - $EndDisp) ==="
Write-Host "JSON: $jsonFile"
Write-Host "HTML: $htmlFile"

# PAT and API setup
$PAT     = (Get-Content "$BASE\asana_pat.txt" -Raw).Trim()
$headers = @{ Authorization = "Bearer $PAT" }
$apiBase = "https://app.asana.com/api/1.0"

$ART_GIDs = @(
    "1213598068805254",
    "1213598068805258",
    "1213599181255288",
    "1213599181255292",
    "1213910439454138",
    "1213910439713691",
    "1213911620513682",
    "1213911895502718",
    "1213993120177405",
    "1213879913329451"
)
$ART_DIRECTION = @{
    "1213598068805254"="2D Art / UI"; "1213598068805258"="3D Art"
    "1213599181255288"="VFX";         "1213599181255292"="Animations"
    "1213910439454138"="ASO Icons";   "1213910439713691"="ASO Screenshots"
    "1213911620513682"="ASO CPP";     "1213911895502718"="ASO In App Events"
    "1213993120177405"="Banner ADS";  "1213879913329451"="CAS Requests"
}
$ART_GID_SET = @{}
foreach ($g in $ART_GIDs) { $ART_GID_SET[$g] = $true }

# ============================================================
# STEP 1 - Collect tasks from 10 ART projects
# ============================================================
Write-Host "`n[1/3] Collecting tasks from 10 ART projects..."
$allTasks = @{}

foreach ($projGid in $ART_GIDs) {
    $offset   = $null
    $newCount = 0
    do {
        $url = "$apiBase/projects/$projGid/tasks?opt_fields=gid,name,assignee.name,memberships.project.gid,memberships.project.name,permalink_url&limit=100"
        if ($offset) { $url += "&offset=$offset" }
        try {
            $resp = Invoke-RestMethod $url -Headers $headers
            foreach ($task in $resp.data) {
                if (-not $allTasks.ContainsKey($task.gid)) {
                    $mems = @()
                    if ($task.memberships) {
                        foreach ($m in $task.memberships) {
                            if ($m.PSObject.Properties['project'] -and $m.project -and $m.project.gid) {
                                $mems += @{ gid=[string]$m.project.gid; name=[string]$m.project.name }
                            }
                        }
                    }
                    $allTasks[$task.gid] = @{
                        name          = $task.name
                        assignee      = if ($task.PSObject.Properties['assignee'] -and $task.assignee -and $task.assignee.name) { $task.assignee.name } else { "Unassigned" }
                        permalink_url = if ($task.PSObject.Properties['permalink_url']) { $task.permalink_url } else { "" }
                        memberships   = $mems
                    }
                    $newCount++
                }
            }
            $offset = if ($resp.next_page -and $resp.next_page.offset) { $resp.next_page.offset } else { $null }
        } catch {
            Write-Host "  ERROR project $projGid : $_"
            $offset = $null
        }
    } while ($offset)
    Write-Host "  $($ART_DIRECTION[$projGid]): +$newCount  (total: $($allTasks.Count))"
}
Write-Host "Total unique tasks: $($allTasks.Count)"

# ============================================================
# STEP 2 - Get time_tracking_entries filtered by period
# ============================================================
Write-Host "`n[2/3] Fetching time entries for $StartDisp - $EndDisp ..."
$taskMinutes = @{}
$i = 0
foreach ($gid in @($allTasks.Keys)) {
    $i++
    if ($i % 50 -eq 0) { Write-Host "  [$i / $($allTasks.Count)]..." }
    try {
        $url  = "$apiBase/tasks/$gid/time_tracking_entries?opt_fields=duration_minutes,entered_on&limit=100"
        $resp = Invoke-RestMethod $url -Headers $headers
        $tot  = 0
        foreach ($e in $resp.data) {
            if ($e.entered_on -and $e.entered_on -ge $Start -and $e.entered_on -le $End) {
                $tot += [int]$e.duration_minutes
            }
        }
        if ($tot -gt 0) { $taskMinutes[$gid] = $tot }
    } catch {}
}
Write-Host "Tasks with tracked time in period: $($taskMinutes.Count)"

# Attribute tasks to projects
Write-Host "[3/3] Attributing and saving JSON..."
$processed = @{}
foreach ($gid in $taskMinutes.Keys) {
    $task = $allTasks[$gid]
    $artDir = "Unknown"
    foreach ($m in $task.memberships) {
        if ($ART_DIRECTION.ContainsKey($m.gid)) { $artDir = $ART_DIRECTION[$m.gid]; break }
    }
    $attrProject = $null
    foreach ($m in $task.memberships) {
        if (-not $ART_GID_SET.ContainsKey($m.gid)) { $attrProject = $m.name; break }
    }
    if (-not $attrProject) {
        foreach ($m in $task.memberships) {
            if ($ART_GID_SET.ContainsKey($m.gid)) { $attrProject = $m.name; break }
        }
    }
    if (-not $attrProject) { $attrProject = "Unknown" }

    $processed[$gid] = @{
        name               = $task.name
        assignee           = $task.assignee
        permalink_url      = $task.permalink_url
        art_direction      = $artDir
        attributed_project = $attrProject
        minutes            = $taskMinutes[$gid]
        hours              = [math]::Round($taskMinutes[$gid] / 60, 2)
    }
}
$processed | ConvertTo-Json -Depth 10 | Out-File $jsonFile -Encoding utf8
Write-Host "Saved: $jsonFile  ($($processed.Count) tasks)"

# ============================================================
# STEP 4 - Generate HTML
# ============================================================
Write-Host "`n[4/4] Generating HTML report..."

$rawJson = Get-Content $jsonFile -Raw -Encoding utf8
$dataObj = $rawJson | ConvertFrom-Json
$tasks2  = @{}
foreach ($prop in $dataObj.PSObject.Properties) {
    $t = $prop.Value
    $tasks2[$prop.Name] = @{
        name               = [string]$t.name
        assignee           = [string]$t.assignee
        permalink_url      = [string]$t.permalink_url
        art_direction      = [string]$t.art_direction
        attributed_project = [string]$t.attributed_project
        hours              = [double]$t.hours
    }
}

function Esc([string]$s) { $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
function Clean-Project([string]$name) {
    $c = $name -replace '\s*:?\s*\[[^\]]*\]','' -replace '\s*\([^\)]*\)\s*$',''
    $c = $c.Trim()
    if ($c -eq 'ASO Custom Product Pages') { return 'ASO CPP' }
    return $c
}
function Art-Pill([string]$dir) {
    switch ($dir) {
        '2D Art / UI'       { '<span class="art-pill art-2d">2D Art</span>' }
        '3D Art'            { '<span class="art-pill art-3d">3D Art</span>' }
        'VFX'               { '<span class="art-pill art-vfx">VFX</span>' }
        'Animations'        { '<span class="art-pill art-anim">Anim</span>' }
        'ASO Icons'         { '<span class="art-pill art-aso">ASO Icons</span>' }
        'ASO Screenshots'   { '<span class="art-pill art-aso">ASO SS</span>' }
        'ASO CPP'           { '<span class="art-pill art-aso">ASO CPP</span>' }
        'ASO In App Events' { '<span class="art-pill art-aso">ASO Events</span>' }
        'Banner ADS'        { '<span class="art-pill art-ban">Banner</span>' }
        'CAS Requests'      { '<span class="art-pill art-cas">CAS</span>' }
        default             { '<span class="art-pill">' + (Esc $dir) + '</span>' }
    }
}
function Fmt([double]$h) {
    if ($h -eq [math]::Floor($h)) { "$([int]$h)" } else { "$([math]::Round($h,2))" }
}

# Aggregate
$byProject   = @{}
$byDirection = @{}
$byAssignee  = @{}
foreach ($gid in $tasks2.Keys) {
    $t    = $tasks2[$gid]
    $proj = Clean-Project $t.attributed_project
    $dir  = $t.art_direction
    $who  = $t.assignee
    if (-not $byProject.ContainsKey($proj)) {
        $byProject[$proj] = @{ tasks=[System.Collections.Generic.List[object]]::new(); hours=0.0; dirs=@{} }
    }
    $byProject[$proj].tasks.Add(@{gid=$gid;name=$t.name;assignee=$t.assignee;url=$t.permalink_url;dir=$dir;hours=$t.hours})
    $byProject[$proj].hours += $t.hours
    $byProject[$proj].dirs[$dir] = 1
    if (-not $byDirection.ContainsKey($dir)) { $byDirection[$dir] = 0.0 }
    $byDirection[$dir] += $t.hours
    if (-not $byAssignee.ContainsKey($who)) {
        $byAssignee[$who] = @{ tasks=[System.Collections.Generic.List[object]]::new(); hours=0.0 }
    }
    $byAssignee[$who].tasks.Add(@{gid=$gid;name=$t.name;url=$t.permalink_url;dir=$dir;hours=$t.hours;proj=$proj})
    $byAssignee[$who].hours += $t.hours
}

$totalH    = 0.0
foreach ($g in $tasks2.Keys) { $totalH += $tasks2[$g].hours }
$totalT    = $tasks2.Count
$totalP    = $byProject.Count
$totalD    = $byDirection.Count
$totalHInt = [math]::Round($totalH)

$sortedProj      = $byProject.GetEnumerator()  | Sort-Object { $_.Value.hours } -Descending
$sortedAssignees = $byAssignee.GetEnumerator() | Sort-Object { $_.Value.hours } -Descending
$maxH = 0.0
foreach ($v in $byProject.Values) { if ($v.hours -gt $maxH) { $maxH = $v.hours } }

$deptOrder = @('3D Art','2D Art / UI','Animations','VFX','CAS Requests',
               'ASO Screenshots','ASO Icons','ASO CPP','ASO In App Events','Banner ADS')
$barColors = @('#667eea','#764ba2','#f093fb','#4facfe','#f5576c','#fd746c','#43e97b',
               '#fa709a','#30cfd0','#a8edea','#feb692','#96fbc4','#5ee7df','#b490ca','#fda085')

# Build HTML
$L = [System.Collections.Generic.List[string]]::new()

[void]$L.Add('<!DOCTYPE html>')
[void]$L.Add('<html lang="ru">')
[void]$L.Add('<head>')
[void]$L.Add('<meta charset="UTF-8">')
[void]$L.Add('<title>ART Department Report &#8212; ' + $Label + '</title>')
[void]$L.Add('<style>')
[void]$L.Add('* { box-sizing:border-box; margin:0; padding:0; }')
[void]$L.Add('body { font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:#f5f6fa; color:#2d3748; font-size:14px; }')
[void]$L.Add('.container { max-width:1200px; margin:0 auto; padding:24px; }')
[void]$L.Add('.header { background:linear-gradient(135deg,#667eea 0%,#764ba2 100%); color:white; border-radius:12px; padding:28px 32px; margin-bottom:24px; }')
[void]$L.Add('.header h1 { font-size:24px; font-weight:700; margin-bottom:6px; }')
[void]$L.Add('.header .meta { opacity:.85; font-size:13px; }')
[void]$L.Add('.header .stats { display:flex; gap:32px; margin-top:20px; flex-wrap:wrap; }')
[void]$L.Add('.stat { text-align:center; }')
[void]$L.Add('.stat-val { font-size:28px; font-weight:700; }')
[void]$L.Add('.stat-lbl { font-size:12px; opacity:.8; margin-top:2px; }')
[void]$L.Add('.notice-g { background:#f0fff4; border-left:4px solid #38a169; padding:12px 16px; border-radius:6px; margin-bottom:24px; font-size:13px; color:#276749; }')
[void]$L.Add('.section-title { font-size:16px; font-weight:700; color:#4a5568; margin-bottom:12px; display:flex; align-items:center; gap:8px; }')
[void]$L.Add('.section-title::before { content:""; display:block; width:4px; height:18px; background:#667eea; border-radius:2px; }')
[void]$L.Add('.card { background:white; border-radius:12px; padding:20px 24px; margin-bottom:24px; box-shadow:0 1px 3px rgba(0,0,0,.08); }')
[void]$L.Add('.summary-table { width:100%; border-collapse:collapse; }')
[void]$L.Add('.summary-table th { background:#f7f8fc; text-align:left; padding:10px 14px; font-weight:600; font-size:12px; color:#718096; text-transform:uppercase; letter-spacing:.5px; border-bottom:2px solid #e2e8f0; }')
[void]$L.Add('.summary-table td { padding:10px 14px; border-bottom:1px solid #f0f2f7; vertical-align:middle; }')
[void]$L.Add('.summary-table tr:hover td { background:#f7f8fc; }')
[void]$L.Add('.bar-wrap { width:100%; background:#edf2f7; border-radius:4px; height:8px; min-width:80px; }')
[void]$L.Add('.bar { height:8px; border-radius:4px; background:#667eea; }')
[void]$L.Add('.badge { display:inline-block; padding:2px 8px; border-radius:10px; font-size:11px; font-weight:600; }')
[void]$L.Add('.rank-1 { color:#744210; background:#fefcbf; } .rank-2 { color:#1a365d; background:#bee3f8; } .rank-3 { color:#22543d; background:#c6f6d5; }')
[void]$L.Add('.hours { font-weight:700; font-size:15px; color:#2d3748; }')
[void]$L.Add('.pct { font-weight:600; color:#718096; font-size:13px; }')
[void]$L.Add('.art-types { display:flex; flex-wrap:wrap; gap:4px; }')
[void]$L.Add('.art-pill { display:inline-block; padding:1px 7px; border-radius:8px; font-size:11px; font-weight:500; }')
[void]$L.Add('.art-2d { background:#e9d8fd; color:#553c9a; }')
[void]$L.Add('.art-3d { background:#bee3f8; color:#2a69ac; }')
[void]$L.Add('.art-vfx { background:#c6f6d5; color:#276749; }')
[void]$L.Add('.art-anim { background:#feebc8; color:#7b341e; }')
[void]$L.Add('.art-aso { background:#fed7e2; color:#97266d; }')
[void]$L.Add('.art-ban { background:#e2e8f0; color:#4a5568; }')
[void]$L.Add('.art-cas { background:#e6fffa; color:#234e52; }')
[void]$L.Add('.dist-chart { display:flex; flex-direction:column; gap:10px; }')
[void]$L.Add('.dist-row { display:flex; align-items:center; gap:12px; }')
[void]$L.Add('.dist-label { width:240px; font-size:13px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; flex-shrink:0; }')
[void]$L.Add('.dist-bar-wrap { flex:1; background:#edf2f7; border-radius:4px; height:20px; }')
[void]$L.Add('.dist-bar { height:20px; border-radius:4px; display:flex; align-items:center; padding-left:8px; font-size:11px; color:white; font-weight:600; white-space:nowrap; min-width:36px; }')
[void]$L.Add('.dist-val { width:70px; text-align:right; font-size:12px; color:#718096; flex-shrink:0; }')
[void]$L.Add('.dept-grid { display:grid; grid-template-columns:repeat(5,1fr); gap:12px; }')
[void]$L.Add('.dept-card { background:#f7f8fc; border-radius:8px; padding:16px; text-align:center; border:1px solid #e2e8f0; }')
[void]$L.Add('.dept-card .dept-name { font-size:12px; font-weight:600; color:#718096; text-transform:uppercase; letter-spacing:.5px; margin-bottom:8px; }')
[void]$L.Add('.dept-card .dept-hours { font-size:24px; font-weight:700; color:#2d3748; }')
[void]$L.Add('.dept-card .dept-pct { font-size:12px; color:#a0aec0; margin-top:2px; }')
[void]$L.Add('details { margin-bottom:8px; }')
[void]$L.Add('details summary { cursor:pointer; padding:10px 14px; background:#f7f8fc; border-radius:8px; font-weight:600; font-size:13px; list-style:none; display:flex; align-items:center; justify-content:space-between; border:1px solid #e2e8f0; }')
[void]$L.Add('details summary::-webkit-details-marker { display:none; }')
[void]$L.Add('details summary::after { content:"\25B8"; color:#a0aec0; font-size:12px; }')
[void]$L.Add('details[open] summary::after { content:"\25BE"; }')
[void]$L.Add('details[open] summary { border-radius:8px 8px 0 0; }')
[void]$L.Add('.detail-content { border:1px solid #e2e8f0; border-top:none; border-radius:0 0 8px 8px; overflow:hidden; }')
[void]$L.Add('.detail-table { width:100%; border-collapse:collapse; }')
[void]$L.Add('.detail-table th { background:#f0f4f8; padding:8px 12px; text-align:left; font-size:11px; color:#718096; text-transform:uppercase; letter-spacing:.4px; }')
[void]$L.Add('.detail-table td { padding:8px 12px; border-bottom:1px solid #f0f2f7; font-size:13px; }')
[void]$L.Add('.detail-table tr:hover td { background:#f7f8fc; }')
[void]$L.Add('.task-link { color:#5a67d8; text-decoration:none; }')
[void]$L.Add('.task-link:hover { text-decoration:underline; }')
[void]$L.Add('.total-row td { font-weight:700; background:#f7f8fc; }')
[void]$L.Add('.artist-stat { font-size:12px; color:#718096; font-weight:400; }')
[void]$L.Add('@media(max-width:900px){ .dept-grid{ grid-template-columns:repeat(3,1fr); } }')
[void]$L.Add('@media(max-width:600px){ .dept-grid{ grid-template-columns:repeat(2,1fr); } .dist-label{ width:130px; } }')
[void]$L.Add('</style>')
[void]$L.Add('</head>')
[void]$L.Add('<body><div class="container">')

# Header
[void]$L.Add('<div class="header">')
[void]$L.Add('  <h1>ART Department &#8212; &#1054;&#1090;&#1095;&#1105;&#1090; &#1087;&#1086; &#1079;&#1072;&#1076;&#1072;&#1095;&#1072;&#1084;</h1>')
[void]$L.Add('  <div class="meta">&#1055;&#1077;&#1088;&#1080;&#1086;&#1076;: ' + $StartDisp + ' &#8212; ' + $EndDisp + ' &nbsp;|&nbsp; &#1055;&#1086;&#1088;&#1090;&#1092;&#1077;&#1083;&#1100;: ART Portfolio &nbsp;|&nbsp; &#1048;&#1089;&#1090;&#1086;&#1095;&#1085;&#1080;&#1082;: Asana time_tracking_entries</div>')
[void]$L.Add('  <div class="stats">')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + $totalHInt + '</div><div class="stat-lbl">&#1063;&#1072;&#1089;&#1086;&#1074; (' + $Label + ')</div></div>')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + $totalT + '</div><div class="stat-lbl">&#1047;&#1072;&#1076;&#1072;&#1095; &#1089; &#1090;&#1088;&#1077;&#1082;&#1080;&#1085;&#1075;&#1086;&#1084;</div></div>')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + $totalP + '</div><div class="stat-lbl">&#1055;&#1088;&#1086;&#1077;&#1082;&#1090;&#1086;&#1074;</div></div>')
[void]$L.Add('    <div class="stat"><div class="stat-val">' + $totalD + '</div><div class="stat-lbl">&#1053;&#1072;&#1087;&#1088;&#1072;&#1074;&#1083;&#1077;&#1085;&#1080;&#1081; ART</div></div>')
[void]$L.Add('  </div>')
[void]$L.Add('</div>')

# Notice
[void]$L.Add('<div class="notice-g">&#9989; <strong>&#1044;&#1072;&#1085;&#1085;&#1099;&#1077; &#1086;&#1090;&#1092;&#1080;&#1083;&#1100;&#1090;&#1088;&#1086;&#1074;&#1072;&#1085;&#1099; &#1095;&#1077;&#1088;&#1077;&#1079; Asana time_tracking_entries API.</strong> &#1060;&#1080;&#1083;&#1100;&#1090;&#1088; &#1087;&#1086; <em>entered_on</em>: ' + $StartDisp + ' &#8212; ' + $EndDisp + '.</div>')

# Dept grid
[void]$L.Add('<div class="card">')
[void]$L.Add('  <div class="section-title">&#1056;&#1072;&#1079;&#1073;&#1080;&#1074;&#1082;&#1072; &#1087;&#1086; &#1085;&#1072;&#1087;&#1088;&#1072;&#1074;&#1083;&#1077;&#1085;&#1080;&#1103;&#1084; ART</div>')
[void]$L.Add('  <div class="dept-grid">')
foreach ($dir in $deptOrder) {
    $dh   = if ($byDirection.ContainsKey($dir)) { $byDirection[$dir] } else { 0.0 }
    $dpct = [math]::Round($dh / $totalH * 100, 1)
    $dhd  = Fmt $dh
    [void]$L.Add('    <div class="dept-card"><div class="dept-name">' + (Esc $dir) + '</div><div class="dept-hours">' + $dhd + ' &#1095;</div><div class="dept-pct">' + $dpct + '% &#1086;&#1090; &#1086;&#1073;&#1097;&#1077;&#1075;&#1086;</div></div>')
}
[void]$L.Add('  </div>')
[void]$L.Add('</div>')

# Distribution chart
[void]$L.Add('<div class="card">')
[void]$L.Add('  <div class="section-title">&#1056;&#1072;&#1089;&#1087;&#1088;&#1077;&#1076;&#1077;&#1083;&#1077;&#1085;&#1080;&#1077; &#1087;&#1086; &#1091;&#1095;&#1105;&#1090;&#1085;&#1099;&#1084; &#1087;&#1088;&#1086;&#1077;&#1082;&#1090;&#1072;&#1084;</div>')
[void]$L.Add('  <div class="dist-chart">')
$ci = 0
foreach ($kv in $sortedProj) {
    $ph   = $kv.Value.hours
    $ppct = [math]::Round($ph / $totalH * 100, 1)
    $barW = [math]::Round($ph / $maxH * 100)
    $col  = $barColors[$ci % $barColors.Count]
    $phd  = Fmt $ph
    [void]$L.Add('    <div class="dist-row"><div class="dist-label">' + (Esc $kv.Key) + '</div><div class="dist-bar-wrap"><div class="dist-bar" style="width:' + $barW + '%;background:' + $col + ';">' + $ppct + '%</div></div><div class="dist-val">' + $phd + ' &#1095;</div></div>')
    $ci++
}
[void]$L.Add('  </div>')
[void]$L.Add('</div>')

# Summary table
[void]$L.Add('<div class="card">')
[void]$L.Add('  <div class="section-title">&#1057;&#1074;&#1086;&#1076;&#1085;&#1072;&#1103; &#1090;&#1072;&#1073;&#1083;&#1080;&#1094;&#1072; &#1087;&#1086; &#1087;&#1088;&#1086;&#1077;&#1082;&#1090;&#1072;&#1084;</div>')
[void]$L.Add('  <table class="summary-table">')
[void]$L.Add('    <thead><tr><th>#</th><th>&#1055;&#1088;&#1086;&#1077;&#1082;&#1090; (&#1091;&#1095;&#1105;&#1090;&#1085;&#1099;&#1081;)</th><th>&#1053;&#1072;&#1087;&#1088;&#1072;&#1074;&#1083;&#1077;&#1085;&#1080;&#1103; ART</th><th>&#1047;&#1072;&#1076;&#1072;&#1095;</th><th>&#1063;&#1072;&#1089;&#1086;&#1074;</th><th>%</th><th>&#1044;&#1086;&#1083;&#1103;</th></tr></thead>')
[void]$L.Add('    <tbody>')
$ri = 0; $sumT = 0; $sumH = 0.0
foreach ($kv in $sortedProj) {
    $ri++
    $ph     = $kv.Value.hours
    $ptasks = $kv.Value.tasks.Count
    $sumT  += $ptasks
    $sumH  += $ph
    $ppct   = [math]::Round($ph / $totalH * 100, 1)
    $barW   = [math]::Round($ph / $maxH * 100)
    $phd    = Fmt $ph
    $rankBadge = switch ($ri) {
        1 { '<span class="badge rank-1">1</span>' }
        2 { '<span class="badge rank-2">2</span>' }
        3 { '<span class="badge rank-3">3</span>' }
        default { "$ri" }
    }
    $pillsHtml = ($kv.Value.dirs.Keys | ForEach-Object { Art-Pill $_ }) -join ' '
    [void]$L.Add('      <tr><td>' + $rankBadge + '</td><td><strong>' + (Esc $kv.Key) + '</strong></td><td><div class="art-types">' + $pillsHtml + '</div></td><td>' + $ptasks + '</td><td class="hours">' + $phd + '</td><td class="pct">' + $ppct + '%</td><td><div class="bar-wrap"><div class="bar" style="width:' + $barW + '%"></div></div></td></tr>')
}
[void]$L.Add('      <tr class="total-row"><td></td><td>&#1048;&#1058;&#1054;&#1043;&#1054;</td><td></td><td>' + $sumT + '</td><td class="hours">' + (Fmt $sumH) + '</td><td class="pct">100%</td><td></td></tr>')
[void]$L.Add('    </tbody></table>')
[void]$L.Add('</div>')

# Details by project
[void]$L.Add('<div class="card">')
[void]$L.Add('  <div class="section-title">&#1044;&#1077;&#1090;&#1072;&#1083;&#1080;&#1079;&#1072;&#1094;&#1080;&#1103; &#1079;&#1072;&#1076;&#1072;&#1095; &#1087;&#1086; &#1087;&#1088;&#1086;&#1077;&#1082;&#1090;&#1072;&#1084;</div>')
foreach ($kv in $sortedProj) {
    $ph     = $kv.Value.hours
    $ptasks = $kv.Value.tasks.Count
    $ppct   = [math]::Round($ph / $totalH * 100, 1)
    $phd    = Fmt $ph
    [void]$L.Add('  <details>')
    [void]$L.Add('    <summary>' + (Esc $kv.Key) + '&nbsp;&nbsp;<span style="color:#718096;font-weight:400">' + $phd + ' &#1095; &mdash; ' + $ppct + '% &mdash; ' + $ptasks + ' &#1079;&#1072;&#1076;&#1072;&#1095;</span></summary>')
    [void]$L.Add('    <div class="detail-content"><table class="detail-table">')
    [void]$L.Add('      <thead><tr><th>&#1047;&#1072;&#1076;&#1072;&#1095;&#1072;</th><th>&#1053;&#1072;&#1087;&#1088;&#1072;&#1074;&#1083;&#1077;&#1085;&#1080;&#1077;</th><th>&#1048;&#1089;&#1087;&#1086;&#1083;&#1085;&#1080;&#1090;&#1077;&#1083;&#1100;</th><th>&#1063;&#1072;&#1089;&#1086;&#1074;</th></tr></thead>')
    [void]$L.Add('      <tbody>')
    foreach ($tk in ($kv.Value.tasks | Sort-Object { $_.hours } -Descending)) {
        [void]$L.Add('        <tr><td><a class="task-link" href="' + $tk.url + '" target="_blank">' + (Esc $tk.name) + '</a></td><td>' + (Art-Pill $tk.dir) + '</td><td>' + (Esc $tk.assignee) + '</td><td class="hours">' + (Fmt $tk.hours) + '</td></tr>')
    }
    [void]$L.Add('        <tr class="total-row"><td colspan="3">&#1048;&#1090;&#1086;&#1075;&#1086;: ' + (Esc $kv.Key) + '</td><td>' + $phd + '</td></tr>')
    [void]$L.Add('      </tbody></table></div>')
    [void]$L.Add('  </details>')
}
[void]$L.Add('</div>')

# Artists section
[void]$L.Add('<div class="card">')
[void]$L.Add('  <div class="section-title">&#1056;&#1072;&#1089;&#1087;&#1088;&#1077;&#1076;&#1077;&#1083;&#1077;&#1085;&#1080;&#1077; &#1088;&#1072;&#1073;&#1086;&#1090; &#1087;&#1086; &#1093;&#1091;&#1076;&#1086;&#1078;&#1085;&#1080;&#1082;&#1072;&#1084;</div>')
foreach ($kv in $sortedAssignees) {
    $ah     = $kv.Value.hours
    $atasks = $kv.Value.tasks.Count
    $apct   = [math]::Round($ah / $totalH * 100, 1)
    $ahd    = Fmt $ah
    [void]$L.Add('  <details>')
    [void]$L.Add('    <summary>' + (Esc $kv.Key) + '&nbsp;&nbsp;<span class="artist-stat">' + $ahd + ' &#1095; &mdash; ' + $apct + '% &mdash; ' + $atasks + ' &#1079;&#1072;&#1076;&#1072;&#1095;</span></summary>')
    [void]$L.Add('    <div class="detail-content"><table class="detail-table">')
    [void]$L.Add('      <thead><tr><th>&#1047;&#1072;&#1076;&#1072;&#1095;&#1072;</th><th>&#1053;&#1072;&#1087;&#1088;&#1072;&#1074;&#1083;&#1077;&#1085;&#1080;&#1077;</th><th>&#1055;&#1088;&#1086;&#1077;&#1082;&#1090;</th><th>&#1063;&#1072;&#1089;&#1086;&#1074;</th><th>%</th></tr></thead>')
    [void]$L.Add('      <tbody>')
    foreach ($tk in ($kv.Value.tasks | Sort-Object { $_.hours } -Descending)) {
        $tpct = [math]::Round($tk.hours / $ah * 100, 1)
        [void]$L.Add('        <tr><td><a class="task-link" href="' + $tk.url + '" target="_blank">' + (Esc $tk.name) + '</a></td><td>' + (Art-Pill $tk.dir) + '</td><td>' + (Esc $tk.proj) + '</td><td class="hours">' + (Fmt $tk.hours) + '</td><td class="pct">' + $tpct + '%</td></tr>')
    }
    [void]$L.Add('        <tr class="total-row"><td colspan="3">&#1048;&#1090;&#1086;&#1075;&#1086;: ' + (Esc $kv.Key) + '</td><td>' + $ahd + '</td><td>100%</td></tr>')
    [void]$L.Add('      </tbody></table></div>')
    [void]$L.Add('  </details>')
}
[void]$L.Add('</div>')

# ============================================================
# COMPARISON SECTION (vs previous month)
# ============================================================
$prevData2 = $null; $prevPeriodLbl = $null
try {
    $pd0 = [datetime]::ParseExact($Start, 'yyyy-MM-dd', $null).AddMonths(-1)
    $prevKey0 = $pd0.ToString('yyyy-MM')
    $prevJson0 = "$BASE\time_data_$prevKey0.json"
    if (Test-Path $prevJson0) {
        $prevData2 = Get-Content $prevJson0 -Raw -Encoding utf8 | ConvertFrom-Json
        $mn0 = @('January','February','March','April','May','June','July','August','September','October','November','December')
        $prevPeriodLbl = "$($mn0[$pd0.Month-1]) $($pd0.Year)"
    }
} catch {}

if ($prevData2 -and $prevPeriodLbl) {
    function DSN([double]$v) { if ($v -ge 0) { '+' } else { '' } }
    function DCol([double]$v,[bool]$inv=$false) {
        $pos = if ($inv) { $v -le 0 } else { $v -ge 0 }
        if ($pos) { '#38a169' } else { '#e53e3e' }
    }

    # Build per-person stats for prev month (skip Unassigned)
    $prevPP = @{}
    foreach ($prop0 in $prevData2.PSObject.Properties) {
        $t0 = $prop0.Value; $who0 = [string]$t0.assignee
        if ($who0 -eq 'Unassigned') { continue }
        if (-not $prevPP[$who0]) { $prevPP[$who0] = @{tasks=0;hours=0.0} }
        $prevPP[$who0].tasks++
        $prevPP[$who0].hours += [double]$t0.hours
    }

    # Build per-person stats for current month (reuse $byAssignee)
    $currPP = @{}
    foreach ($kv0 in $byAssignee.GetEnumerator()) {
        if ($kv0.Key -eq 'Unassigned') { continue }
        $currPP[$kv0.Key] = @{tasks=$kv0.Value.tasks.Count; hours=$kv0.Value.hours}
    }

    $prevTT0 = 0; foreach ($v0 in $prevPP.Values) { $prevTT0 += $v0.tasks }
    $currTT0 = 0; foreach ($v0 in $currPP.Values) { $currTT0 += $v0.tasks }
    $prevHH0 = 0.0; foreach ($v0 in $prevPP.Values) { $prevHH0 += $v0.hours }
    $currHH0 = 0.0; foreach ($v0 in $currPP.Values) { $currHH0 += $v0.hours }
    $prevEC0 = $prevPP.Count; $currEC0 = $currPP.Count

    $dT0  = $currTT0 - $prevTT0
    $dTp0 = if ($prevTT0 -gt 0) { [math]::Round($dT0/$prevTT0*100,1) } else { 0 }
    $dE0  = $currEC0 - $prevEC0
    $dEp0 = if ($prevEC0 -gt 0) { [math]::Round($dE0/$prevEC0*100,1) } else { 0 }
    $dH0  = $currHH0 - $prevHH0
    $dHp0 = if ($prevHH0 -gt 0) { [math]::Round($dH0/$prevHH0*100,1) } else { 0 }

    $joined0 = @($currPP.Keys | Where-Object { -not $prevPP.ContainsKey($_) } | Sort-Object)
    $left0   = @($prevPP.Keys | Where-Object { -not $currPP.ContainsKey($_) } | Sort-Object)

    [void]$L.Add('<div class="card">')
    [void]$L.Add('  <div class="section-title">&#1057;&#1088;&#1072;&#1074;&#1085;&#1077;&#1085;&#1080;&#1077; &#1089; ' + (Esc $prevPeriodLbl) + '</div>')

    # 3-column summary
    [void]$L.Add('  <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin-bottom:20px;">')
    $sumItems0 = @(
        @{lbl='&#1047;&#1072;&#1076;&#1072;&#1095;';            cur=[int]$currTT0; prv=[int]$prevTT0; d=[int]$dT0; dp=$dTp0},
        @{lbl='&#1057;&#1086;&#1090;&#1088;&#1091;&#1076;&#1085;&#1080;&#1082;&#1086;&#1074;'; cur=[int]$currEC0; prv=[int]$prevEC0; d=[int]$dE0; dp=$dEp0},
        @{lbl='&#1063;&#1072;&#1089;&#1086;&#1074;';            cur=[math]::Round($currHH0); prv=[math]::Round($prevHH0); d=[math]::Round($dH0); dp=$dHp0}
    )
    foreach ($si in $sumItems0) {
        $sc = DCol $si.d; $ss = DSN $si.d
        [void]$L.Add('    <div style="background:#f7f8fc;border:1px solid #e2e8f0;border-radius:8px;padding:16px;text-align:center;">')
        [void]$L.Add('      <div style="font-size:11px;font-weight:600;color:#718096;text-transform:uppercase;letter-spacing:.5px;margin-bottom:8px;">' + $si.lbl + '</div>')
        [void]$L.Add('      <div style="font-size:28px;font-weight:700;">' + $si.cur + '</div>')
        [void]$L.Add('      <div style="font-size:12px;color:#a0aec0;margin-top:2px;">&#1073;&#1099;&#1083;&#1086;: ' + $si.prv + '</div>')
        [void]$L.Add('      <div style="font-size:15px;font-weight:700;color:' + $sc + ';margin-top:6px;">' + $ss + $si.d + ' (' + $ss + $si.dp + '%)</div>')
        [void]$L.Add('    </div>')
    }
    [void]$L.Add('  </div>')

    # Joined / Left chips
    if ($joined0.Count -gt 0 -or $left0.Count -gt 0) {
        [void]$L.Add('  <div style="display:flex;gap:16px;margin-bottom:20px;flex-wrap:wrap;">')
        if ($joined0.Count -gt 0) {
            [void]$L.Add('    <div style="flex:1;min-width:220px;">')
            [void]$L.Add('      <div style="font-size:12px;font-weight:600;color:#276749;margin-bottom:6px;">+ &#1042;&#1087;&#1077;&#1088;&#1074;&#1099;&#1077; &#1074; ' + (Esc $Label) + ':</div>')
            [void]$L.Add('      <div style="display:flex;flex-wrap:wrap;gap:4px;">')
            foreach ($nm0 in $joined0) { [void]$L.Add('        <span style="background:#c6f6d5;color:#276749;padding:2px 10px;border-radius:10px;font-size:12px;">' + (Esc $nm0) + '</span>') }
            [void]$L.Add('      </div></div>')
        }
        if ($left0.Count -gt 0) {
            [void]$L.Add('    <div style="flex:1;min-width:220px;">')
            [void]$L.Add('      <div style="font-size:12px;font-weight:600;color:#c53030;margin-bottom:6px;">&#8722; &#1053;&#1077; &#1072;&#1082;&#1090;&#1080;&#1074;&#1085;&#1099; &#1074; ' + (Esc $Label) + ':</div>')
            [void]$L.Add('      <div style="display:flex;flex-wrap:wrap;gap:4px;">')
            foreach ($nm0 in $left0) { [void]$L.Add('        <span style="background:#fed7d7;color:#c53030;padding:2px 10px;border-radius:10px;font-size:12px;">' + (Esc $nm0) + '</span>') }
            [void]$L.Add('      </div></div>')
        }
        [void]$L.Add('  </div>')
    }

    # Per-employee comparison table
    [void]$L.Add('  <table class="summary-table">')
    [void]$L.Add('    <thead><tr>')
    [void]$L.Add('      <th>&#1057;&#1086;&#1090;&#1088;&#1091;&#1076;&#1085;&#1080;&#1082;</th>')
    [void]$L.Add('      <th style="text-align:center">' + (Esc $prevPeriodLbl) + '<br><small style="font-weight:400;text-transform:none">&#1095; / &#1079;&#1072;&#1076;.</small></th>')
    [void]$L.Add('      <th style="text-align:center">' + (Esc $Label) + '<br><small style="font-weight:400;text-transform:none">&#1095; / &#1079;&#1072;&#1076;.</small></th>')
    [void]$L.Add('      <th style="text-align:center">&#916; &#1063;&#1072;&#1089;&#1086;&#1074;</th>')
    [void]$L.Add('      <th style="text-align:center">&#916; &#1047;&#1072;&#1076;&#1072;&#1095;</th>')
    [void]$L.Add('      <th style="text-align:center">&#1063;&#1072;&#1089;/&#1079;&#1072;&#1076;. (&#1101;&#1092;&#1092;.)</th>')
    [void]$L.Add('    </tr></thead><tbody>')

    $allP0 = @{}
    foreach ($n0 in $currPP.Keys) { $allP0[$n0] = 1 }
    foreach ($n0 in $prevPP.Keys) { $allP0[$n0] = 1 }
    $sortedP0 = $allP0.Keys | Sort-Object { if ($currPP[$_]) { -$currPP[$_].hours } else { 9999 } }

    foreach ($nm0 in $sortedP0) {
        $cH0  = if ($currPP[$nm0]) { $currPP[$nm0].hours } else { 0.0 }
        $cT0b = if ($currPP[$nm0]) { $currPP[$nm0].tasks } else { 0 }
        $pH0  = if ($prevPP[$nm0]) { $prevPP[$nm0].hours } else { 0.0 }
        $pT0  = if ($prevPP[$nm0]) { $prevPP[$nm0].tasks } else { 0 }

        $cEff0 = if ($cT0b -gt 0) { [math]::Round($cH0/$cT0b,1) } else { 0.0 }
        $pEff0 = if ($pT0 -gt 0)  { [math]::Round($pH0/$pT0,1) }  else { 0.0 }
        $dEff0 = if ($cEff0 -gt 0 -and $pEff0 -gt 0) { [math]::Round($cEff0-$pEff0,1) } else { 0.0 }

        $dHv0  = $cH0 - $pH0
        $dHvp0 = if ($pH0 -gt 0) { [math]::Round($dHv0/$pH0*100,1) } else { 0 }
        $dTv0  = $cT0b - $pT0
        $dTvp0 = if ($pT0 -gt 0) { [math]::Round($dTv0/$pT0*100,1) } else { 0 }

        $prevC0 = if ($pT0 -gt 0)  { (Fmt $pH0) + ' / ' + $pT0  } else { '&mdash;' }
        $currC0 = if ($cT0b -gt 0) { (Fmt $cH0) + ' / ' + $cT0b } else { '&mdash;' }

        $effC0 = if ($pEff0 -gt 0 -and $cEff0 -gt 0) {
            $es = DSN $dEff0; $ec = DCol $dEff0 $true
            [string]$pEff0 + ' &#8594; <strong style="color:' + $ec + '">' + [string]$cEff0 + '</strong> <small style="color:#a0aec0">(' + $es + [string]$dEff0 + ')</small>'
        } elseif ($cEff0 -gt 0) { '&#8594; ' + [string]$cEff0 }
        else { '&mdash;' }

        $dHhtml0 = if ($pH0 -gt 0) {
            $s0 = DSN $dHv0; $c0 = DCol $dHv0
            '<span style="color:' + $c0 + ';font-weight:600">' + $s0 + (Fmt $dHv0) + '</span><br><small style="color:#a0aec0">' + $s0 + $dHvp0 + '%</small>'
        } else { '<small style="color:#a0aec0">&#1085;&#1086;&#1074;&#1099;&#1081;</small>' }

        $dThtml0 = if ($pT0 -gt 0) {
            $s0 = DSN $dTv0; $c0 = DCol $dTv0
            '<span style="color:' + $c0 + ';font-weight:600">' + $s0 + $dTv0 + '</span><br><small style="color:#a0aec0">' + $s0 + $dTvp0 + '%</small>'
        } else { '<small style="color:#a0aec0">&#1085;&#1086;&#1074;&#1099;&#1081;</small>' }

        [void]$L.Add('      <tr>')
        [void]$L.Add('        <td><strong>' + (Esc $nm0) + '</strong></td>')
        [void]$L.Add('        <td style="text-align:center;color:#718096;">' + $prevC0 + '</td>')
        [void]$L.Add('        <td style="text-align:center;font-weight:700;">' + $currC0 + '</td>')
        [void]$L.Add('        <td style="text-align:center;">' + $dHhtml0 + '</td>')
        [void]$L.Add('        <td style="text-align:center;">' + $dThtml0 + '</td>')
        [void]$L.Add('        <td style="text-align:center;font-size:13px;">' + $effC0 + '</td>')
        [void]$L.Add('      </tr>')
    }
    [void]$L.Add('    </tbody></table>')
    [void]$L.Add('</div>')
}

# Footer
$genDate = Get-Date -Format 'dd.MM.yyyy HH:mm'
[void]$L.Add('<div style="text-align:center;color:#a0aec0;font-size:12px;padding:24px 0">&#1057;&#1075;&#1077;&#1085;&#1077;&#1088;&#1080;&#1088;&#1086;&#1074;&#1072;&#1085;&#1086;: ' + $genDate + ' &nbsp;|&nbsp; Asana time_tracking_entries &nbsp;|&nbsp; ' + $StartDisp + ' &#8212; ' + $EndDisp + '</div>')
[void]$L.Add('</div></body></html>')

$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllLines($htmlFile, $L, $utf8)
Write-Host "=== DONE ==="
Write-Host "HTML: $htmlFile  ($($L.Count) lines)"
Write-Host "Stats: $totalHInt h / $totalT tasks / $totalP projects"
