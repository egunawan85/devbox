<#
.SYNOPSIS
  win-test-run.ps1 — the box-side half of the win-test appliance. Runs one Windows-only
  test suite against a synced worktree, under a box-wide lock, and records a heartbeat so
  the idle-monitor knows when it's safe to deallocate.

.DESCRIPTION
  Invoked over SSH by claude-config/scripts/win-test.sh (the Linux orchestrator). It never
  starts or stops the VM — lifecycle is the idle-monitor's job (spec §L). Responsibilities:

    1. Acquire a box-wide lock. The integration suites share a single (localdb)\MSSQLLocalDB
       with a fixed 'TestRunegate' catalog, so two runs at once would clobber the same DB.
       Concurrent invocations queue here rather than corrupt each other.
    2. Ensure LocalDB is up (SqlLocalDB start MSSQLLocalDB).
    3. dotnet test the suite's projects, emitting a TRX + console log into
       <RepoDir>/tmp/win-test/ (win-test.sh rsyncs that back).
    4. Release the lock, bump the heartbeat, and garbage-collect stale per-branch dirs.

  Exit code mirrors `dotnet test` (0 = all passed).

.PARAMETER RepoDir   The synced worktree on the box, e.g. C:\ci\my-branch.
.PARAMETER Suite     unit | integration | smoke | all  (default: integration)
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $RepoDir,
  [ValidateSet('unit','integration','smoke','all')] [string] $Suite = 'integration'
)
$ErrorActionPreference = 'Stop'

# Appliance state lives outside any one branch dir so it survives GC and --clean.
$StateDir  = 'C:\ci\.win-test'
$LockFile  = Join-Path $StateDir 'run.lock'
$Heartbeat = Join-Path $StateDir 'last-activity'
$CiRoot    = Split-Path $RepoDir -Parent
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

function Touch-Heartbeat { Set-Content -Path $Heartbeat -Value (Get-Date -Format o) }

# --- 1. box-wide lock (serialize concurrent runs) --------------------------------
# A single-holder lock via an exclusively-created file handle; wait up to 30 min for a
# peer run to finish. Touch-Heartbeat while waiting so the idle-monitor never deallocates
# a box that has a run queued behind the lock.
$lock = $null
$deadline = (Get-Date).AddMinutes(30)
while ($true) {
  try { $lock = [System.IO.File]::Open($LockFile, 'CreateNew', 'Write', 'None'); break }
  catch [System.IO.IOException] {
    if ((Get-Date) -gt $deadline) { throw "win-test-run: timed out waiting for the box lock (another run held it >30 min)" }
    Touch-Heartbeat
    Write-Host "win-test-run: another run holds the box lock; waiting…"
    Start-Sleep -Seconds 10
  }
}

try {
  Touch-Heartbeat

  # --- 2. LocalDB up -------------------------------------------------------------
  Write-Host "win-test-run: ensuring MSSQLLocalDB is started…"
  & SqlLocalDB start MSSQLLocalDB | Out-Null

  # --- 3. run the suite ----------------------------------------------------------
  # These are CLASSIC (packages.config) net4x solutions, so the recipe is the repos' own
  # (runegate audit/TEST_STRATEGY.md + CLAUDE.md): nuget restore -> msbuild build ->
  # dotnet test --no-build per suite project. NOT a bare `dotnet test` (that assumes
  # PackageReference restore and would fail on packages.config). Tool paths resolve via
  # vswhere (VS BuildTools). Verified/tuned on the first Slice-1 run against a real box.
  $results = Join-Path $RepoDir 'tmp\win-test'
  New-Item -ItemType Directory -Force -Path $results | Out-Null

  # Prefer a dedicated *.Tests.sln (kash-cards has one); else the single root *.sln.
  $sln = Get-ChildItem $RepoDir -Filter *.Tests.sln -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $sln) { $sln = Get-ChildItem $RepoDir -Filter *.sln -ErrorAction SilentlyContinue | Select-Object -First 1 }
  if (-not $sln) { throw "win-test-run: no .sln found under $RepoDir" }

  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  $msbuild = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild `
                        -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
  if (-not $msbuild) { throw "win-test-run: MSBuild not found via vswhere" }

  Write-Host "win-test-run: nuget restore $($sln.Name)"
  & nuget restore $sln.FullName -NonInteractive
  if ($LASTEXITCODE -ne 0) { throw "win-test-run: nuget restore failed ($LASTEXITCODE)" }
  Touch-Heartbeat

  Write-Host "win-test-run: msbuild build $($sln.Name)"
  & $msbuild $sln.FullName /t:Build /p:Configuration=Debug /m /verbosity:minimal `
      *>&1 | Tee-Object -FilePath (Join-Path $results 'build.log')
  if ($LASTEXITCODE -ne 0) { throw "win-test-run: msbuild build failed ($LASTEXITCODE)" }
  Touch-Heartbeat

  # Select test projects by naming convention (*.Tests.<Suite>.csproj); 'all' runs every
  # *.Tests.*.csproj EXCEPT E2E (live staging + real secrets — the scheduled GH Action's
  # job, not this appliance's — spec §X2).
  $pattern = if ($Suite -eq 'all') { '*.Tests.*.csproj' } else { "*.Tests.$Suite.csproj" }
  $projects = Get-ChildItem -Path $RepoDir -Recurse -Filter $pattern -ErrorAction SilentlyContinue |
              Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' -and $_.Name -notmatch '\.Tests\.E2E\.' }
  if (-not $projects) { throw "win-test-run: no test projects matched '$pattern' under $RepoDir" }

  $failed = 0
  foreach ($p in $projects) {
    $name = [IO.Path]::GetFileNameWithoutExtension($p.Name)
    Write-Host "win-test-run: dotnet test $name"
    & dotnet test $p.FullName --no-build --no-restore --nologo `
        --logger "trx;LogFileName=$name.trx" --results-directory $results `
        *>&1 | Tee-Object -FilePath (Join-Path $results "$name.log") -Append
    if ($LASTEXITCODE -ne 0) { $failed++ }
    Touch-Heartbeat
  }

  if ($failed -gt 0) { Write-Host "win-test-run: $failed project(s) failed."; $script:rc = 1 }
  else               { Write-Host "win-test-run: all suites passed.";        $script:rc = 0 }
}
finally {
  # --- 4. release + heartbeat + GC ------------------------------------------------
  Touch-Heartbeat
  if ($lock) { $lock.Close(); Remove-Item $LockFile -Force -ErrorAction SilentlyContinue }

  # Self-GC: drop per-branch dirs untouched > CI_RETAIN_DAYS, and any whose branch is gone.
  # Best-effort — never let cleanup fail a test run.
  try {
    $retainDays = [int]($env:CI_RETAIN_DAYS   | ForEach-Object { $_ }); if (-not $retainDays) { $retainDays = 14 }
    $cutoff = (Get-Date).AddDays(-$retainDays)
    Get-ChildItem -Path $CiRoot -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -ne '.win-test' -and $_.LastWriteTime -lt $cutoff } |
      ForEach-Object { Write-Host "win-test-run: GC stale $($_.Name)"; Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
  } catch { Write-Host "win-test-run: GC skipped ($_)" }
}

exit $script:rc
