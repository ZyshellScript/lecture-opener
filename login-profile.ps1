$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot

function Get-ChromePath {
    @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

function Get-AccountEmail {
    param([string]$folder)
    $lsFile = Join-Path $folder 'Local State'
    if (-not (Test-Path -LiteralPath $lsFile)) { return '' }
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

$folders = @(Get-ChildItem -LiteralPath $scriptDir -Directory -Filter "chrome-profile*" | Sort-Object Name)

Write-Host ""
Write-Host "================================================="
Write-Host "  Lecture Opener - Chrome profile sign-in"
Write-Host "================================================="

if ($folders.Count -gt 0) {
    Write-Host ""
    Write-Host "Existing profiles:"
    for ($i = 0; $i -lt $folders.Count; $i++) {
        $email = Get-AccountEmail $folders[$i].FullName
        $desc = if ($email) { $email } else { "(not signed in)" }
        Write-Host ("  {0}) {1}  [{2}]" -f ($i + 1), $folders[$i].Name, $desc)
    }
} else {
    Write-Host ""
    Write-Host "No Chrome profile folder yet."
}

Write-Host ""
Write-Host ("  {0}) Add a NEW profile (sign in with a new Google account)" -f ($folders.Count + 1))
Write-Host ""

$n = 0
while ($true) {
    $choice = (Read-Host "Pick a number").Trim()
    if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le ($folders.Count + 1)) { break }
    Write-Host "Invalid choice."
}

$chrome = Get-ChromePath
if (-not $chrome) {
    Write-Host "Google Chrome was not found on this computer."
    exit 1
}

if ($n -le $folders.Count) {
    $target = $folders[$n - 1]
    Write-Host ""
    Write-Host "Opening Chrome for profile: $($target.Name)"
    Write-Host "Sign in with the account for this profile, then CLOSE Chrome and run start.bat."
    Start-Process -FilePath $chrome -ArgumentList @("--user-data-dir=$($target.FullName)", "--no-first-run", "--no-default-browser-check", "https://accounts.google.com")
    exit 0
}

# ---- Add a new profile ----
$newFolder = Join-Path $scriptDir "chrome-profile-new"
$suffix = 1
while (Test-Path -LiteralPath $newFolder) {
    $newFolder = Join-Path $scriptDir ("chrome-profile-new-" + $suffix)
    $suffix++
}
New-Item -ItemType Directory -Path $newFolder | Out-Null

Write-Host ""
Write-Host "Created new folder: $newFolder"
Write-Host "Sign in with the NEW Google account in the Chrome window that opens."
Write-Host "After signing in, CLOSE Chrome completely, then press Enter here."
Start-Process -FilePath $chrome -ArgumentList @("--user-data-dir=$newFolder", "--no-first-run", "--no-default-browser-check", "https://accounts.google.com")
[void](Read-Host "`nPress Enter after you signed in and closed Chrome")

$email = Get-AccountEmail $newFolder
if ($email) {
    $safe = $email -replace '[<>:"/\\|?*]', '_'
    $finalName = "chrome-profile-" + $safe
    $final = Join-Path $scriptDir $finalName
    $n2 = 1
    while (Test-Path -LiteralPath $final) {
        $final = Join-Path $scriptDir ($finalName + "-" + $n2)
        $n2++
    }
    try {
        Rename-Item -LiteralPath $newFolder -NewName (Split-Path $final -Leaf)
        Write-Host ""
        Write-Host "New profile folder created:"
        Write-Host "  " + (Split-Path $final -Leaf)
        Write-Host "Account: $email"
    } catch {
        Write-Host ""
        Write-Host "Signed in as $email, but the folder could not be renamed (maybe Chrome is still running)."
        Write-Host "Folder is: $newFolder"
    }
} else {
    Write-Host ""
    Write-Host "Could not detect a signed-in account yet. Folder kept as: $newFolder"
    Write-Host "Sign in again later: run login-profile.bat and pick this folder."
}
