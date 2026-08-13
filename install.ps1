#Requires -Version 5.1
<#
  SentinelX Core - Windows installer (companion to install.sh / install-macos.sh).

  Two modes:
    (default) SERVICE mode -- registers the agent as a Windows service via WinSW,
              running as LocalSystem, started at boot. Needs an ELEVATED
              PowerShell (admin). The Windows analogue of the systemd unit /
              macOS LaunchDaemon.
    -User     USER mode -- NO admin. Installs under %LOCALAPPDATA% and runs the
              agent as a per-user Scheduled Task at logon (via pythonw, windowless).
              Runs as YOU, so it can do anything you can without elevation -- the
              right fit for locked-down / corporate machines. Analogue of the
              macOS per-user LaunchAgent.

  A bare `python -m sentinelx_core` is neither a Windows service nor self-starting,
  so service mode wraps it with WinSW and user mode supervises it with a Scheduled
  Task -- just as systemd/launchd supervise the process on the other platforms.

  Parameters (all optional):
    -User        No-admin per-user install (Scheduled Task). Default install dir
                 becomes %LOCALAPPDATA%\SentinelX.
    -InstallDir  Where the venv, config, logs live.
                 Default: C:\ProgramData\SentinelX (service) / %LOCALAPPDATA%\SentinelX (-User)
    -HubUrl      Hub base URL.                       Default: https://mcp.sentinelx.app
    -HostId      Host id.                            Default: win-<hostname>
    -Source      Local checkout path -> EDITABLE install (dev: `git pull` + restart iterates).
                 Omit -> pip install from git main.
    -ImportFrom  A dir holding an existing identity.json / config.yaml to REUSE.
    -Check       Dry-run: print the plan, touch nothing. Does NOT require admin.

  Service-mode real installs need an ELEVATED PowerShell. -User and -Check do not.
#>
[CmdletBinding()]
param(
  [switch]$User,
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
$ExampleUrl = 'https://raw.githubusercontent.com/pensados/sentinelx-cloud-core/main/config.example.windows.yaml'
if (-not $HostId) { $HostId = "win-$($env:COMPUTERNAME.ToLower())" }
# User mode installs under the user profile (no admin needed).
if ($User -and $InstallDir -eq 'C:\ProgramData\SentinelX') {
  $InstallDir = Join-Path $env:LOCALAPPDATA 'SentinelX'
}

$Venv         = Join-Path $InstallDir '.venv'
$PyExe        = Join-Path $Venv 'Scripts\python.exe'
$PywExe       = Join-Path $Venv 'Scripts\pythonw.exe'
$IdentityPath = Join-Path $InstallDir 'identity.json'
$ConfigPath   = Join-Path $InstallDir 'config.yaml'
$AuditPath    = Join-Path $InstallDir 'audit.jsonl'
$LogDir       = Join-Path $InstallDir 'logs'
$AgentLog     = Join-Path $LogDir 'agent.log'
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
  # GitHub "latest" release, pick the x64 executable asset. WinSW-x64.exe is
  # present across v2 and v3, so this avoids pinning a version that may move.
  $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/winsw/winsw/releases/latest' `
                           -Headers @{ 'User-Agent' = 'sentinelx-installer' }
  $asset = $rel.assets | Where-Object { $_.name -eq 'WinSW-x64.exe' } | Select-Object -First 1
  if (-not $asset) { Fatal 'Could not find WinSW-x64.exe in the latest WinSW release.' }
  $asset.browser_download_url
}

# ------------------------- CHECK (dry-run) --------------------------------
if ($Check) {
  Info 'check mode - nothing will be installed.'
  Info ('Mode       : ' + $(if ($User) { 'USER (Scheduled Task, no admin)' } else { 'SERVICE (WinSW, LocalSystem, admin)' }))
  Info "InstallDir : $InstallDir"
  Info "HostId     : $HostId   |  Hub: $HubUrl"
  if ($Source)     { Info "Source     : $Source (EDITABLE install)" } else { Info "Source     : $RepoUrl (git main)" }
  if ($ImportFrom) { Info "ImportFrom : $ImportFrom (reuse identity/config)" }
  if ($User) {
    Info "Startup    : per-user Scheduled Task '$SvcId' at logon, running:"
    Info "             $PywExe -m sentinelx_core --hub $HubUrl --identity `"$IdentityPath`" --config `"$ConfigPath`" --log-file `"$AgentLog`""
  } else {
    try { Info "WinSW url  : $(Resolve-WinswUrl)" } catch { Warn "WinSW url  : lookup failed ($($_.Exception.Message))" }
    Info '---- service XML that would be written ----'
    Get-ServiceXml
  }
  exit 0
}

# ------------------------- real install -----------------------------------
if (-not $User -and -not (Test-Admin)) {
  Fatal 'Service mode needs an ELEVATED PowerShell (Run as administrator). On a machine where you are not a local admin, use -User for a no-admin per-user install. (-Check is a no-admin dry-run.)'
}

# 1) Python launcher. NB: distinct name from $PyExe -- PowerShell variables are
# case-INSENSITIVE, so a `$pyExe` here would be the SAME variable as $PyExe and
# clobber the venv python path.
$BootPy = $null; $pyPre = @()
if     (Get-Command py     -ErrorAction SilentlyContinue) { $BootPy = 'py'; $pyPre = @('-3') }
elseif (Get-Command python -ErrorAction SilentlyContinue) { $BootPy = 'python' }
else   { Fatal 'Python not found. Install Python 3.12+ (python.org) and re-run.' }

New-Item -ItemType Directory -Force -Path $InstallDir, $LogDir | Out-Null

# Make the venv SELF-CONTAINED: hide the invoking user's site-packages so pip
# installs ALL deps INTO the venv (a service running as LocalSystem can't see a
# user's per-user site-packages, so deps left "already satisfied" there crash it).
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
    Info 'Fetching + tailoring the example config'
    Invoke-WebRequest -Uri $ExampleUrl -OutFile $ConfigPath
    # Fill in machine-specific file_ops paths (profile r, workspace rw, config.yaml
    # rw for self-management) + upload_base, and set the sentinelx service backend
    # (service vs task), via the venv Python. Without this a fresh config has no
    # readable/writable paths.
    $backend = if ($User) { 'task' } else { 'service' }
    $tailor = @'
import sys, os, yaml
cfg_path, install_dir, backend = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = yaml.safe_load(open(cfg_path, encoding="utf-8").read()) or {}
home = os.environ.get("USERPROFILE", r"C:\Users\Public")
ws = os.path.join(install_dir, "workspace")
os.makedirs(ws, exist_ok=True)
cfg["file_ops"] = {"paths": [
    {"path": home, "access": "r"},
    {"path": ws, "access": "rw"},
    {"path": os.path.join(install_dir, "config.yaml"), "access": "rw"},
]}
cfg["upload_base"] = os.path.join(install_dir, "uploads")
svc = (cfg.get("services") or {}).get("sentinelx")
if isinstance(svc, dict):
    svc["backend"] = backend
open(cfg_path, "w", encoding="utf-8").write(
    yaml.safe_dump(cfg, sort_keys=False, allow_unicode=True, width=100))
print("  tailored: " + home + " (r), " + ws + " (rw), config self-managed, backend=" + backend)
'@
    $tailor | & $PyExe - $ConfigPath $InstallDir $backend
  }
}

# 4) startup mechanism
if ($User) {
  # ---- USER mode: per-user Scheduled Task (no admin, no WinSW) ------------
  Info "Registering per-user Scheduled Task '$SvcId' (runs at your logon, restarts on failure)"
  $me      = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $taskArg = "-m sentinelx_core --hub $HubUrl --identity `"$IdentityPath`" --config `"$ConfigPath`" --log-file `"$AgentLog`""
  $action    = New-ScheduledTaskAction -Execute $PywExe -Argument $taskArg -WorkingDirectory $InstallDir
  $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $me
  $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
  $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -RestartCount 720 -RestartInterval (New-TimeSpan -Minutes 1) `
                 -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $SvcId -Action $action -Trigger $trigger `
                         -Principal $principal -Settings $settings -Force | Out-Null
  Start-ScheduledTask -TaskName $SvcId
  Start-Sleep -Seconds 4
  $state = (Get-ScheduledTask -TaskName $SvcId -ErrorAction SilentlyContinue).State
  if ($state -eq 'Running') {
    Info "Done. Task '$SvcId' is running as you (starts at logon). Logs: $AgentLog"
    Info "Manage: schtasks /Run /TN $SvcId  |  schtasks /End /TN $SvcId  |  Get-ScheduledTask $SvcId"
  } else {
    Warn "Task registered but state is '$state'. Check $AgentLog. If your org blocks Task Scheduler by policy, that is the likely cause."
  }
} else {
  # ---- SERVICE mode: WinSW (LocalSystem, boot) ---------------------------
  if (-not (Test-Path $WinswExe)) {
    $url = Resolve-WinswUrl
    Info "Downloading WinSW: $url"
    Invoke-WebRequest -Uri $url -OutFile $WinswExe
  }
  Info 'Writing service definition'
  Get-ServiceXml | Set-Content -Encoding utf8 $WinswXml

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
}
