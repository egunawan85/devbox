# toolchain.ps1 -- Layer B: the runegate / qrypto-omni build toolchain for the Windows devbox.
#
# Run on the box via `az vm run-command` (as SYSTEM) by `devbox -p windows toolchain` -- NOT
# at first boot, to keep provision.ps1 small and because these installs are long (VS Build
# Tools alone is ~20 min). Installs the classic .NET Framework build stack the repos need:
# VS 2022 Build Tools (Web workload + FW 4.7.2/4.6.2 targeting packs), NuGet CLI, SQL Server
# Express (mixed-mode + TCP, for the repos' SQL auth), PowerShell 7, Azure CLI, go-sqlcmd.
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

  # --- PowerShell 7, Azure CLI, go-sqlcmd, NuGet CLI (Chocolatey) ---
  & $choco install -y --no-progress powershell-core azure-cli sqlcmd nuget.commandline
  if ($LASTEXITCODE -ne 0) { throw "choco toolchain install failed: exit $LASTEXITCODE" }

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
