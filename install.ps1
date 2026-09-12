# pause-unpause installer for Windows
# irm https://raw.githubusercontent.com/Nitin-kun/pause-unpause/main/install.ps1 | iex
#
# Do not use param() — PowerShell ignores it when the script is piped to iex.
# Current Chrome ignores --load-extension. This installer force-installs a packed
# CRX through Chrome policy so it appears in the profile you already use.

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
$CrxPath = Join-Path $Prefix "extension.crx"
$PemPath = Join-Path $Prefix "extension.pem"
$UpdateXml = Join-Path $Prefix "update.xml"
$Launcher = Join-Path $Prefix "pause-unpause.cmd"
$PolicyValue = "pause-unpause"

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

function Get-PolicyRoots([string]$browserName) {
  if ($browserName -eq "msedge") {
    return @(
      "HKCU:\SOFTWARE\Policies\Microsoft\Edge",
      "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    )
  }
  return @(
    "HKCU:\SOFTWARE\Policies\Google\Chrome",
    "HKLM:\SOFTWARE\Policies\Google\Chrome"
  )
}

function Stop-BrowserProcess([string]$name) {
  $exe = "$name.exe"
  cmd.exe /c "taskkill /F /IM $exe /T >nul 2>&1"
  $deadline = (Get-Date).AddSeconds(12)
  do {
    Start-Sleep -Milliseconds 400
  } while ((Get-Process -Name $name -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline)
}

function Get-FileUri([string]$path) {
  ([Uri]$path).AbsoluteUri
}

function Get-ExtensionIdFromPublicKey([byte[]]$pub) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash($pub)
  } finally {
    $sha.Dispose()
  }
  $map = "abcdefghijklmnop".ToCharArray()
  $chars = New-Object System.Collections.Generic.List[char]
  for ($i = 0; $i -lt 16; $i++) {
    $b = $hash[$i]
    [void]$chars.Add($map[$b -shr 4])
    [void]$chars.Add($map[$b -band 0xF])
  }
  -join $chars
}

function Get-SpkiFromBytes([byte[]]$bytes) {
  for ($i = 0; $i -lt $bytes.Length - 4; $i++) {
    if ($bytes[$i] -ne 0x30 -or $bytes[$i + 1] -ne 0x82) { continue }
    $len = ($bytes[$i + 2] * 256) + $bytes[$i + 3]
    $total = $len + 4
    if ($total -lt 270 -or $total -gt 400) { continue }
    if (($i + $total) -gt $bytes.Length) { continue }
    $slice = New-Object byte[] $total
    [Array]::Copy($bytes, $i, $slice, 0, $total)
    return $slice
  }
  return $null
}

function Get-CrxExtensionId([string]$path) {
  $bytes = [IO.File]::ReadAllBytes($path)
  if ($bytes.Length -lt 16) { throw "CRX file is too small." }
  $magic = [Text.Encoding]::ASCII.GetString($bytes, 0, 4)
  if ($magic -ne "Cr24") { throw "Not a Chrome CRX file." }
  $version = [BitConverter]::ToUInt32($bytes, 4)
  if ($version -ge 3) {
    $headerSize = [BitConverter]::ToInt32($bytes, 8)
    $header = New-Object byte[] $headerSize
    [Array]::Copy($bytes, 12, $header, 0, $headerSize)
    $pub = Get-SpkiFromBytes $header
  } else {
    $pubLen = [BitConverter]::ToInt32($bytes, 8)
    $pub = New-Object byte[] $pubLen
    [Array]::Copy($bytes, 16, $pub, 0, $pubLen)
  }
  if (-not $pub) { throw "Could not read the CRX public key." }
  Get-ExtensionIdFromPublicKey $pub
}

function Pack-ExtensionCrx([string]$browser, [string]$extDir, [string]$crxPath, [string]$pemPath) {
  if (Test-Path -LiteralPath $crxPath) { Remove-Item -LiteralPath $crxPath -Force }
  $args = @("--pack-extension=$extDir", "--no-message-box")
  if (Test-Path -LiteralPath $pemPath) {
    $args += "--pack-extension-key=$pemPath"
  }
  $proc = Start-Process -FilePath $browser -ArgumentList $args -PassThru
  $deadline = (Get-Date).AddSeconds(25)
  $found = $null
  do {
    Start-Sleep -Milliseconds 400
    foreach ($candidate in @(
        $crxPath,
        (Join-Path $extDir "extension.crx"),
        (Join-Path (Split-Path $extDir -Parent) "extension.crx")
      )) {
      if (Test-Path -LiteralPath $candidate) {
        $found = $candidate
        break
      }
    }
  } while (-not $found -and -not $proc.HasExited -and (Get-Date) -lt $deadline)

  Start-Sleep -Milliseconds 500
  if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }

  $parentCrx = Join-Path (Split-Path $extDir -Parent) "$(Split-Path $extDir -Leaf).crx"
  $parentPem = Join-Path (Split-Path $extDir -Parent) "$(Split-Path $extDir -Leaf).pem"
  if (-not $found -and (Test-Path -LiteralPath $parentCrx)) { $found = $parentCrx }
  if (-not $found) { throw "Chrome did not pack the extension into a CRX." }
  if ($found -ne $crxPath) { Copy-Item -LiteralPath $found -Destination $crxPath -Force }
  if ((Test-Path -LiteralPath $parentPem) -and $parentPem -ne $pemPath) {
    Copy-Item -LiteralPath $parentPem -Destination $pemPath -Force
  }
}

function Write-UpdateXml([string]$id, [string]$crxPath, [string]$xmlPath, [string]$version) {
  $crxUri = Get-FileUri $crxPath
  @"
<?xml version="1.0" encoding="UTF-8"?>
<gupdate xmlns="http://www.google.com/update2/response" protocol="2.0">
  <app appid="$id">
    <updatecheck codebase="$crxUri" version="$version" status="ok" />
  </app>
</gupdate>
"@ | Set-Content -LiteralPath $xmlPath -Encoding UTF8
}

function Set-ForceInstallPolicy([string]$browserName, [string]$id, [string]$updateUrl) {
  $ok = $false
  foreach ($root in (Get-PolicyRoots $browserName)) {
    try {
      $listKey = Join-Path $root "ExtensionInstallForcelist"
      $srcKey = Join-Path $root "ExtensionInstallSources"
      $allowKey = Join-Path $root "ExtensionInstallAllowlist"
      New-Item -Path $listKey -Force | Out-Null
      New-Item -Path $srcKey -Force | Out-Null
      New-Item -Path $allowKey -Force | Out-Null
      New-ItemProperty -Path $listKey -Name $PolicyValue -Value "$id;$updateUrl" -PropertyType String -Force | Out-Null
      New-ItemProperty -Path $srcKey -Name $PolicyValue -Value "file:///*" -PropertyType String -Force | Out-Null
      New-ItemProperty -Path $allowKey -Name $PolicyValue -Value $id -PropertyType String -Force | Out-Null
      $ok = $true
    } catch {}
  }
  if (-not $ok) { throw "Could not write Chrome policy. Run PowerShell as Administrator." }
}

function Remove-ForceInstallPolicy([string]$browserName) {
  foreach ($root in (Get-PolicyRoots $browserName)) {
    foreach ($sub in @("ExtensionInstallForcelist", "ExtensionInstallSources", "ExtensionInstallAllowlist")) {
      $key = Join-Path $root $sub
      if (Test-Path -LiteralPath $key) {
        Remove-ItemProperty -Path $key -Name $PolicyValue -ErrorAction SilentlyContinue
      }
    }
  }
}

if ($Uninstall) {
  $browser = Find-Browser
  $browserName = if ($browser) { Get-BrowserName $browser } else { "chrome" }
  if ($browser) { Stop-BrowserProcess $browserName }
  Remove-ForceInstallPolicy $browserName
  if (Test-Path -LiteralPath $Prefix) { Remove-Item -LiteralPath $Prefix -Recurse -Force }
  Write-Host "pause-unpause was removed. Restart Chrome if it is still open."
  return
}

New-Item -ItemType Directory -Force -Path $ExtDir | Out-Null

$homeDir = Get-InstallerHome
$localManifest = Join-Path $homeDir "browser-extension\manifest.json"
if (Test-Path -LiteralPath $localManifest) {
  Write-Host "Installing from local files..."
  Copy-Item -Recurse -Force (Join-Path $homeDir "browser-extension\*") $ExtDir
} else {
  Write-Host "Downloading pause-unpause from GitHub ($RepoSlug)..."
  $zip = Join-Path $env:TEMP "pause-unpause.zip"
  $extract = Join-Path $env:TEMP "pause-unpause-src"
  $headers = @{ "User-Agent" = "pause-unpause-installer" }
  Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri "https://github.com/$RepoSlug/archive/refs/heads/main.zip" -OutFile $zip
  if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
  Expand-Archive -Path $zip -DestinationPath $extract -Force
  $manifest = Get-ChildItem -Path $extract -Filter manifest.json -Recurse |
    Where-Object { $_.Directory.Name -eq "browser-extension" } |
    Select-Object -First 1
  if (-not $manifest) {
    $manifest = Get-ChildItem -Path $extract -Filter manifest.json -Recurse | Select-Object -First 1
  }
  if (-not $manifest) { throw "Download succeeded, but manifest.json was missing." }
  Copy-Item -Recurse -Force (Join-Path $manifest.DirectoryName "*") $ExtDir
}

if (-not (Test-Path -LiteralPath (Join-Path $ExtDir "manifest.json"))) {
  throw "Install failed: manifest.json is missing from $ExtDir"
}

$version = "1.0.0"
try {
  $man = Get-Content -LiteralPath (Join-Path $ExtDir "manifest.json") -Raw | ConvertFrom-Json
  if ($man.version) { $version = [string]$man.version }
} catch {}

$browser = Find-Browser
@"
@echo off
start "" "$browser"
"@ | Set-Content -Encoding ASCII $Launcher

if (-not $browser) {
  Write-Host "Installed the files, but Chrome / Edge was not found."
  Write-Host "  $ExtDir"
  return
}

$browserName = Get-BrowserName $browser
Write-Host "Closing $browserName and installing pause-unpause into your profile..."
Stop-BrowserProcess $browserName

Write-Host "Packing the extension..."
Pack-ExtensionCrx $browser $ExtDir $CrxPath $PemPath
Stop-BrowserProcess $browserName

$extId = Get-CrxExtensionId $CrxPath
Write-UpdateXml $extId $CrxPath $UpdateXml $version
Set-ForceInstallPolicy $browserName $extId (Get-FileUri $UpdateXml)

Write-Host ""
Write-Host "pause-unpause is installed."
Write-Host "  Extension id: $extId"
Write-Host "  Files:        $Prefix"
Write-Host ""
Write-Host "Chrome may show Managed by your organization. That is how a script is allowed to add an extension without Load unpacked."
Write-Host "Uninstall later with:  irm https://raw.githubusercontent.com/$RepoSlug/main/install.ps1 | iex   after setting `$env:PAUSE_UNPAUSE_UNINSTALL=1"

if ($NoLaunch) { return }

Start-Sleep -Seconds 1
Start-Process -FilePath $browser -ArgumentList "chrome://extensions"
Write-Host "Opened chrome://extensions. pause-unpause should appear on that page."
