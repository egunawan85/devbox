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
  # Refresh PATH so node/npm resolve in this session, then install the Claude Code CLI into a
  # machine-wide npm prefix and put that prefix on the MACHINE PATH. We run as SYSTEM here (Azure
  # Custom Script Extension), so npm's default global prefix is SYSTEM's per-user %AppData%\npm --
  # a folder on no PATH a normal login (or the `configure` verify) ever reads, leaving the claude
  # shim installed but unresolvable. Choco's nodejs-lts doesn't add %AppData%\npm to PATH either,
  # unlike the official Node MSI. Pinning the prefix to C:\ProgramData\npm and adding it to the
  # machine PATH mirrors how git/gh/node already resolve (and matches the Linux box, where the
  # global bin lands in /usr/bin -- system-wide and on PATH by default). The sshd restart below
  # propagates the new machine PATH to fresh SSH sessions.
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
  $npmPrefix = Join-Path $env:ProgramData 'npm'
  New-Item -ItemType Directory -Force -Path $npmPrefix | Out-Null
  # The package's postinstall downloads the native claude.exe into bin/. --foreground-scripts
  # surfaces it (instead of silently swallowing failures) and --ignore-scripts=false overrides any
  # inherited ignore-scripts=true that would skip the download outright. A skipped/failed
  # postinstall leaves the npm shim pointing at a claude.exe that was never fetched, so `claude`
  # errors with CommandNotFoundException on the missing exe rather than failing the install here.
  & npm install -g --prefix $npmPrefix @anthropic-ai/claude-code --foreground-scripts --ignore-scripts=false
  if ($LASTEXITCODE -ne 0) { throw "npm install of @anthropic-ai/claude-code failed (exit $LASTEXITCODE)" }
  # Assert the native binary the shim execs actually landed -- fail loudly here rather than ship a
  # half-installed CLI that only breaks at first `claude` invocation.
  $claudeExe = Join-Path $npmPrefix 'node_modules\@anthropic-ai\claude-code\bin\claude.exe'
  if (-not (Test-Path $claudeExe)) {
    throw "Claude CLI install incomplete: $claudeExe is missing (npm shim present but native binary not fetched)."
  }
  $machPath = [Environment]::GetEnvironmentVariable('Path','Machine')
  if (($machPath -split ';') -notcontains $npmPrefix) {
    [Environment]::SetEnvironmentVariable('Path', "$machPath;$npmPrefix", 'Machine')
  }

  # --- Make git use the GitHub CLI as its credential helper for github.com (headless-safe) ---
  # Git for Windows defaults to Git Credential Manager, whose 'wincredman' store needs an
  # interactive desktop logon and FAILS over a headless SSH session ("Unable to persist
  # credentials with the 'wincredman' credential store"). Project-repo git auths via `gh` over
  # HTTPS, so point git's helper at gh now -- the token-less equivalent of `gh auth setup-git`
  # (the empty value first resets the inherited GCM helper for that host). After the operator
  # runs `gh auth login`, HTTPS clones work with no GCM/wincredman in the path.
  foreach ($h in 'https://github.com', 'https://gist.github.com') {
    & git config --system "credential.$h.helper" ''
    & git config --system --add "credential.$h.helper" '!gh auth git-credential'
  }

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
