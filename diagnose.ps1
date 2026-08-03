$logFile = "C:\Lectures\diagnose-output.txt"
function Write-Log($msg) { Write-Output $msg; Add-Content -LiteralPath $logFile -Value $msg -Encoding UTF8 }

$chrome = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "(default)"
if (-not $chrome) { $chrome = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe" }
if (-not (Test-Path -LiteralPath $chrome)) { $chrome = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe" }

$debugPort = 9222
$profile = "C:\Lectures\chrome-profile"
$base = "http://127.0.0.1:$debugPort"

try {
    $null = Invoke-RestMethod -Uri "$base/json/version" -TimeoutSec 3
    Write-Log "Connected to running automation Chrome (port $debugPort)"
} catch {
    Write-Log "Starting automation Chrome for diagnosis..."
    Start-Process -FilePath $chrome -ArgumentList @("--remote-debugging-port=$debugPort", "--user-data-dir=$profile", "--no-first-run", "--no-default-browser-check", "--remote-allow-origins=*") | Out-Null
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        try { $null = Invoke-RestMethod -Uri "$base/json/version" -TimeoutSec 2; break } catch { Start-Sleep -Milliseconds 800 }
    }
}

$targets = @()
try { $targets = Invoke-RestMethod -Uri "$base/json/list" -TimeoutSec 5 } catch { Write-Log "ERROR: cannot list tabs: $_" }

Write-Log "=== OPEN TABS ==="
foreach ($t in $targets | Where-Object { $_.type -eq "page" }) {
    Write-Log "TAB | url=$($t.url) | title=$($t.title)"
}

$meet = $targets | Where-Object { $_.type -eq "page" -and ($_.url -like "*meet.google.com*" -or $_.url -like "*zoom.us*") } | Select-Object -First 1
if (-not $meet) {
    Write-Log "No meeting tab found. If a meeting tab is open in a NORMAL Chrome window, close normal Chrome and open the link again via the script."
    Read-Host "Press Enter to close"
    exit 1
}
Write-Log "=== INSPECTING MEETING TAB: $($meet.url) ==="

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ws.ConnectAsync([uri]$meet.webSocketDebuggerUrl, [System.Threading.CancellationToken]::None).Wait()

function Receive-CdpMessage($ws) {
    $ct = [System.Threading.CancellationToken]::None
    $buffer = New-Object byte[] 262144
    $ms = New-Object System.IO.MemoryStream
    do {
        $segR = [ArraySegment[byte]]::new($buffer)
        $res = $ws.ReceiveAsync($segR, $ct).Result
        if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { break }
        $ms.Write($buffer, 0, $res.Count)
    } while (-not $res.EndOfMessage)
    $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    $ms.Dispose()
    return $text
}

function Invoke-CdpEvaluate($ws, $expr, $id) {
    $payload = @{ id = $id; method = "Runtime.evaluate"; params = @{ expression = $expr; returnByValue = $true } } | ConvertTo-Json -Compress -Depth 6
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

$js = @'
(() => {
  const out = [];
  const push = (el) => out.push({
    tag: el.tagName,
    role: el.getAttribute('role') || '',
    label: (el.getAttribute('aria-label') || '').trim(),
    text: (el.innerText || '').trim().slice(0, 80)
  });
  document.querySelectorAll('[role="button"]').forEach(push);
  document.querySelectorAll('button').forEach(push);
  return JSON.stringify(out);
})()
'@

$resp = Invoke-CdpEvaluate $ws $js 1
$value = $resp.result.result.value
Write-Log "=== BUTTONS ON SCREEN ==="
$value | Out-String -Width 300 | ForEach-Object { Write-Log $_ }
Write-Log "=== DONE ==="
$ws.Dispose()
Read-Host "Press Enter to close"
