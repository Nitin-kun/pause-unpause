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
  $exe = "$name.exe"
  cmd.exe /c "taskkill /F /IM $exe /T >nul 2>&1"
  $deadline = (Get-Date).AddSeconds(12)
  do {
    Start-Sleep -Milliseconds 400
  } while ((Get-Process -Name $name -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline)
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
    $next = $raw
    if ($next -match '"developer_mode"') {
      $next = [regex]::Replace($next, '"developer_mode"\s*:\s*false', '"developer_mode": true')
    } elseif ($next -match '"extensions"\s*:\s*\{') {
      $next = [regex]::Replace(
        $next,
        '"extensions"\s*:\s*\{',
        '"extensions": {"ui":{"developer_mode":true},',
        1
      )
    }
    if ($next -eq $raw) { return }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($pref, $next, $utf8)
  } catch {}
}

function Show-ManualSteps {
  Write-Host ""
  Write-Host "Add it in chrome://extensions:"
  Write-Host "  1. Turn on Developer mode (top right)"
  Write-Host "  2. Click Load unpacked"
  Write-Host "  3. Pick this folder:"
  Write-Host "     $ExtDir"
  Write-Host "  4. Pin pause-unpause from the puzzle icon"
}

function Invoke-LoadUnpackedCdp([string]$browser, [string]$extDir) {
  $port = 9229
  Start-Process -FilePath $browser -ArgumentList @(
    "--remote-debugging-port=$port",
    "--remote-debugging-address=127.0.0.1",
    "--enable-unsafe-extension-debugging"
  )
  $deadline = (Get-Date).AddSeconds(25)
  $version = $null
  do {
    Start-Sleep -Milliseconds 500
    try {
      $version = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/version" -TimeoutSec 1
    } catch {}
  } while (-not $version -and (Get-Date) -lt $deadline)

  if (-not $version -or -not $version.webSocketDebuggerUrl) { return $false }

  $ws = $null
  try {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter(20000)
    $ws.ConnectAsync([Uri]$version.webSocketDebuggerUrl, $cts.Token).GetAwaiter().GetResult()
    $payload = @{
      id     = 1
      method = "Extensions.loadUnpacked"
      params = @{ path = $extDir }
    } | ConvertTo-Json -Compress -Depth 6
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $send = New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $bytes)
    $ws.SendAsync($send, [Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()
    $buf = New-Object byte[] 65536
    $recv = New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $buf)
    $got = $ws.ReceiveAsync($recv, $cts.Token).GetAwaiter().GetResult()
    $text = [Text.Encoding]::UTF8.GetString($buf, 0, $got.Count)
    return ($text -match '"result"' -and $text -notmatch '"error"')
  } catch {
    return $false
  } finally {
    if ($ws) {
      try { $ws.Dispose() } catch {}
    }
  }
}

if ($Uninstall) {
  $browser = Find-Browser
  Restore-ChromeShortcuts
  if ($browser) { Stop-BrowserProcess (Get-BrowserName $browser) }
  if (Test-Path -LiteralPath $Prefix) { Remove-Item -LiteralPath $Prefix -Recurse -Force }
  Write-Host "pause-unpause files were removed."
  Write-Host "If it still appears in chrome://extensions, click Remove on that card."
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
@"
@echo off
start "" "$browser" chrome://extensions
"@ | Set-Content -Encoding ASCII $Launcher

Write-Host ""
Write-Host "Files are ready."
Write-Host "  Extension: $ExtDir"
Write-Host ""

if (-not $browser) {
  Write-Host "Chrome / Edge was not found. Load that folder as an unpacked extension."
  return
}

$browserName = Get-BrowserName $browser
Restore-ChromeShortcuts

try { Set-Clipboard -Value $ExtDir } catch {}

if ($NoLaunch) {
  Show-ManualSteps
  return
}

Write-Host "Closing $browserName so pause-unpause can be added to your profile..."
Stop-BrowserProcess $browserName
Enable-DeveloperMode $browserName

$loaded = Invoke-LoadUnpackedCdp $browser $ExtDir
Stop-BrowserProcess $browserName
Start-Sleep -Seconds 1
Start-Process -FilePath $browser -ArgumentList "chrome://extensions"

if ($loaded) {
  Write-Host "pause-unpause should now be listed on chrome://extensions."
  Write-Host "If Developer mode is off, turn it on so unpacked extensions stay enabled."
} else {
  Write-Host "Chrome blocked a silent install (normal on current Chrome)."
  Show-ManualSteps
  Write-Host "The folder path is on your clipboard."
  try { Invoke-Item -LiteralPath $ExtDir } catch {}
}
