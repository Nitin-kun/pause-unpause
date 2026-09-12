# pause-unpause installer for Windows
# irm https://raw.githubusercontent.com/Nitin-kun/pause-unpause/main/install.ps1 | iex
#
# Do not use param() — PowerShell ignores it when the script is piped to iex.

$ErrorActionPreference = "Stop"
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$Uninstall = $false
$NoLaunch = $false
foreach ($a in @($args)) {
  $n = [string]$a
  if ($n -match '^(?i)-+-?uninstall$') { $Uninstall = $true }
  if ($n -match '^(?i)-+-?no-?launch$') { $NoLaunch = $true }
}
if ($env:PAUSE_UNPAUSE_UNINSTALL -eq "1") { $Uninstall = $true }
if ($env:PAUSE_UNPAUSE_NO_LAUNCH -eq "1") { $NoLaunch = $true }

$RepoSlug = if ($env:PAUSE_UNPAUSE_REPO) { $env:PAUSE_UNPAUSE_REPO } else { "Nitin-kun/pause-unpause" }
$Prefix = Join-Path $env:LOCALAPPDATA "pause-unpause"
$ExtDir = Join-Path $Prefix "extension"
$Launcher = Join-Path $Prefix "pause-unpause.cmd"
$ShortcutBackup = Join-Path $Prefix "shortcut-backup.json"
$LoadArg = "--load-extension=`"$ExtDir`""

function Get-InstallerHome {
  if ($PSScriptRoot) { return $PSScriptRoot }
  if ($PSCommandPath) { return (Split-Path -Parent $PSCommandPath) }
  return (Get-Location).Path
}

function Find-Browser {
  $candidates = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LocalAppData\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:LocalAppData\Microsoft\Edge\Application\msedge.exe"
  )
  foreach ($path in $candidates) {
    if (Test-Path -LiteralPath $path) { return $path }
  }
  return $null
}

function Get-BrowserName([string]$browser) {
  if ($browser -match 'msedge\.exe$') { return "msedge" }
  return "chrome"
}

function Restore-ChromeShortcuts {
  if (-not (Test-Path -LiteralPath $ShortcutBackup)) { return }
  try {
    $items = Get-Content -LiteralPath $ShortcutBackup -Raw | ConvertFrom-Json
  } catch { return }
  $shell = New-Object -ComObject WScript.Shell
  foreach ($item in @($items)) {
    if (-not $item.path -or -not (Test-Path -LiteralPath $item.path)) { continue }
    try {
      $lnk = $shell.CreateShortcut($item.path)
      $lnk.Arguments = [string]$item.arguments
      $lnk.Save()
    } catch {}
  }
}

function Stop-BrowserProcess([string]$name) {
  $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
  if (-not $procs) { return }
  Write-Host "Closing $name so pause-unpause can load into your browser..."
  $procs | Stop-Process -Force -ErrorAction SilentlyContinue
  $deadline = (Get-Date).AddSeconds(8)
  do {
    Start-Sleep -Milliseconds 400
    $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
  } while ($procs -and (Get-Date) -lt $deadline)
}

function Enable-DeveloperMode([string]$browserName) {
  $pref = if ($browserName -eq "msedge") {
    Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data\Default\Preferences"
  } else {
    Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data\Default\Preferences"
  }
  if (-not (Test-Path -LiteralPath $pref)) { return }
  try {
    $raw = [IO.File]::ReadAllText($pref)
    $next = [regex]::Replace($raw, '"developer_mode"\s*:\s*false', '"developer_mode": true')
    if ($next -eq $raw) { return }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($pref, $next, $utf8)
  } catch {}
}

function Update-ChromeShortcuts([string]$browser) {
  $roots = @(
    (Join-Path $env:USERPROFILE "Desktop"),
    (Join-Path $env:PUBLIC "Desktop"),
    (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"),
    (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"),
    (Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar")
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

  $shell = New-Object -ComObject WScript.Shell
  $backup = @()
  $leaf = [IO.Path]::GetFileName($browser)

  foreach ($root in $roots) {
    Get-ChildItem -LiteralPath $root -Filter *.lnk -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
      try {
        $lnk = $shell.CreateShortcut($_.FullName)
      } catch { return }
      if (-not $lnk.TargetPath) { return }
      if ([IO.Path]::GetFileName($lnk.TargetPath) -ne $leaf) { return }
      $orig = [string]$lnk.Arguments
      if ($orig -like "*$ExtDir*") { return }
      $backup += [pscustomobject]@{ path = $_.FullName; arguments = $orig }
      $lnk.Arguments = ($orig.Trim() + " " + $LoadArg).Trim()
      try { $lnk.Save() } catch {}
    }
  }

  if ($backup.Count -gt 0) {
    $backup | ConvertTo-Json | Set-Content -LiteralPath $ShortcutBackup -Encoding UTF8
  }
}

if ($Uninstall) {
  $browser = Find-Browser
  Restore-ChromeShortcuts
  if (Test-Path -LiteralPath $Prefix) { Remove-Item -LiteralPath $Prefix -Recurse -Force }
  Write-Host "pause-unpause removed. Chrome shortcuts were restored."
  if ($browser) {
    Write-Host "Restart Chrome if it is open so the unpacked extension unloads."
  }
  return
}

New-Item -ItemType Directory -Force -Path $ExtDir | Out-Null

$homeDir = Get-InstallerHome
$localManifest = Join-Path $homeDir "browser-extension\unpause\manifest.json"
if (Test-Path -LiteralPath $localManifest) {
  Write-Host "Installing from local files..."
  Copy-Item -Recurse -Force (Join-Path $homeDir "browser-extension\unpause\*") $ExtDir
} else {
  Write-Host "Downloading pause-unpause from GitHub ($RepoSlug)..."
  $zip = Join-Path $env:TEMP "pause-unpause.zip"
  $extract = Join-Path $env:TEMP "pause-unpause-src"
  $headers = @{ "User-Agent" = "pause-unpause-installer" }
  Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri "https://github.com/$RepoSlug/archive/refs/heads/main.zip" -OutFile $zip
  if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
  Expand-Archive -Path $zip -DestinationPath $extract -Force
  $manifest = Get-ChildItem -Path $extract -Filter manifest.json -Recurse | Select-Object -First 1
  if (-not $manifest) { throw "Download succeeded, but manifest.json was missing." }
  Copy-Item -Recurse -Force (Join-Path $manifest.DirectoryName "*") $ExtDir
}

if (-not (Test-Path -LiteralPath (Join-Path $ExtDir "manifest.json"))) {
  throw "Install failed: manifest.json is missing from $ExtDir"
}

$browser = Find-Browser
if (-not $browser) {
  Write-Host "Installed the files, but Chrome / Edge was not found."
  Write-Host "Load this folder in chrome://extensions as an unpacked extension:"
  Write-Host "  $ExtDir"
  return
}

$browserName = Get-BrowserName $browser

@"
@echo off
start "" "$browser" $LoadArg
"@ | Set-Content -Encoding ASCII $Launcher

Update-ChromeShortcuts $browser

Write-Host ""
Write-Host "pause-unpause is installed."
Write-Host "  Extension: $ExtDir"
Write-Host "  Command:   $Launcher"
Write-Host ""

if ($NoLaunch) {
  Write-Host "Run $Launcher (or restart Chrome from the Start menu) to load it."
  return
}

Stop-BrowserProcess $browserName
Enable-DeveloperMode $browserName

Write-Host "Opening your browser with pause-unpause loaded..."
Start-Process -FilePath $browser -ArgumentList "--load-extension=$ExtDir"
Write-Host "Done. Pin the pause-unpause icon from the puzzle menu if you want it on the toolbar."
