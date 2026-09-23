# Tests for install.ps1 under Windows PowerShell 5.1.
#
# Why this exists: install.ps1 is written for 5.1 but was only exercised in
# pwsh 7. The two differ in exactly the place the enrollment exchange depends
# on -- how a failed HTTP call surfaces its status and body
# ($_.Exception.Response, $_.ErrorDetails). Loads the installer's functions
# from its AST instead of running the script, which would really install.
$ErrorActionPreference = 'Stop'
$script:fail = 0
function Check([string]$Name, [bool]$Cond, [string]$Detail = '') {
  if ($Cond) { Write-Host "PASS  $Name" }
  else { Write-Host "FAIL  $Name  $Detail"; $script:fail++ }
}
function B64U([string]$s) {
  [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
function New-Tok($claims) {
  return (B64U '{"alg":"RS256","typ":"JWT"}') + '.' + (B64U ($claims | ConvertTo-Json -Compress)) + '.sig'
}

Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
Check 'running on Windows PowerShell 5.1' ($PSVersionTable.PSVersion.Major -eq 5)

# --- 1. the whole file parses under 5.1 --------------------------------------
$path = Join-Path $PSScriptRoot '..\install.ps1'
$tk = $null; $pe = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tk, [ref]$pe)
foreach ($e in $pe) { Write-Host "  parse error line $($e.Extent.StartLineNumber): $($e.Message)" }
Check 'install.ps1 parses with 0 errors' ($pe.Count -eq 0)

# --- load the installer's own functions --------------------------------------
$want = 'Info', 'Warn', 'Fatal', 'Get-TokenClaims', 'Invoke-EnrollExchange'
$defs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($d in $defs) { if ($want -contains $d.Name) { . ([scriptblock]::Create($d.Extent.Text)) } }
# Fatal really does `exit 1`; make it throw so a test can observe the message.
function Fatal($m) { throw "FATAL: $m" }

# --- 2. Get-TokenClaims -------------------------------------------------------
$legacy = New-Tok @{ sub = 'u1'; host_id = 'host_legacy'; scope = 'agent' }
$enroll = New-Tok @{ sub = 'u1'; host_id = 'host_enr'; scope = 'agent'; typ = 'enroll' }
$c = Get-TokenClaims $legacy
Check 'claims: legacy has no typ' (-not $c.typ)
Check 'claims: legacy host_id read' ($c.host_id -eq 'host_legacy')
Check 'claims: enroll typ read' ((Get-TokenClaims $enroll).typ -eq 'enroll')
$g = Get-TokenClaims 'no-es-un-jwt'
Check 'claims: garbage does not throw' ((-not $g.typ) -and (-not $g.host_id))

# --- 3. the enrollment block, as the installer runs it -----------------------
$blk = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and
    $args[0].Extent.Text.StartsWith('if (-not (Test-Path $IdentityPath))') }, $true) | Select-Object -First 1
Check 'enrollment block found' ($null -ne $blk)
$HubUrl = 'https://hub.invalid'; $HostId = 'host_generated'; $ImportFrom = $null
$IdentityPath = Join-Path $env:TEMP 'sx_identity_test.json'
function Invoke-Block([string]$Paste, [string]$EnvTok) {
  Remove-Item $IdentityPath -ErrorAction SilentlyContinue
  $script:PASTE = $Paste
  if ($EnvTok) { $env:SENTINELX_ENROLL_TOKEN = $EnvTok } else { Remove-Item Env:\SENTINELX_ENROLL_TOKEN -ErrorAction SilentlyContinue }
  try { . ([scriptblock]::Create($blk.Extent.Text)); return 'ok' }
  catch { return $_.Exception.Message }
  finally { Remove-Item Env:\SENTINELX_ENROLL_TOKEN -ErrorAction SilentlyContinue }
}
function Read-Host($p) { return $script:PASTE }   # the user pasting

$r = Invoke-Block "  $legacy  " ''
$id = Get-Content $IdentityPath -Raw | ConvertFrom-Json
Check 'paste legacy (today''s path): written' ($r -eq 'ok')
Check 'paste legacy: token as pasted, trimmed' ($id.token -eq $legacy)
Check 'paste legacy: installer host_id kept' ($id.host_id -eq 'host_generated')

$r = Invoke-Block '' $legacy
$id = Get-Content $IdentityPath -Raw | ConvertFrom-Json
Check 'env legacy: written as-is' (($r -eq 'ok') -and ($id.token -eq $legacy))
Check 'env legacy: token host_id used' ($id.host_id -eq 'host_legacy')

$r = Invoke-Block 'no-es-un-token' ''
Check 'paste garbage: refused' ($r -like 'FATAL: That does not look like an enrollment token*') $r
Check 'paste garbage: nothing written' (-not (Test-Path $IdentityPath))
$r = Invoke-Block '' ''
Check 'paste empty: refused, nothing written' (($r -like 'FATAL:*') -and -not (Test-Path $IdentityPath)) $r

# --- 4. HTTP error handling under 5.1 (the part pwsh 7 could not vouch for) --
$hub = $env:DEV_HUB
function Try-Exchange([string]$Tok, [string]$Hub = $hub) {
  try { return 'CRED:' + (Invoke-EnrollExchange -Hub $Hub -Token $Tok) } catch { return $_.Exception.Message }
}
$r = Try-Exchange 'aaa.bbb.ccc'
Check '5.1 reads HTTP status of a failed call' ($r -like '*HTTP 401*') $r
Check '5.1 reads the JSON error body' ($r -like '*malformed*') $r
$r = Try-Exchange ''
Check '5.1: missing token surfaces its code' ($r -like '*missing_token*') $r
$r = Try-Exchange 'aaa.bbb.ccc' 'https://127.0.0.1:9'
Check '5.1: unreachable hub -> could not reach' ($r -like 'FATAL: Could not reach*') $r

# --- 5. real exchange, then reuse (single-use token from a repo secret) ------
if ($env:ENROLL_TOKEN_OK) {
  $r = Try-Exchange $env:ENROLL_TOKEN_OK
  Check 'real exchange returns a host credential' ($r -like 'CRED:*.*.*') ($r.Substring(0, [Math]::Min(60, $r.Length)))
  if ($r -like 'CRED:*') {
    $cc = Get-TokenClaims $r.Substring(5)
    Check 'credential is typ=host' ($cc.typ -eq 'host')
  }
  $r = Try-Exchange $env:ENROLL_TOKEN_OK
  Check '5.1: reused token -> friendly already-used message' ($r -like 'FATAL: This enrollment token was already used*') $r
} else {
  Write-Host 'SKIP  real exchange (no CI_ENROLL_TOKEN secret)'
}

Remove-Item $IdentityPath -ErrorAction SilentlyContinue
Write-Host ''
if ($script:fail) { Write-Host "$script:fail check(s) FAILED"; exit 1 }
Write-Host 'all checks passed'
