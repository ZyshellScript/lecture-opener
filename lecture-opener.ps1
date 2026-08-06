param([switch]$Auto, [int]$ProfileIndex = -1)
# advance = open this many minutes BEFORE the time | delay = open this many minutes AFTER the time
# mode = "link" (use the saved link) OR "classroom" (find the link in Google Classroom, class name in 'classroom')
#
# Profiles and schedule are managed from the GUI (lecture-opener-gui.ps1) and
# saved to data.json next to this script. This engine just reads data.json -
# no manual editing needed.
# -Auto = run silently (no prompts): uses the timezone and active profile from data.json.

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$logFile = Join-Path $PSScriptRoot "log.txt"
$script:configPath = Join-Path $PSScriptRoot "config.json"
$script:dataPath = Join-Path $PSScriptRoot "data.json"

$script:dataTimeZoneId = $null
$script:dataLastProfile = $null

$profiles = @()
if (Test-Path -LiteralPath $script:dataPath) {
    try {
        $dataObj = Get-Content -LiteralPath $script:dataPath -Raw | ConvertFrom-Json
        if ($dataObj.timezoneId) { $script:dataTimeZoneId = [string]$dataObj.timezoneId }
        if ($dataObj.lastProfile) { $script:dataLastProfile = [string]$dataObj.lastProfile }
        $profiles = @($dataObj.profiles | ForEach-Object {
            $pName = [string]$_.name
            $pAccount = [string]$_.account
            $pChromeProfile = [string]$_.chromeProfile
            $pEmail = Get-ChromeAccountEmail (Join-Path $PSScriptRoot $pChromeProfile)
            if ([string]::IsNullOrWhiteSpace($pName) -and $pEmail) { $pName = $pEmail }
            if ([string]::IsNullOrWhiteSpace($pAccount) -and $pEmail) { $pAccount = $pEmail }
            @{
                name          = $pName
                account       = $pAccount
                chromeProfile = $pChromeProfile
                schedule      = @($_.schedule | ForEach-Object {
                    @{ name = [string]$_.name; link = [string]$_.link; day = [string]$_.day; time = [string]$_.time; advance = [int]$_.advance; delay = [int]$_.delay; mode = [string]$_.mode; classroom = [string]$_.classroom }
                })
            }
        })
    } catch {
        Write-Host "WARNING: could not read data.json - $($_.Exception.Message)"
        $profiles = @()
    }
}
if ($profiles.Count -eq 0 -and -not $Auto) {
    Write-Host "No schedule found in data.json. Open the app (start.bat) and add your lectures there."
}

function Get-ChromeAccountEmail {
    param([string]$profilePath)
    $lsFile = Join-Path $profilePath 'Local State'
    if (-not $profilePath -or -not (Test-Path -LiteralPath $lsFile)) { return '' }
    try {
        $ls = Get-Content -LiteralPath $lsFile -Raw | ConvertFrom-Json
        $cache = $ls.profile.info_cache
        if ($cache) {
            foreach ($prop in $cache.PSObject.Properties) {
                $entry = $prop.Value
                if ($entry -and $entry.user_name) { return [string]$entry.user_name }
            }
        }
    } catch {}
    return ''
}

function Get-ChromePath {
    $paths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($p in $paths) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

function Write-Log($msg) {
    $tz = $script:tz
    if (-not $tz) { $tz = [System.TimeZoneInfo]::Local }
    $line = "[{0}] {1}" -f ([System.TimeZoneInfo]::ConvertTime([DateTime]::UtcNow, $tz).ToString("yyyy-MM-dd HH:mm:ss"), $msg)
    Write-Host $line
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

function Test-DayMatches($scheduleDay, $todayEnglish) {
    return ($scheduleDay.Trim() -eq $todayEnglish -or $scheduleDay.Trim() -eq $todayEnglish.Substring(0,3))
}

function Read-Trim($prompt) {
    $v = Read-Host $prompt
    if ($null -eq $v) { return "" }
    return $v.Trim()
}

function Save-Config($props) {
    $cfg = @{}
    if (Test-Path -LiteralPath $script:configPath) {
        try {
            $existing = Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json
            foreach ($p in $existing.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
        } catch {}
    }
    foreach ($k in $props.Keys) { $cfg[$k] = $props[$k] }
    $cfg | ConvertTo-Json | Set-Content -LiteralPath $script:configPath -Encoding UTF8
}

function Select-Profile {
    if ($ProfileIndex -ge 0 -and $ProfileIndex -lt $profiles.Count) {
        $chosen = $profiles[$ProfileIndex]
        Write-Log "Using profile: $($chosen.name) ($($chosen.account))"
        if (@($chosen.schedule).Count -eq 0) {
            Write-Log "This profile has no lectures scheduled. The automator will stay idle."
        }
        Save-Config @{ lastProfile = $chosen.name }
        return $chosen
    }
    $active = @($profiles | Where-Object { $_.schedule -and @($_.schedule).Count -gt 0 })
    if ($active.Count -eq 0) {
        Write-Log "ERROR: No profiles with a schedule were found. Add lectures from the app (start.bat)."
        if (-not $Auto) { Read-Host "Press Enter to close" }
        exit 1
    }
    if ($active.Count -eq 1) {
        Write-Log "Using profile: $($active[0].name) ($($active[0].account))"
        Save-Config @{ lastProfile = $active[0].name }
        return $active[0]
    }
    $savedName = $script:dataLastProfile
    if (-not $savedName -and (Test-Path -LiteralPath $script:configPath)) {
        try { $savedName = (Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json).lastProfile } catch {}
    }
    $saved = $null
    if ($savedName) { $saved = $active | Where-Object { $_.name -eq $savedName } | Select-Object -First 1 }
    if ($Auto) {
        if (-not $saved) { $saved = $active[0] }
        Write-Log "Using profile: $($saved.name) ($($saved.account))"
        Save-Config @{ lastProfile = $saved.name }
        return $saved
    }
    if ($saved) {
        $ans = Read-Trim "Use last profile '$($saved.name)'? (Enter=yes, or type anything to change)"
        if ([string]::IsNullOrWhiteSpace($ans)) {
            Write-Log "Using profile: $($saved.name) ($($saved.account))"
            Save-Config @{ lastProfile = $saved.name }
            return $saved
        }
    }
    Write-Host ""
    Write-Host "Multiple profiles found. Select one:"
    for ($i = 0; $i -lt $active.Count; $i++) {
        Write-Host ("  {0}) {1}  ({2})" -f ($i + 1), $active[$i].name, $active[$i].account)
    }
    while ($true) {
        $n = 0
        $choice = Read-Trim "Pick a number"
        if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $active.Count) {
            $sel = $active[$n - 1]
            Write-Log "Using profile: $($sel.name) ($($sel.account))"
            Save-Config @{ lastProfile = $sel.name }
            return $sel
        }
        Write-Host "Invalid choice."
    }
}

function Stop-AutomationChrome {
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine -like "*--user-data-dir=*$PSScriptRoot*"
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Select-Timezone {
    $timezones = [System.TimeZoneInfo]::GetSystemTimeZones()
    $saved = $null
    if ($script:dataTimeZoneId) {
        try { $saved = [System.TimeZoneInfo]::FindSystemTimeZoneById($script:dataTimeZoneId) } catch {}
    }
    if (-not $saved -and (Test-Path -LiteralPath $script:configPath)) {
        try {
            $cfg = Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json
            if ($cfg.timezoneId) { $saved = [System.TimeZoneInfo]::FindSystemTimeZoneById($cfg.timezoneId) }
        } catch {}
    }
    if ($saved) {
        if ($Auto) { return $saved }
        Write-Host ""
        Write-Host "Saved timezone: $($saved.Id) ($($saved.DisplayName))"
        $ans = Read-Trim "Press Enter to keep it, or type a country/timezone name to change"
        if ([string]::IsNullOrWhiteSpace($ans)) { return $saved }
    } else {
        if ($Auto) { return [System.TimeZoneInfo]::Local }
        Write-Host ""
        Write-Host "Select your timezone (any country works)."
        $ans = $null
    }
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($ans)) {
            $ans = Read-Trim "Country/timezone (example: Egypt, India, UK, California, Eastern) or Enter for your PC timezone"
        }
        if ([string]::IsNullOrWhiteSpace($ans)) {
            $local = [System.TimeZoneInfo]::Local
            Write-Host "Using your computer's timezone: $($local.Id)"
            Save-Config @{ timezoneId = $local.Id }
            return $local
        }
        $matches = @($timezones | Where-Object {
            $_.Id -like "*$ans*" -or $_.DisplayName -like "*$ans*" -or $_.StandardName -like "*$ans*" -or $_.DaylightName -like "*$ans*"
        })
        if ($matches.Count -eq 0) {
            Write-Host "No timezone matched '$ans'."
            $ans = $null
            continue
        }
        if ($matches.Count -eq 1) {
            Write-Host "Matched: $($matches[0].Id) ($($matches[0].DisplayName))"
            Save-Config @{ timezoneId = $matches[0].Id }
            return $matches[0]
        }
        Write-Host "Multiple matches:"
        for ($i = 0; $i -lt $matches.Count; $i++) {
            Write-Host ("  {0}) {1}  ({2})" -f ($i + 1), $matches[$i].Id, $matches[$i].DisplayName)
        }
        $n = 0
        $choice = Read-Trim "Pick a number"
        if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $matches.Count) {
            Write-Host "Selected: $($matches[$n-1].Id) ($($matches[$n-1].DisplayName))"
            Save-Config @{ timezoneId = $matches[$n-1].Id }
            return $matches[$n-1]
        }
        Write-Host "Invalid choice."
        $ans = $null
    }
}

$script:tz = Select-Timezone

$script:chrome = Get-ChromePath
if (-not $script:chrome) {
    Write-Log "ERROR: Google Chrome was not found on this computer."
    if (-not $Auto) { Read-Host "Press Enter to close" }
    exit 1
}

$script:debugPort = 9222
$script:cdpId = 0

$script:profile = Select-Profile
$script:schedule = $script:profile.schedule
$script:chromeProfile = Join-Path $PSScriptRoot $script:profile.chromeProfile
Stop-AutomationChrome

function Receive-CdpMessage($ws) {
    $ct = [System.Threading.CancellationToken]::None
    $buffer = New-Object byte[] 262144
    $ms = New-Object System.IO.MemoryStream
    do {
        $segR = [ArraySegment[byte]]::new($buffer)
        $res = $ws.ReceiveAsync($segR, $ct).Result
        if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
            break
        }
        $ms.Write($buffer, 0, $res.Count)
    } while (-not $res.EndOfMessage)
    $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    $ms.Dispose()
    return $text
}

function Invoke-CdpMethod($ws, $method, $params) {
    $script:cdpId++
    $id = $script:cdpId
    $payload = @{ id = $id; method = $method; params = $params } | ConvertTo-Json -Compress -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ct = [System.Threading.CancellationToken]::None
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()
    while ($true) {
        $msg = Receive-CdpMessage $ws
        if (-not $msg) { return $null }
        $obj = $msg | ConvertFrom-Json
        if ($obj.id -eq $id) { return $obj }
    }
}

function Invoke-CdpEvaluate($ws, $expr) {
    return (Invoke-CdpMethod $ws "Runtime.evaluate" @{ expression = $expr; returnByValue = $true })
}

function Invoke-CdpMouseClick($ws, $x, $y) {
    $null = Invoke-CdpMethod $ws "Input.dispatchMouseEvent" @{ type = "mouseMoved";    x = $x; y = $y }
    $null = Invoke-CdpMethod $ws "Input.dispatchMouseEvent" @{ type = "mousePressed";  x = $x; y = $y; button = "left"; buttons = 1; clickCount = 1 }
    $null = Invoke-CdpMethod $ws "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $x; y = $y; button = "left"; buttons = 0; clickCount = 1 }
}

function Open-MeetingTab($link) {
    $base = "http://127.0.0.1:$script:debugPort"
    try {
        $null = Invoke-RestMethod -Uri "$base/json/version" -TimeoutSec 3
        try {
            $encoded = [uri]::EscapeDataString($link)
            Invoke-RestMethod -Method Put -Uri "$base/json/new?$encoded" -TimeoutSec 5 | Out-Null
            return $true
        } catch { return $false }
    } catch {
        $args = @(
            "--remote-debugging-port=$script:debugPort",
            "--user-data-dir=$script:chromeProfile",
            "--start-fullscreen",
            "--no-first-run",
            "--no-default-browser-check",
            "--remote-allow-origins=*",
            $link
        )
        try {
            Start-Process -FilePath $script:chrome -ArgumentList $args | Out-Null
            return $true
        } catch { return $false }
    }
}

function Send-CdpFireAndForget($ws, $method, $params) {
    $script:cdpId++
    $payload = @{ id = $script:cdpId; method = $method; params = $params } | ConvertTo-Json -Compress -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ct = [System.Threading.CancellationToken]::None
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()
}

function Connect-ToPage($link) {
    if (-not (Open-MeetingTab $link)) { return $null }
    $base = "http://127.0.0.1:$script:debugPort"
    $wsUrl = $null
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        try {
            $targets = Invoke-RestMethod -Uri "$base/json/list" -TimeoutSec 3
            $t = $targets | Where-Object { $_.type -eq "page" -and $_.url -like "$link*" } | Select-Object -First 1
            if (-not $t) {
                $t = $targets | Where-Object { $_.type -eq "page" -and ($_.url -like "*meet.google.com*" -or $_.url -like "*zoom.us*" -or $_.url -like "*classroom.google.com*") -and $_.url -notlike "chrome://*" } | Select-Object -First 1
            }
            if ($t -and $t.webSocketDebuggerUrl) { $wsUrl = $t.webSocketDebuggerUrl; break }
        } catch {}
        Start-Sleep -Milliseconds 800
    }
    if (-not $wsUrl) { return $null }
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    try {
        $ws.ConnectAsync([uri]$wsUrl, [System.Threading.CancellationToken]::None).Wait()
        return $ws
    } catch { return $null }
}

function Join-Meeting($name, $link) {
    Write-Log "Auto-joining: $name"
    $ws = Connect-ToPage $link
    if (-not $ws) {
        Write-Log "Could not connect to the meeting page for $name"
        return
    }
    try {

        $js = @'
(() => {
  const prefixes = ['Join now', 'Ask to join', 'join here', 'Switch here','انضمام الآن', 'اسأل عن الانضمام', 'التبديل هنا'];
  const candidates = Array.from(document.querySelectorAll('[role="button"], button'));
  for (const b of candidates) {
    const label = (b.getAttribute('aria-label') || '').trim();
    const text = (b.innerText || '').trim();
    for (const p of prefixes) {
      if (label.startsWith(p) || text.startsWith(p)) {
        const r = b.getBoundingClientRect();
        if (r.width > 0 && r.height > 0) {
          return { found: true, x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2), match: p };
        }
      }
    }
  }
  return { found: false, x: 0, y: 0 };
})()
'@

        $deadline = (Get-Date).AddSeconds(90)
        $joined = $false
        $clickedOnce = $false
        $misses = 0
        while ((Get-Date) -lt $deadline) {
            $resp = Invoke-CdpEvaluate $ws $js
            $v = $null
            if ($resp -and $resp.result -and $resp.result.result -and $resp.result.result.value) {
                $v = $resp.result.result.value
            }
            if ($v -and $v.found) {
                $clickedOnce = $true
                $misses = 0
                Write-Log "Clicking '$($v.match)' at ($($v.x), $($v.y)) for $name"
                Invoke-CdpMouseClick $ws $v.x $v.y
            } else {
                if ($clickedOnce) { $misses++ }
                if ($misses -ge 3) { $joined = $true; break }
            }
            Start-Sleep -Seconds 2
        }
        if ($joined) { Write-Log "Joined meeting: $name" }
        else { Write-Log "Could not join $name (join button never disappeared)" }
    } catch {
        Write-Log "Automation error for ${name}: $_"
    } finally {
        try { $ws.Dispose() } catch {}
    }
}

$now = [System.TimeZoneInfo]::ConvertTime([DateTime]::UtcNow, $script:tz)
Write-Log "Schedule is running - lectures in schedule: $($script:schedule.Count) - Timezone $($script:tz.Id): $($now.ToString('yyyy-MM-dd HH:mm'))"
Write-Log "Leave it running, it will open the links by itself."
Write-Log "Account: $($script:profile.account) (already logged in if you used login-profile.bat)"

$openedToday = @{}
$lastDay = ""

while ($true) {
    $now = [System.TimeZoneInfo]::ConvertTime([DateTime]::UtcNow, $script:tz)

function Join-FromClassroom($name, $subject) {
    if ([string]::IsNullOrWhiteSpace($subject)) {
        Write-Log "SKIPPED '$name': classroom name is empty. Edit the lecture and set the Classroom name."
        return $false
    }
    Write-Log "Looking for '$subject' meeting in Google Classroom"
    $ws = Connect-ToPage "https://classroom.google.com"
    if (-not $ws) {
        Write-Log "Could not open Google Classroom for $subject"
        return $false
    }
    try {
        $subjectEsc = $subject.Replace("'", "")
        $findClass = @"
(() => {
  const q = '$subjectEsc'.toLowerCase();
  const links = Array.from(document.querySelectorAll('a[href*="/c/"]'));
  for (const a of links) {
    const t = (a.innerText || '').trim().toLowerCase();
    if (t.includes(q)) return { found: true, url: a.href };
  }
  return { found: false };
})()
"@

        $courseUrl = $null
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline -and -not $courseUrl) {
            $resp = Invoke-CdpEvaluate $ws $findClass
            if ($resp -and $resp.result -and $resp.result.result -and $resp.result.result.value -and $resp.result.result.value.found) {
                $courseUrl = $resp.result.result.value.url
                Write-Log "Found class '$subject' in Classroom"
            } else {
                Start-Sleep -Seconds 3
            }
        }
        if (-not $courseUrl) {
            Write-Log "Class '$subject' not found in Classroom"
            return $false
        }

        Send-CdpFireAndForget $ws "Page.navigate" @{ url = $courseUrl }
        Start-Sleep -Seconds 8

        $extractMeet = @'
(() => {
  const anchors = Array.from(document.querySelectorAll('a[href*="meet.google.com"]'));
  for (const a of anchors) {
    let el = a.parentElement;
    let section = null;
    while (el && el !== document.body) {
      if (el.tagName === 'SECTION') { section = el; break; }
      el = el.parentElement;
    }
    if (!section) continue;
    const m = (section.textContent || '').match(/Created\s+(\d{1,2}:\d{2}\s*[APap][Mm])/);
    if (m) return { found: true, link: a.href };
  }
  return { found: false };
})()
'@

        $searchDeadline = (Get-Date).AddMinutes(25)
        $meetLink = $null
        while ((Get-Date) -lt $searchDeadline -and -not $meetLink) {
            $resp = Invoke-CdpEvaluate $ws $extractMeet
            if ($resp -and $resp.result -and $resp.result.result -and $resp.result.result.value -and $resp.result.result.value.found) {
                $meetLink = $resp.result.result.value.link
                Write-Log "Found meeting link for '$subject': $meetLink"
            } else {
                Send-CdpFireAndForget $ws "Page.reload" @{}
                Write-Log "No meeting link yet for '$subject' - refreshing..."
                Start-Sleep -Seconds 8
            }
        }
        if (-not $meetLink) {
            Write-Log "No meeting link appeared for '$subject' after waiting"
            return $false
        }
        Join-Meeting $name $meetLink
        return $true
    } catch {
        Write-Log "Classroom automation error for ${subject}: $_"
        return $false
    } finally {
        try { $ws.Dispose() } catch {}
    }
}

$now = [System.TimeZoneInfo]::ConvertTime([DateTime]::UtcNow, $script:tz)
    $dayKey = $now.ToString("yyyy-MM-dd")
    $todayEnglish = $now.DayOfWeek.ToString()
    $timeStr = $now.ToString("HH:mm")

    if ($lastDay -ne $dayKey) {
        $lastDay = $dayKey
        $openedToday = @{}
        Write-Log "New day: $($now.ToString('dddd')) $dayKey"
    }

    foreach ($lec in $script:schedule) {
        if (-not (Test-DayMatches $lec.day $todayEnglish)) { continue }

        $openTime = ([DateTime]::Parse($lec.time)).AddMinutes([int]$lec.delay - [int]$lec.advance).ToString("HH:mm")
        if ($timeStr -ne $openTime) { continue }

        $key = "$dayKey|$($lec.mode)|$($lec.name)|$timeStr"
        if ($openedToday.ContainsKey($key)) { continue }

        $openedToday[$key] = $true
        if ($lec.mode -eq "classroom") {
            $ok = Join-FromClassroom $lec.name $lec.classroom
            if (-not $ok -and $lec.link) {
                Write-Log "Classroom lookup failed for $($lec.name) - falling back to saved link"
                Join-Meeting $lec.name $lec.link
            }
        } else {
            Write-Log "Opening lecture: $($lec.name) -> $($lec.link)"
            Join-Meeting $lec.name $lec.link
        }
    }

    Start-Sleep -Seconds 15
}


