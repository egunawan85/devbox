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
    '--add','Microsoft.Net.Component.4.7.2.TargetingPack',
    '--add','Microsoft.Net.Component.4.6.2.TargetingPack',
    '--includeRecommended'
  )
  $p = Start-Process -FilePath $bt -ArgumentList $btArgs -Wait -PassThru
  if ($p.ExitCode -notin 0,3010) { throw "VS Build Tools failed: exit $($p.ExitCode)" }
  Write-Output "VS Build Tools exit=$($p.ExitCode) (3010 = reboot pending)"

  # --- SQL Server Express: SQLEngine, mixed-mode + static TCP/1433 (the repos use SQL auth) ---
  if (-not (Get-Service 'MSSQL$SQLEXPRESS' -ErrorAction SilentlyContinue)) {
    # Random sa password (the repos use a least-privilege app login, not sa; sa stays unused).
    $sa = -join (1..28 | ForEach-Object { [char]((65..90)+(97..122)+(48..57) | Get-Random) }) + 'Aa1!'
    $ssei = Join-Path $env:TEMP 'SQL2022-SSEI-Expr.exe'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://go.microsoft.com/fwlink/?linkid=2216019' -OutFile $ssei
    $media = 'C:\SQLEXPR-media'
    # SSEI /ACTION=Download fetches a self-extracting package (SQLEXPR_x64_ENU.exe); run it
    # directly with the unattended switches (it extracts and runs setup.exe with them).
    & $ssei /ACTION=Download /MEDIAPATH=$media /MEDIATYPE=Core /QUIET
    if ($LASTEXITCODE -ne 0) { throw "SQL Express media download failed: exit $LASTEXITCODE" }
    $pkg = Get-ChildItem -Path $media -Recurse -Filter 'SQLEXPR*.exe' | Select-Object -First 1
    if (-not $pkg) { throw ("SQL Express package not found under $media; contents: " + ((Get-ChildItem $media -Recurse -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', ')) }
    $sqlArgs = "/Q /IACCEPTSQLSERVERLICENSETERMS /ACTION=Install /FEATURES=SQLEngine /INSTANCENAME=SQLEXPRESS /SECURITYMODE=SQL /SAPWD=$sa /TCPENABLED=1 /SQLSYSADMINACCOUNTS=`"BUILTIN\Administrators`""
    $sp = Start-Process -FilePath $pkg.FullName -ArgumentList $sqlArgs -Wait -PassThru
    if ($sp.ExitCode -notin 0,3010) { throw "SQL Express install failed: exit $($sp.ExitCode)" }
    Write-Output "SQL Express installed (mixed-mode)"
  } else { Write-Output "SQL Express already present -- skipping install" }
  # Pin TCP to static 1433 (idempotent; runs whether we just installed or it pre-existed). Named
  # instances default to a dynamic port + SQL Browser, but the repos connect to 127.0.0.1:1433.
  $inst = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').SQLEXPRESS
  $tcp = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$inst\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"
  Set-ItemProperty -Path $tcp -Name TcpDynamicPorts -Value ''
  Set-ItemProperty -Path $tcp -Name TcpPort -Value '1433'
  Set-Service 'MSSQL$SQLEXPRESS' -StartupType Automatic
  Restart-Service 'MSSQL$SQLEXPRESS'
  Write-Output "SQL Express TCP pinned to static 1433"

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
