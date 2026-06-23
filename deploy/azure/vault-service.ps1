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
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ver  = '2.5.4'
$dir  = 'C:\Program Files\OpenBao'
$bao  = Join-Path $dir 'bao.exe'
$data = 'C:\ProgramData\devbox\openbao-data'
$cfg  = 'C:\ProgramData\devbox\openbao.hcl'
New-Item -ItemType Directory -Force -Path $dir, $data, (Split-Path $cfg) | Out-Null
# Lock C:\ProgramData\devbox down BEFORE any secret is written into it. The default
# %ProgramData% ACL grants BUILTIN\Users read+create (inherited); without this, the
# devbox-app token (vault.env), the watchdog script, and the manifest would be readable
# and the SYSTEM watchdog script replaceable by any non-admin local process. Restrict to
# SYSTEM + Administrators (full) + eddyg (read), inheritance off so children inherit it.
icacls (Split-Path $cfg) /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' 'eddyg:(OI)(CI)R' | Out-Null

# --- Install bao.exe (pinned + checksum-verified) if absent ---
if (-not (Test-Path $bao)) {
  $base = "https://github.com/openbao/openbao/releases/download/v$ver"
  $asset = "bao_${ver}_Windows_x86_64.zip"
  $zip = Join-Path $env:TEMP $asset
  $wc = New-Object Net.WebClient   # DownloadString returns a string (Invoke-WebRequest .Content
  $wc.DownloadFile("$base/$asset", $zip)                       # is a byte[] for octet-stream)
  $sums = $wc.DownloadString("$base/checksums-windows.txt")
  $want = $null
  foreach ($l in ($sums -split "[\r\n]+")) {
    $f = @(($l.Trim() -split '\s+') | Where-Object { $_ })
    if ($f.Count -ge 2 -and $f[-1] -eq $asset) { $want = $f[0].ToLower(); break }
  }
  if (-not $want) { throw "checksum for $asset not found (fetched $($sums.Length) bytes)" }
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
if (-not (Test-Path $nssm)) { & $choco install -y --no-progress nssm --version=2.24 | Out-Null }  # pin: NSSM launches bao as SYSTEM
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
  try { $status = (Invoke-RestMethod -UseBasicParsing -Uri 'http://127.0.0.1:8200/v1/sys/seal-status' | ConvertTo-Json -Compress); break }
  catch { Start-Sleep -Seconds 1 }
}
Write-Output "__VAULTJSON__${status}__ENDVAULTJSON__"
