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
    4. Stop LocalDB, release the lock, bump the heartbeat, garbage-collect stale
       per-branch dirs — then write tmp/win-test/done.json, the completion sentinel.

  LocalDB MUST be stopped on every exit path: a lingering sqlservr.exe inherits the SSH
  session's stdio handles, so the orchestrator's blocking ssh never sees EOF and hangs
  long after the suite finished. The sentinel exists for the same reason: it carries the
  real exit code, so the orchestrator can trust "finished" without trusting the SSH
  channel (spec §X6).

  Exit code mirrors `dotnet test` (0 = all passed), except that a project which executes
  zero tests fails the run — vstest exits 0 on "no tests found", which would otherwise be
  a silent pass (spec §X5).

.PARAMETER RepoDir   The synced worktree on the box, e.g. C:\ci\my-branch.
.PARAMETER Suite     unit | integration | smoke | all  (default: integration)
.PARAMETER RunId     Opaque id echoed into done.json so the orchestrator can tell this
                     run's sentinel from a stale one. Optional.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $RepoDir,
  [ValidateSet('unit','integration','smoke','all')] [string] $Suite = 'integration',
  [string] $RunId = ''
)
$ErrorActionPreference = 'Stop'

# Failure until proven otherwise: exit paths that never reach the pass/fail verdict
# (lock timeout, restore/build throw) must still report non-zero in the sentinel.
$script:rc  = 1
$script:err = $null

# Appliance state lives outside any one branch dir so it survives GC and --clean.
$StateDir  = 'C:\ci\.win-test'
$LockFile  = Join-Path $StateDir 'run.lock'
$Heartbeat = Join-Path $StateDir 'last-activity'
$CiRoot    = Split-Path $RepoDir -Parent
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

# Results dir up front — even a run that dies waiting for the lock must be able to leave
# a done.json behind for the orchestrator.
$results = Join-Path $RepoDir 'tmp\win-test'
New-Item -ItemType Directory -Force -Path $results | Out-Null

function Touch-Heartbeat { Set-Content -Path $Heartbeat -Value (Get-Date -Format o) }

$lock = $null
try {
  # --- 1. box-wide lock (serialize concurrent runs) --------------------------------
  # A single-holder lock via an exclusively-created file handle; wait up to 30 min for a
  # peer run to finish. Touch-Heartbeat while waiting so the idle-monitor never deallocates
  # a box that has a run queued behind the lock. Inside the try so even a lock timeout
  # leaves a done.json for the orchestrator.
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
  # job, not this appliance's — spec §X2) and Fixtures (the shared test-data/helpers
  # library the suites borrow from — not a runnable suite: it carries no test adapter,
  # so it executes zero tests and would trip the §X5 zero-tests-fails-loud rule).
  $pattern = if ($Suite -eq 'all') { '*.Tests.*.csproj' } else { "*.Tests.$Suite.csproj" }
  $projects = Get-ChildItem -Path $RepoDir -Recurse -Filter $pattern -ErrorAction SilentlyContinue |
              Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' -and $_.Name -notmatch '\.Tests\.(E2E|Fixtures)\.' }
  if (-not $projects) { throw "win-test-run: no test projects matched '$pattern' under $RepoDir" }

  # Classic packages.config projects keep their VSTest adapter (e.g. xunit.runner.visualstudio)
  # in the repo-local packages dir, which dotnet test does not probe by default — without it
  # discovery finds ZERO tests and still exits 0. Hand vstest every restored adapter dir.
  $adapterArgs = @()
  Get-ChildItem -Path (Join-Path $RepoDir 'packages') -Recurse -Filter '*testadapter.dll' -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty DirectoryName -Unique |
    ForEach-Object { $adapterArgs += @('--test-adapter-path', $_) }

  $failed = 0
  foreach ($p in $projects) {
    $name = [IO.Path]::GetFileNameWithoutExtension($p.Name)
    Write-Host "win-test-run: dotnet test $name"
    & dotnet test $p.FullName --no-build --no-restore --nologo @adapterArgs `
        --logger "trx;LogFileName=$name.trx" --results-directory $results `
        *>&1 | Tee-Object -FilePath (Join-Path $results "$name.log") -Append
    $rcTest = $LASTEXITCODE
    # A project that discovers/executes zero tests must FAIL the run (spec §X5: a run that
    # could not execute is a loud failure, never a silent pass) — vstest exits 0 for it.
    $executed = 0
    $trx = Join-Path $results "$name.trx"
    if (Test-Path $trx) { $executed = [int]([xml](Get-Content $trx)).TestRun.ResultSummary.Counters.executed }
    if ($rcTest -ne 0) { $failed++ }
    elseif ($executed -eq 0) { Write-Host "win-test-run: $name executed ZERO tests — failing loud (spec X5)"; $failed++ }
    Touch-Heartbeat
  }

  if ($failed -gt 0) { Write-Host "win-test-run: $failed project(s) failed."; $script:rc = 1 }
  else               { Write-Host "win-test-run: all suites passed.";        $script:rc = 0 }
}
catch {
  # Record the failure for the sentinel, then rethrow so the console still shows it and
  # pwsh exits non-zero.
  $script:err = "$_"
  throw
}
finally {
  # --- 4. LocalDB down + release + heartbeat + GC + sentinel -----------------------
  # Stop LocalDB BEFORE releasing the lock (a queued run starts it fresh for itself;
  # stopping after release could yank it out from under that run). A lingering
  # sqlservr.exe holds the SSH session's stdio open, which is exactly the hang this
  # teardown prevents. Stop only — never delete the instance; that would discard the
  # warm TestRunegate catalog the deallocate-not-destroy lifecycle keeps (spec §L5).
  try {
    Write-Host "win-test-run: stopping MSSQLLocalDB…"
    & SqlLocalDB stop MSSQLLocalDB | Out-Null
  } catch { Write-Host "win-test-run: LocalDB stop skipped ($_)" }

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

  # The completion sentinel — written LAST, so its presence means every teardown step
  # above already ran. win-test.sh treats this file (matched by runId), not the SSH
  # channel, as "the run finished"; rc here is the authoritative verdict (spec §X6).
  try {
    @{ runId = $RunId; rc = $script:rc; error = $script:err; finishedAt = (Get-Date -Format o) } |
      ConvertTo-Json -Compress | Set-Content -Path (Join-Path $results 'done.json')
  } catch { Write-Host "win-test-run: couldn't write done.json ($_)" }
}

exit $script:rc
