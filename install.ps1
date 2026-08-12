#Requires -Version 5.1
<#
  SentinelX Core - Windows installer (companion to install.sh / install-macos.sh).

  Registers the agent as a Windows SERVICE via WinSW: runs as LocalSystem,
  starts at boot, auto-restarts on failure. This is the Windows analogue of
  the Linux systemd unit / macOS LaunchDaemon.

  A bare `python -m sentinelx_core` is NOT a Windows service (it doesn't speak
  the SCM protocol), so we wrap it with WinSW (a tiny GitHub-hosted supervisor)
  exactly as systemd/launchd supervise the process on the other platforms.

  Parameters (all optional):
    -InstallDir  Where the venv, WinSW, config, logs live.  Default: C:\ProgramData\SentinelX
    -HubUrl      Hub base URL.                               Default: https://mcp.sentinelx.app
    -HostId      Host id.                                    Default: win-<hostname>
    -Source      Local checkout path -> EDITABLE install (dev: `git pull` + restart iterates).
                 Omit -> pip install from git main.
    -ImportFrom  A dir holding an existing identity.json / config.yaml to REUSE
                 (copied into -InstallDir) instead of enrolling / writing fresh.
    -Check       Dry-run: resolve WinSW, print the service XML and the plan,
                 touch nothing. Does NOT require admin.

  Real installs modify the system -> run in an ELEVATED PowerShell
  ("Run as administrator"). -Check does not.
#>
[CmdletBinding()]
param(
  [string]$InstallDir = 'C:\ProgramData\SentinelX',
  [string]$HubUrl     = 'https://mcp.sentinelx.app',
  [string]$HostId,
  [string]$Source,
  [string]$ImportFrom,
  [switch]$Check
)
$ErrorActionPreference = 'Stop'

function Info($m){ Write-Host "[*] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!] $m" -ForegroundColor Yellow }
function Fatal($m){ Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

$SvcId      = 'SentinelX'
$SvcName    = 'SentinelX Agent'
$RepoUrl    = 'git+https://github.com/pensados/sentinelx-cloud-core.git'
# NOTE: until windows-port merges to main, the example lives on that branch.
$ExampleUrl = 'https://raw.githubusercontent.com/pensados/sentinelx-cloud-core/windows-port/config.example.windows.yaml'
if (-not $HostId) { $HostId = "win-$($env:COMPUTERNAME.ToLower())" }

$Venv         = Join-Path $InstallDir '.venv'
$PyExe        = Join-Path $Venv 'Scripts\python.exe'
$IdentityPath = Join-Path $InstallDir 'identity.json'
$ConfigPath   = Join-Path $InstallDir 'config.yaml'
$AuditPath    = Join-Path $InstallDir 'audit.jsonl'
$LogDir       = Join-Path $InstallDir 'logs'
$WinswExe     = Join-Path $InstallDir 'sentinelx-service.exe'
$WinswXml     = Join-Path $InstallDir 'sentinelx-service.xml'

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Get-ServiceXml {
@"
<service>
  <id>$SvcId</id>
  <name>$SvcName</name>
  <description>SentinelX cloud agent - structured, auditable host access via MCP.</description>
  <executable>$PyExe</executable>
  <arguments>-m sentinelx_core --hub $HubUrl --identity "$IdentityPath" --config "$ConfigPath"</arguments>
  <workingdirectory>$InstallDir</workingdirectory>
  <env name="SENTINELX_AUDIT_PATH" value="$AuditPath" />
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="10 sec" />
  <logpath>$LogDir</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>3</keepFiles>
  </log>
</service>
"@
}

function Resolve-WinswUrl {
  # GitHub "latest" release, pick the x64 executable asset. Avoids pinning a
  # version that may move; WinSW-x64.exe is present across v2 and v3.
  $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/winsw/winsw/releases/latest' `
                           -Headers @{ 'User-Agent' = 'sentinelx-installer' }
  $asset = $rel.assets | Where-Object { $_.name -eq 'WinSW-x64.exe' } | Select-Object -First 1
  if (-not $asset) { Fatal 'Could not find WinSW-x64.exe in the latest WinSW release.' }
  $asset.browser_download_url
}

# ------------------------- CHECK (dry-run) --------------------------------
if ($Check) {
  Info 'check mode - nothing will be installed.'
  Info "InstallDir : $InstallDir"
  Info "HostId     : $HostId   |  Hub: $HubUrl"
  if ($Source)     { Info "Source     : $Source (EDITABLE install)" } else { Info "Source     : $RepoUrl (git main)" }
  if ($ImportFrom) { Info "ImportFrom : $ImportFrom (reuse identity/config)" }
  try { Info "WinSW url  : $(Resolve-WinswUrl)" } catch { Warn "WinSW url  : lookup failed ($($_.Exception.Message))" }
  Info '---- service XML that would be written ----'
  Get-ServiceXml
  exit 0
}

# ------------------------- real install -----------------------------------
if (-not (Test-Admin)) {
  Fatal 'Run this in an ELEVATED PowerShell (Run as administrator) - the service install needs it. (Use -Check for a no-admin dry-run.)'
}

# 1) Python launcher. NB: distinct name from $PyExe -- PowerShell variables are
# case-INSENSITIVE, so a `$pyExe` here would be the SAME variable as $PyExe (the
# venv python) and clobber it, making the service run the system `py` instead of
# the venv (which is how the LocalSystem service lost its deps).
$BootPy = $null; $pyPre = @()
if     (Get-Command py     -ErrorAction SilentlyContinue) { $BootPy = 'py'; $pyPre = @('-3') }
elseif (Get-Command python -ErrorAction SilentlyContinue) { $BootPy = 'python' }
else   { Fatal 'Python not found. Install Python 3.12+ (python.org) and re-run.' }

New-Item -ItemType Directory -Force -Path $InstallDir, $LogDir | Out-Null

# Make the venv SELF-CONTAINED: hide the invoking user's site-packages so pip
# installs ALL deps INTO the venv. The service runs as LocalSystem, which can't
# see a user's per-user site-packages, so any dependency left "already
# satisfied" from user-site would crash the service (ModuleNotFoundError).
$env:PYTHONNOUSERSITE = '1'

# 2) venv + agent
if (-not (Test-Path $PyExe)) {
  Info "Creating venv at $Venv"
  & $BootPy @pyPre -m venv $Venv
}
Info 'Upgrading pip'
& $PyExe -m pip install --upgrade pip | Out-Null
if ($Source) {
  Info "Installing agent (editable) from $Source"
  & $PyExe -m pip install -e $Source
} else {
  Info 'Installing agent from git main'
  & $PyExe -m pip install $RepoUrl
}

# 3) identity + config
if (-not (Test-Path $IdentityPath)) {
  if ($ImportFrom -and (Test-Path (Join-Path $ImportFrom 'identity.json'))) {
    Info "Importing identity.json from $ImportFrom"
    Copy-Item (Join-Path $ImportFrom 'identity.json') $IdentityPath -Force
  } else {
    Info "Enroll in your browser: $HubUrl/auth/dashboard/enroll?host_id=$HostId"
    $tok = Read-Host 'Paste enrollment token'
    @{ host_id = $HostId; token = $tok; hub = $HubUrl } | ConvertTo-Json |
      Set-Content -Encoding ascii $IdentityPath
  }
}
if (-not (Test-Path $ConfigPath)) {
  if ($ImportFrom -and (Test-Path (Join-Path $ImportFrom 'config.yaml'))) {
    Info "Importing config.yaml from $ImportFrom"
    Copy-Item (Join-Path $ImportFrom 'config.yaml') $ConfigPath -Force
  } else {
    Info 'Fetching read-only example config'
    Invoke-WebRequest -Uri $ExampleUrl -OutFile $ConfigPath
  }
}

# 4) WinSW binary + service definition
if (-not (Test-Path $WinswExe)) {
  $url = Resolve-WinswUrl
  Info "Downloading WinSW: $url"
  Invoke-WebRequest -Uri $url -OutFile $WinswExe
}
Info 'Writing service definition'
Get-ServiceXml | Set-Content -Encoding utf8 $WinswXml

# 5) install + start (never fight an already-installed service)
$status = ''
try { $status = (& $WinswExe status 2>$null | Out-String).Trim() } catch {}
if ($status -and $status -notmatch 'NonExistent') {
  Info "Service already present (status: $status) - refreshing + restarting."
  & $WinswExe restart
} else {
  Info 'Installing + starting the SentinelX service (LocalSystem, auto-start at boot)'
  & $WinswExe install
  & $WinswExe start
}

Start-Sleep -Seconds 4
$final = ''
try { $final = (& $WinswExe status 2>$null | Out-String).Trim() } catch {}
if ($final -match 'Started|Running') {
  Info "Done. Service '$SvcId' is running (starts at boot). Logs: $LogDir"
  Info "Manage: Restart-Service $SvcId  |  Get-Service $SvcId  |  `"$WinswExe`" status"
} else {
  Warn "Service installed but not confirmed running (status: '$final'). Check $LogDir\sentinelx-service.*.log."
}
