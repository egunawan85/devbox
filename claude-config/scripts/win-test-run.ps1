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
.PARAMETER Suite     unit | integration | smoke | all | modern  (default: integration)
.PARAMETER RunId     Opaque id echoed into done.json so the orchestrator can tell this
                     run's sentinel from a stale one. Optional.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $RepoDir,
  [ValidateSet('unit','integration','smoke','all','modern')] [string] $Suite = 'integration',
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

  # QryptoOmni.Tests.Integration (PR #214) defaults to the shared Docker SQL Server on
  # 127.0.0.1:1433 and — by design — does NOT fall back to LocalDB when that engine is
  # absent. This appliance only stands up LocalDB (above), so point QO's suite at the
  # built-in Windows-auth opt-in it ships for exactly this case. Scoped to the QO repo:
  # these QO_TEST_DB_* vars are unread by the runegate / kash-cards suites that share
  # this runner, but the guard keeps it self-documenting. To instead test the same
  # engine CI uses, stand up runegate2-db-sqlserver-1 on :1433 and unset these.
  if (Test-Path (Join-Path $RepoDir 'QryptoOmni.Tests.Integration')) {
    Write-Host "win-test-run: QryptoOmni repo — routing integration suite to LocalDB (QO_TEST_DB_INTEGRATED_SECURITY)."
    $env:QO_TEST_DB_INTEGRATED_SECURITY = '1'
    $env:QO_TEST_DB_SERVER = '(localdb)\MSSQLLocalDB'
  }

  # A synced repo may declare the env its tests need in scripts/win-test.env — simple
  # KEY=VALUE lines; blank lines and # comments ignored. Each key is set for this process
  # only when the environment doesn't already provide it, so an operator-set value always
  # wins. The runner stays agnostic to which repo it tests: it names no repos and no
  # variables, and only honors what the repo declares, versioned alongside its tests.
  $repoEnvFile = Join-Path $RepoDir 'scripts\win-test.env'
  if (Test-Path $repoEnvFile) {
    Write-Host "win-test-run: applying repo-declared test env from $repoEnvFile"
    foreach ($line in Get-Content $repoEnvFile) {
      $line = $line.Trim()
      if (-not $line -or $line.StartsWith('#')) { continue }
      $k, $v = $line -split '=', 2
      $k = $k.Trim()
      if ($null -eq $v -or -not $k) { Write-Host "win-test-run:   skipping malformed line: $line"; continue }
      if (-not (Test-Path "Env:$k")) { Set-Item -Path "Env:$k" -Value $v.Trim() }
    }
  }

  # --- 3. run the suite ----------------------------------------------------------
  # These are CLASSIC (packages.config) net4x solutions, so the recipe is the repos' own
  # (runegate audit/TEST_STRATEGY.md + CLAUDE.md): nuget restore -> msbuild build ->
  # dotnet test --no-build per suite project. NOT a bare `dotnet test` (that assumes
  # PackageReference restore and would fail on packages.config). Tool paths resolve via
  # vswhere (VS BuildTools). Verified/tuned on the first Slice-1 run against a real box.

  # Which solution(s) to build. A dedicated *.Tests.sln (kash-cards has one) is
  # self-contained, so it wins outright. Otherwise build EVERY root *.sln, not just
  # the first: the test-project glob below spans the whole repo, and a repo can carry
  # more than one root solution (runegate post-admin-v2 has both Runegate.sln and the
  # net8 PGCrypto.Admin.Api.sln). Building only the alphabetically-first one left the
  # other solution's test DLLs unbuilt, so `dotnet test --no-build` reported them as
  # "test source file not found" — a spurious failure that looked like a suite verdict.
  $slns = Get-ChildItem $RepoDir -Filter *.Tests.sln -ErrorAction SilentlyContinue
  if (-not $slns) { $slns = Get-ChildItem $RepoDir -Filter *.sln -ErrorAction SilentlyContinue }
  if (-not $slns) { throw "win-test-run: no .sln found under $RepoDir" }

  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  $msbuild = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild `
                        -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
  if (-not $msbuild) { throw "win-test-run: MSBuild not found via vswhere" }

  foreach ($sln in $slns) {
    Write-Host "win-test-run: nuget restore $($sln.Name)"
    & nuget restore $sln.FullName -NonInteractive
    if ($LASTEXITCODE -ne 0) { throw "win-test-run: nuget restore failed for $($sln.Name) ($LASTEXITCODE)" }
    Touch-Heartbeat

    Write-Host "win-test-run: msbuild build $($sln.Name)"
    & $msbuild $sln.FullName /t:Build /p:Configuration=Debug /m /verbosity:minimal `
        *>&1 | Tee-Object -FilePath (Join-Path $results 'build.log') -Append
    if ($LASTEXITCODE -ne 0) { throw "win-test-run: msbuild build failed for $($sln.Name) ($LASTEXITCODE)" }
    Touch-Heartbeat
  }

  # Select test projects by naming convention (*.Tests.<Suite>.csproj); 'all' runs every
  # *.Tests.*.csproj EXCEPT E2E (live staging + real secrets — the scheduled GH Action's
  # job, not this appliance's — spec §X2) and Fixtures (the shared test-data/helpers
  # library the suites borrow from — not a runnable suite: it carries no test adapter,
  # so it executes zero tests and would trip the §X5 zero-tests-fails-loud rule).
  # 'modern' = the SDK-style net10 test projects, which follow the
  # <Project>.Tests.csproj convention (PGCrypto.Admin.Api.Tests,
  # PGCrypto.API.Audit.Tests, PGCrypto.Backend.Worker.Tests, ...) and so
  # match none of the classic *.Tests.<Suite>.csproj suite globs.
  $pattern = switch ($Suite) {
    'all'    { '*.Tests.*.csproj' }
    'modern' { '*.Tests.csproj' }
    default  { "*.Tests.$Suite.csproj" }
  }
  # The E2E/Fixtures exclusion accepts either naming order: the classic suffix form
  # (Foo.Tests.E2E.csproj) and the SDK-style form the 'modern' glob reaches
  # (Foo.E2E.Tests.csproj). Matching only the classic order would let an E2E project
  # through on 'modern' — exactly the suite that must never run on this appliance.
  $projects = Get-ChildItem -Path $RepoDir -Recurse -Filter $pattern -ErrorAction SilentlyContinue |
              Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' -and
                             $_.Name -notmatch '\.(Tests\.(E2E|Fixtures)|(E2E|Fixtures)\.Tests)\.' }
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
    # Classic suites are prebuilt by the msbuild pass above (--no-build keeps
    # dotnet test off packages.config restore). The 'modern' SDK-style projects
    # are not all members of a root .sln (PGCrypto.API.Audit.Tests is
    # deliberately sln-decoupled), so let dotnet test build them itself.
    $buildArgs = if ($Suite -eq 'modern') { @() } else { @('--no-build', '--no-restore') }
    & dotnet test $p.FullName @buildArgs --nologo @adapterArgs `
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
