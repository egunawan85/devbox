# vault-service.ps1 -- install OpenBao (bao.exe) and run it as a Windows Service that
# auto-starts (sealed) on every boot. Run via az run-command (SYSTEM). The Windows analog of
# the Linux systemd unit (spec E7): prod mode, `file` storage (encrypted at rest), listener
# bound to 127.0.0.1 only -- the SSH login is the access gate -- TLS off, disable_mlock.
# Pinned version + SHA256 verification, mirroring the Linux cloud-init discipline.
#
# Pure ASCII (non-ASCII corrupts over run-command -- see toolchain.ps1). Emits the vault's
# seal-status JSON between markers so the operator CLI parses it cleanly.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ver  = '2.5.4'
$dir  = 'C:\Program Files\OpenBao'
$bao  = Join-Path $dir 'bao.exe'
$data = 'C:\ProgramData\devbox\openbao-data'
$cfg  = 'C:\ProgramData\devbox\openbao.hcl'
New-Item -ItemType Directory -Force -Path $dir, $data, (Split-Path $cfg) | Out-Null

# --- Install bao.exe (pinned + checksum-verified) if absent ---
if (-not (Test-Path $bao)) {
  $base = "https://github.com/openbao/openbao/releases/download/v$ver"
  $asset = "bao_${ver}_Windows_x86_64.zip"
  $zip = Join-Path $env:TEMP $asset
  Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile $zip
  $sums = (Invoke-WebRequest -UseBasicParsing -Uri "$base/checksums-windows.txt").Content
  $line = ($sums -split "`n" | Where-Object { $_ -match [regex]::Escape($asset) } | Select-Object -First 1)
  if (-not $line) { throw "checksum line for $asset not found" }
  $want = $line.Trim().Split(' ')[0].ToLower()
  $got  = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
  if ($got -ne $want) { throw "bao zip checksum mismatch: got $got want $want" }
  Expand-Archive -Path $zip -DestinationPath $dir -Force
  Remove-Item $zip -Force
}

# --- Prod HCL config (write only if absent, to not disturb existing sealed data) ---
if (-not (Test-Path $cfg)) {
  $dataFwd = $data -replace '\\', '/'
  @"
storage "file" {
  path = "$dataFwd"
}
listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}
disable_mlock = true
ui            = false
"@ | Set-Content -Path $cfg -Encoding ascii
}

# --- Register the service via NSSM (wraps the console `bao server` as a Windows Service) ---
$choco = Join-Path $env:ProgramData 'chocolatey\bin\choco.exe'
$nssm  = Join-Path $env:ProgramData 'chocolatey\bin\nssm.exe'
if (-not (Test-Path $nssm)) { & $choco install -y --no-progress nssm | Out-Null }
if (-not (Get-Service devbox-vault -ErrorAction SilentlyContinue)) {
  & $nssm install devbox-vault $bao server "-config=$cfg" | Out-Null
  & $nssm set devbox-vault AppDirectory $dir | Out-Null
  & $nssm set devbox-vault AppStdout 'C:\ProgramData\devbox\openbao.log' | Out-Null
  & $nssm set devbox-vault AppStderr 'C:\ProgramData\devbox\openbao.log' | Out-Null
}
Set-Service devbox-vault -StartupType Automatic
if ((Get-Service devbox-vault).Status -ne 'Running') { Start-Service devbox-vault }

# --- Wait for the API, then emit seal-status JSON between markers ---
$status = '{"error":"vault server not responding (see C:\\ProgramData\\devbox\\openbao.log)"}'
foreach ($i in 1..30) {
  try { $status = (Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8200/v1/sys/seal-status').Content; break }
  catch { Start-Sleep -Seconds 1 }
}
Write-Output "__VAULTJSON__${status}__ENDVAULTJSON__"
