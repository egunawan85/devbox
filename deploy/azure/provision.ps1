# devbox first-boot setup (Azure / Windows Server 2022).
#
# This file is a TEMPLATE rendered by the devbox CLI (os_render_firstboot), which fills in
# the SSH port and the authorized public keys, then runs it on the box via the Azure Custom
# Script Extension (as SYSTEM) right after VM create. It installs + hardens OpenSSH (key-only,
# non-default port, agent forwarding, no RDP path), pins GitHub's host keys, installs the base
# toolchain, and writes the readiness marker the CLI polls. It stores NO secret.
#
# The heavy project toolchain (VS Build Tools, SQL Express) is NOT here — that installs later
# over SSH, once the box is reachable, to keep this bootstrap script small.
$ErrorActionPreference = 'Stop'
Start-Transcript -Path 'C:\devbox-provision.log' -Append | Out-Null
try {
  $port = '__SSH_PORT__'

  # --- OpenSSH Server (built-in Windows capability) ---
  Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
  Set-Service -Name sshd      -StartupType Automatic
  Set-Service -Name ssh-agent -StartupType Automatic
  Start-Service ssh-agent

  $sshDir = Join-Path $env:ProgramData 'ssh'
  New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

  # --- Authorized keys. The login user is the VM admin, and Windows OpenSSH reads admin
  #     users' keys from administrators_authorized_keys (NOT ~/.ssh), which must be ACL'd
  #     to SYSTEM + Administrators only. ---
  $akf = Join-Path $sshDir 'administrators_authorized_keys'
  $keys = @'
__AUTHORIZED_KEYS_BLOCK__
'@
  Set-Content -Path $akf -Value $keys -Encoding ascii
  icacls.exe $akf /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null

  # --- sshd config. Write a COMPLETE config rather than editing a default: the OpenSSH
  #     capability may not have generated the default sshd_config yet at this point (sshd
  #     isn't started until the end), so there is nothing to merge with. Crucially, the
  #     `Match Group administrators` block points admin users (our login user IS the VM
  #     admin) at administrators_authorized_keys — without it sshd reads ~/.ssh and denies. ---
  $cfg = Join-Path $sshDir 'sshd_config'
  $cfgContent = @"
Port $port
PasswordAuthentication no
PubkeyAuthentication yes
AllowAgentForwarding yes
X11Forwarding no
AuthorizedKeysFile .ssh/authorized_keys
Subsystem sftp sftp-server.exe

Match Group administrators
       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
"@
  Set-Content -Path $cfg -Value $cfgContent -Encoding ascii

  # --- Default SSH shell = Windows PowerShell (Layer B may repoint to pwsh 7 later) ---
  New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
  New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
    -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null

  # --- OS firewall: allow our SSH port; make sure RDP is not exposed at the OS layer either
  #     (the Azure NSG already denies it; this is defense in depth). ---
  Get-NetFirewallRule -Name 'devbox-sshd' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
  New-NetFirewallRule -Name 'devbox-sshd' -DisplayName "OpenSSH ($port)" -Enabled True `
    -Direction Inbound -Protocol TCP -Action Allow -LocalPort $port | Out-Null
  Disable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue

  # --- Pin GitHub's host keys (over TLS) so the box's git clone needs no TOFU ---
  try {
    $meta = Invoke-RestMethod -Uri 'https://api.github.com/meta' -UseBasicParsing
    $kh = Join-Path $sshDir 'ssh_known_hosts'
    ($meta.ssh_keys | ForEach-Object { "github.com $_" }) | Set-Content -Path $kh -Encoding ascii
  } catch { Write-Warning "could not seed GitHub host keys: $_" }

  # --- Base toolchain via Chocolatey (winget is absent on Server 2022) ---
  Set-ExecutionPolicy Bypass -Scope Process -Force
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
  $choco = Join-Path $env:ProgramData 'chocolatey\bin\choco.exe'
  & $choco install -y --no-progress git gh nodejs-lts
  # Refresh PATH so node/npm resolve in this session, then install the Claude Code CLI.
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
  & npm install -g @anthropic-ai/claude-code

  # --- Apply config and (re)start sshd on the right port ---
  Restart-Service sshd

  # --- Readiness marker the CLI waits on (os_box_ready) ---
  Set-Content -Path 'C:\devbox-ready' -Value (Get-Date -Format o) -Encoding ascii
  Write-Output 'devbox provision complete'
} catch {
  Write-Error "devbox provision FAILED: $_"
  throw
} finally {
  Stop-Transcript | Out-Null
}
