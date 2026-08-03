# =====================================================
#  Lecture Opener - opens your lecture links in Google
#  Chrome automatically at the right time (Egypt TZ).
#  Keep your laptop and this script running, and it will
#  open the link by itself at the exact time, then click
#  the Join button using a real mouse click.
#
#  THIS IS A TEMPLATE. Copy it to lecture-opener.ps1 and
#  put your real meeting links in the schedule below.
# =====================================================

# advance = open this many minutes BEFORE the time | delay = open this many minutes AFTER the time
$schedule = @(
    @{ name = "Math";    link = "PASTE_MEETING_LINK_HERE"; day = "Monday";    time = "10:00"; advance = 0; delay = 0 }
    @{ name = "Physics"; link = "PASTE_MEETING_LINK_HERE"; day = "Wednesday"; time = "13:30"; advance = 0; delay = 0 }
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$egyptTZ = [System.TimeZoneInfo]::FindSystemTimeZoneById("Egypt Standard Time")
$logFile = Join-Path $PSScriptRoot "log.txt"

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
    $line = "[{0}] {1}" -f ([System.TimeZoneInfo]::ConvertTime([DateTime]::UtcNow, $egyptTZ).ToString("yyyy-MM-dd HH:mm:ss"), $msg)
    Write-Host $line
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

function Test-DayMatches($scheduleDay, $todayEnglish) {
    return ($scheduleDay.Trim() -eq $todayEnglish -or $scheduleDay.Trim() -eq $todayEnglish.Substring(0,3))
}

$script:chrome = Get-ChromePath
if (-not $script:chrome) {
    Write-Log "ERROR: Google Chrome was not found on this computer."
    Read-Host "Press Enter to close"
    exit 1
}

$script:debugPort = 9222
$script:chromeProfile = Join-Path $PSScriptRoot "chrome-profile"
$script:cdpId = 0

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

function Join-Meeting($name, $link) {
    Write-Log "Auto-joining: $name"
    if (-not (Open-MeetingTab $link)) {
        Write-Log "FAILED to open Chrome tab for $name"
        return
    }

    $base = "http://127.0.0.1:$script:debugPort"
    $wsUrl = $null
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        try {
            $targets = Invoke-RestMethod -Uri "$base/json/list" -TimeoutSec 3
            $t = $targets | Where-Object { $_.type -eq "page" -and $_.url -like "$link*" } | Select-Object -First 1
            if (-not $t) {
                $t = $targets | Where-Object { $_.type -eq "page" -and ($_.url -like "*meet.google.com*" -or $_.url -like "*zoom.us*") -and $_.url -notlike "chrome://*" } | Select-Object -First 1
            }
            if ($t -and $t.webSocketDebuggerUrl) { $wsUrl = $t.webSocketDebuggerUrl; break }
        } catch {}
        Start-Sleep -Milliseconds 800
    }
    if (-not $wsUrl) {
        Write-Log "Could not connect to the meeting page for $name"
        return
    }

    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    try {
        $ws.ConnectAsync([uri]$wsUrl, [System.Threading.CancellationToken]::None).Wait()

        $js = @'
(() => {
  const prefixes = ['Join now', 'Ask to join', 'Join here', 'Switch here', 'انضمام الآن', 'اسأل عن الانضمام', 'التبديل هنا'];
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

$now = [System.TimeZoneInfo]::ConvertTime([DateTime]::UtcNow, $egyptTZ)
Write-Log "Schedule is running - lectures in schedule: $($schedule.Count) - Egypt time: $($now.ToString('yyyy-MM-dd HH:mm'))"
Write-Log "Leave it running, it will open the links by itself."

$openedToday = @{}
$lastDay = ""

while ($true) {
    $now = [System.TimeZoneInfo]::ConvertTime([DateTime]::UtcNow, $egyptTZ)
    $dayKey = $now.ToString("yyyy-MM-dd")
    $todayEnglish = $now.DayOfWeek.ToString()
    $timeStr = $now.ToString("HH:mm")

    if ($lastDay -ne $dayKey) {
        $lastDay = $dayKey
        $openedToday = @{}
        Write-Log "New day: $($now.ToString('dddd')) $dayKey"
    }

    foreach ($lec in $schedule) {
        if (-not (Test-DayMatches $lec.day $todayEnglish)) { continue }

        $openTime = ([DateTime]::Parse($lec.time)).AddMinutes([int]$lec.delay - [int]$lec.advance).ToString("HH:mm")
        if ($timeStr -ne $openTime) { continue }

        $key = "$dayKey|$($lec.link)"
        if ($openedToday.ContainsKey($key)) { continue }

        $openedToday[$key] = $true
        Write-Log "Opening lecture: $($lec.name) -> $($lec.link)"
        Join-Meeting $lec.name $lec.link
    }

    Start-Sleep -Seconds 15
}
