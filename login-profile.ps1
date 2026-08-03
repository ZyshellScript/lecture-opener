$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot

$folders = @(Get-ChildItem -LiteralPath $scriptDir -Directory -Filter "chrome-profile*" | Sort-Object Name)
if ($folders.Count -eq 0) {
    Write-Host "No Chrome profile folder was found. Create a folder named 'chrome-profile' next to this script:"
    Write-Host "  $scriptDir"
    exit 1
}

$target = $null
if ($folders.Count -eq 1) {
    $target = $folders[0]
} else {
    Write-Host "Multiple Chrome profiles found:"
    for ($i = 0; $i -lt $folders.Count; $i++) {
        Write-Host ("  {0}) {1}" -f ($i + 1), $folders[$i].Name)
    }
    $n = 0
    while ($true) {
        $choice = (Read-Host "Pick a profile to sign in").Trim()
        if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $folders.Count) { $target = $folders[$n - 1]; break }
        Write-Host "Invalid choice."
    }
}

$chrome = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $chrome) {
    Write-Host "Google Chrome was not found on this computer."
    exit 1
}

Write-Host ""
Write-Host "Opening Chrome for profile: $($target.Name)"
Write-Host "Sign in with the account for this profile, then CLOSE Chrome and run start.bat."
Start-Process -FilePath $chrome -ArgumentList @("--user-data-dir=$($target.FullName)", "--no-first-run", "--no-default-browser-check", "https://accounts.google.com")
