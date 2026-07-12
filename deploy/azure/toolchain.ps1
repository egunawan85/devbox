# toolchain.ps1 -- Layer B: the runegate / qrypto-omni build toolchain for the Windows devbox.
#
# Run on the box via `az vm run-command` (as SYSTEM) by `devbox -p windows toolchain` -- NOT
# at first boot, to keep provision.ps1 small and because these installs are long (VS Build
# Tools alone is ~20 min). Installs the classic .NET Framework build stack the repos need:
# VS 2022 Build Tools (Web workload + FW 4.7.2/4.6.2 targeting packs), NuGet CLI, SQL Server
# Express LocalDB (the unit/integration suites), SQL Server Express with TCP pinned to
# localhost:1433 (loopback integrated auth -- the qrypto-omni E2E deploy runs its DB ops
# against `localhost,1433 -E`, which LocalDB's dynamic user-mode instance can't serve),
# PowerShell 7, Azure CLI, go-sqlcmd, rsync (the receive end of the win-test per-run
# source sync).
#
# winget is absent on Windows Server 2022, so this uses Chocolatey (installed by
# provision.ps1) + direct vendor installers. Idempotent where the installers allow.
# Logs to C:\devbox-toolchain.log. NOTE: VS Build Tools may exit 3010 (success, reboot
# pending) -- treated as success; a reboot may be needed before first build.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Start-Transcript -Path 'C:\devbox-toolchain.log' -Append | Out-Null
try {
  $choco = Join-Path $env:ProgramData 'chocolatey\bin\choco.exe'
  if (-not (Test-Path $choco)) { throw "Chocolatey not found ($choco) -- run provision.ps1 first" }

  # Fresh-run signal: clear prior completion markers so the CLI's post-run check (and the rev
  # it records, see os_install_toolchain) can only reflect THIS run, never a stale success.
  Remove-Item -Path 'C:\devbox-toolchain-ready','C:\devbox-toolchain-rev' -Force -ErrorAction SilentlyContinue

  # --- PowerShell 7, Azure CLI, go-sqlcmd, NuGet CLI, VC++ runtime, rsync (Chocolatey) ---
  # vcredist140 = the VS2015-2022 VC++ runtime; required by the SQL LocalDB engine (sqlservr.exe
  # won't start without it -- it was the missing piece when LocalDB was installed by hand).
  # rsync (cwRsync) is the receive end of the win-test source sync (win-test.spec S1): the Linux
  # runner's rsync-over-SSH spawns `rsync --server` here through the box's default PowerShell
  # shell, so rsync.exe must resolve on the MACHINE PATH of a fresh non-interactive SSH session.
  # The choco shim dir (ProgramData\chocolatey\bin) is already on that PATH; the sshd restart
  # below propagates it to new sessions.
  & $choco install -y --no-progress powershell-core azure-cli sqlcmd nuget.commandline vcredist140 rsync
  if ($LASTEXITCODE -ne 0) { throw "choco toolchain install failed: exit $LASTEXITCODE" }
  # Fail loud NOW (not at the first /win-test sync) if the rsync shim didn't land or can't run.
  # Capture output in full, THEN truncate: piping a native command into Select-Object -First
  # kills its pipe mid-write, which fails rsync (exit -1) even when it works.
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
  $rsyncVer = & rsync --version 2>&1
  if ($LASTEXITCODE -ne 0) { throw "rsync installed but does not run: exit $LASTEXITCODE" }
  Write-Output ($rsyncVer | Select-Object -First 1)

  # --- VS 2022 Build Tools: Web workload + .NET FW targeting packs (verified recipe) ---
  $bt = Join-Path $env:TEMP 'vs_buildtools.exe'
  Invoke-WebRequest -UseBasicParsing -Uri 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile $bt
  $btArgs = @(
    '--quiet','--wait','--norestart','--nocache',
    '--add','Microsoft.VisualStudio.Workload.WebBuildTools',
    '--add','Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools',
    '--add','Microsoft.VisualStudio.Component.TestTools.BuildTools',
    '--add','Microsoft.Net.Component.4.7.2.TargetingPack',
    '--add','Microsoft.Net.Component.4.6.2.TargetingPack',
    '--includeRecommended'
  )
  $p = Start-Process -FilePath $bt -ArgumentList $btArgs -Wait -PassThru
  if ($p.ExitCode -notin 0,3010) { throw "VS Build Tools failed: exit $($p.ExitCode)" }
  Write-Output "VS Build Tools exit=$($p.ExitCode) (3010 = reboot pending)"

  # --- SQL Server Express LocalDB: the integration tests connect to (localdb)\MSSQLLocalDB ---
  # (an on-demand, user-mode instance -- no service or TCP port, unlike a full Express instance).
  if (-not (Get-Command SqlLocalDB.exe -ErrorAction SilentlyContinue)) {
    & $choco install -y --no-progress sqllocaldb
    if ($LASTEXITCODE -ne 0) { throw "SQL LocalDB (choco sqllocaldb) install failed: exit $LASTEXITCODE" }
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
    Write-Output "SQL Server Express LocalDB installed"
  } else { Write-Output "SQL LocalDB already present -- skipping install" }
  # Ensure the default instance the tests use exists + is started (both idempotent).
  & SqlLocalDB.exe create MSSQLLocalDB 2>$null
  & SqlLocalDB.exe start  MSSQLLocalDB 2>$null
  Write-Output "LocalDB instance MSSQLLocalDB ready -- connect via (localdb)\MSSQLLocalDB"

  # --- SQL Server Express: a real TCP endpoint on localhost:1433 (the E2E deploy needs it) ---
  # Additive to the LocalDB above: the unit/integration suites keep (localdb)\MSSQLLocalDB,
  # but the qrypto-omni E2E deploy (deploy-iis.ps1) runs its DB ops against `localhost,1433
  # -E` -- LocalDB has no fixed TCP port and cannot satisfy that. Loopback-only exposure: the
  # NSG opens nothing but SSH and Windows Firewall does not filter loopback, so no inbound
  # rule is added. Integrated auth only, no SQL logins: Express setup makes the installing
  # user (SYSTEM, under run-command) sysadmin, and BUILTIN\Administrators is granted below
  # so the SSH user's trusted connections work.
  if (-not (Get-Service 'MSSQL$SQLEXPRESS' -ErrorAction SilentlyContinue)) {
    & $choco install -y --no-progress sql-server-express
    if ($LASTEXITCODE -ne 0) { throw "SQL Server Express (choco) install failed: exit $LASTEXITCODE" }
    Get-Service 'MSSQL$SQLEXPRESS' -ErrorAction Stop | Out-Null
    Write-Output 'SQL Server Express installed (service MSSQL$SQLEXPRESS)'
  } else { Write-Output 'SQL Server Express already present -- skipping install' }
  # A named instance defaults to TCP disabled / a dynamic port; pin a static 1433. With the
  # default ListenOnAllIPs=1 the engine reads the IPAll pair. The settings only take effect
  # on service (re)start, hence the unconditional restart (cheap; this layer re-runs only
  # when this script changes).
  $sqlInst = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').SQLEXPRESS
  $tcpKey  = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$sqlInst\MSSQLServer\SuperSocketNetLib\Tcp"
  Set-ItemProperty -Path $tcpKey -Name Enabled -Value 1
  Set-ItemProperty -Path "$tcpKey\IPAll" -Name TcpDynamicPorts -Value ''
  Set-ItemProperty -Path "$tcpKey\IPAll" -Name TcpPort -Value '1433'
  Set-Service 'MSSQL$SQLEXPRESS' -StartupType Automatic
  Restart-Service 'MSSQL$SQLEXPRESS' -Force
  # Trusted connections for the SSH user: the devbox user is a box Administrator, so grant
  # sysadmin to the BUILTIN\Administrators group login (no per-user login to keep in sync;
  # ALTER SERVER ROLE ADD MEMBER is a no-op when already a member). Retried because the
  # engine accepts TCP a few seconds after the service reports Running; on success this
  # doubles as the fail-loud proof that 1433 + integrated auth actually work.
  $grantSql = "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'BUILTIN\Administrators') CREATE LOGIN [BUILTIN\Administrators] FROM WINDOWS; ALTER SERVER ROLE sysadmin ADD MEMBER [BUILTIN\Administrators];"
  $sqlUp = $false
  # EAP=Continue for the probes only: sqlcmd writes its connect errors to stderr, which the
  # script-wide EAP=Stop would turn into a throw on the FIRST warm-up failure instead of a
  # retry. $LASTEXITCODE is the verdict that matters.
  $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  foreach ($i in 1..12) {
    & sqlcmd -S 'localhost,1433' -E -Q $grantSql 2>$null
    if ($LASTEXITCODE -eq 0) { $sqlUp = $true; break }
    Start-Sleep -Seconds 5
  }
  $ErrorActionPreference = $prevEap
  if (-not $sqlUp) { throw 'SQL Server Express is not reachable on localhost,1433 with integrated auth after install' }
  Write-Output 'SQL Server Express listening on localhost:1433 (integrated auth verified)'

  # Restart sshd so new SSH sessions pick up the updated machine PATH (pwsh/az/sqlcmd were
  # added by MSI after sshd captured its environment at provision time).
  Restart-Service sshd
  Set-Content -Path 'C:\devbox-toolchain-ready' -Value (Get-Date -Format o) -Encoding ascii
  Write-Output 'devbox toolchain install complete'
} catch {
  Write-Error "devbox toolchain FAILED: $_"
  throw
} finally {
  Stop-Transcript | Out-Null
}
