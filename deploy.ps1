Param(
  [switch]$DebugMode,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
if ($DebugMode) { $VerbosePreference = 'Continue' } else { $VerbosePreference = 'SilentlyContinue' }

# ---------- Logging helpers ----------
function _ts { (Get-Date).ToString('HH:mm:ss.fff') }
function Log    { param([string]$m) Write-Host ("[{0}] [INFO ] {1}" -f (_ts), $m) }
function Warn   { param([string]$m) Write-Warning ("[{0}] {1}" -f (_ts), $m) }
function Err    { param([string]$m) Write-Host ("[{0}] [ERROR] {1}" -f (_ts), $m) -ForegroundColor Red }
function CmdLog { param([string]$Exe, [string[]]$ArgList)
  $argLine = ($ArgList | ForEach-Object { $_ }) -join ' '
  Write-Host ("[{0}] [CMD  ] {1} {2}" -f (_ts), $Exe, $argLine) -ForegroundColor Cyan
}

# Run a command with args array; stream output; fail on non-zero exit
function Run {
  param([string]$Exe, [string[]]$ArgList, [switch]$AllowFail)

  CmdLog $Exe $ArgList

  if ($DryRun) { Log "DryRun: skipping execution."; return @{ ExitCode = 0; Output = @() } }

  # PS 5.1: native stderr creates (non-terminating) error records; with 'Stop' they'd become terminating.
  # Temporarily relax EAP around the native call so we can inspect $LASTEXITCODE ourselves.
  $prevEAP = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $out = & $Exe @ArgList 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prevEAP
  }

  if ($out) { $out | ForEach-Object { Write-Host $_ } }
  if (-not $AllowFail -and $code -ne 0) { throw ("{0} exited with code {1}" -f $Exe, $code) }

  return @{ ExitCode = $code; Output = $out }
}

# ---------- Load .env ----------
$envFile = Join-Path $PSScriptRoot '.env'
if (Test-Path $envFile) {
  Log ("Loading .env from {0}" -f $envFile)
  Get-Content $envFile | ForEach-Object {
    if ($_ -match '^\s*(#|$)') { return }
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
      $name = $matches[1]; $value = $matches[2]
      [Environment]::SetEnvironmentVariable($name, $value)
      if ($DebugMode) { Log ("  set {0}={1}" -f $name, $value) }
    }
  }
} else {
  Warn "No .env found; falling back to process environment."
}

# ---------- Settings ----------
$deployHost = $env:DEPLOY_HOST
$deployUser = $env:DEPLOY_USER
$deployPath = $env:DEPLOY_PATH

if (-not $deployHost -or -not $deployUser -or -not $deployPath) {
  throw "Missing DEPLOY_HOST/DEPLOY_USER/DEPLOY_PATH. Set them in .env or environment."
}
Log ("Target: {0}@{1}" -f $deployUser, $deployHost)
Log ("Path  : {0}" -f $deployPath)

# ---------- Tool checks ----------
$sshExe = (Get-Command ssh -ErrorAction SilentlyContinue).Source
$scpExe = (Get-Command scp -ErrorAction SilentlyContinue).Source
if (-not $sshExe) { throw "ssh not found in PATH" }
if (-not $scpExe) { throw "scp not found in PATH" }
Log ("ssh   : {0}" -f $sshExe)
Log ("scp   : {0}" -f $scpExe)

# ---------- SSH options (avoid stalls) ----------
$remoteUserHost = ("{0}@{1}" -f $deployUser, $deployHost)
$remotePath     = ($deployPath.TrimEnd('/')) + "/"

# Compatibility-friendly options for Windows OpenSSH
$sshCommon = @(
  "-o","BatchMode=yes",
  "-o","StrictHostKeyChecking=no",
  "-o","ConnectTimeout=10",
  "-o","ServerAliveInterval=10",
  "-o","ServerAliveCountMax=3"
)

# ---------- Connectivity probe ----------
Log "Testing SSH connectivity..."
$probe = Run $sshExe ($sshCommon + @($remoteUserHost, "echo __ok__"))
if (-not (($probe.Output | Out-String) -match "__ok__")) {
  throw "SSH connectivity test failed (no '__ok__' seen). Check keys/host reachability."
}

# ---------- Ensure remote directory ----------
Log "Ensuring remote directory exists..."
Run $sshExe ($sshCommon + @($remoteUserHost, ("mkdir -p '{0}'" -f $remotePath)))

# ---------- Copy contents of ./public ----------
$localDir = Join-Path $PSScriptRoot 'public/.'
if (-not (Test-Path $localDir)) {
  throw ("Local path not found: {0}  (do you have a 'public' folder next to deploy.ps1?)" -f $localDir)
}

# scp with verbose (-v), compression (-C), recursive (-r)
# Note: modern scp may use the sftp subsystem under the hood — you'll see that in verbose logs; it's fine.
$scpArgs = @(
  "-v","-C","-r",
  "-o","StrictHostKeyChecking=no",
  "-o","BatchMode=yes",
  $localDir,
  ("{0}:{1}" -f $remoteUserHost, $remotePath)
)

Log "Copying site files with scp..."
Run $scpExe $scpArgs

Log ("Deployed to {0}@{1}:{2}" -f $deployUser, $deployHost, $deployPath)
