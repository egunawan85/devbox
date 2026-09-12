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
       <RepoDir>/tmp/win-test/ (win-test.sh rsyncs that back). Each project is routed
       by its SHAPE, not its name: a classic packages.config csproj is prebuilt with
       nuget + the VS BuildTools MSBuild and tested --no-build; an SDK-style csproj
       (<Project Sdk=...>) restores and builds itself under `dotnet test`, whichever
       suite glob its filename happened to match.
    4. Stop LocalDB, release the lock, bump the heartbeat, garbage-collect stale
       per-branch dirs — then write tmp/win-test/done.json, the completion sentinel.

  LocalDB MUST be stopped on every exit path: a lingering sqlservr.exe inherits the SSH
  session's stdio handles, so the orchestrator's blocking ssh never sees EOF and hangs
  long after the suite finished. The sentinel exists for the same reason: it carries the
  real exit code, so the orchestrator can trust "finished" without trusting the SSH
  channel (spec §X6).

  Exit code mirrors `dotnet test` (0 = all passed), except that a project which executes
  zero tests fails the run — vstest exits 0 on "no tests found", which would otherwise be
  a silent pass (spec §X5). Two things are deliberately kept OUT of that verdict, because
  neither is evidence the code is broken: the Fixtures/Support helper libraries (no test
  adapter, zero tests by design — excluded from selection), and tests that shell out to
  git against their own checkout (the sync omits .git, so they cannot run here — excluded
  by --filter). Both exclusions are printed and counted in the summary line below.

  The run ends with one machine-readable line per project and one for the run:

    WIN-TEST-PROJECT name=<proj> rc=<n> passed=<n> failed=<n> skipped=<n> total=<n> stalled=<0|1>
    WIN-TEST-SUMMARY suite=<s> projects=<ok>/<total> passed=<n> failed=<n> skipped=<n> \
                     excluded=<classes|none> stalled=<projects|none> notrun=<projects|none> rc=<n>

  stalled= names projects stopped at the per-project time limit (-ProjectTimeoutSec) —
  a stall, never a verdict. notrun= names projects the repo marks as needing forwarded
  credentials (WIN_TEST_SKIP_WITHOUT_ENV_FILE) that a broad suite left out because none
  were forwarded.

  The summary is also carried in done.json, so the orchestrator can report the verdict
  without parsing the console log at all.

.PARAMETER RepoDir   The synced worktree on the box, e.g. C:\ci\my-branch.
.PARAMETER Suite     unit | integration | smoke | all | modern | projects  (default: integration).
                     'projects' runs exactly the test projects named by -ProjectNames, of either
                     shape, and nothing else.
.PARAMETER RunId     Opaque id echoed into done.json so the orchestrator can tell this
                     run's sentinel from a stale one. Optional.
.PARAMETER ProjectNames
                     Comma-separated test project names (the .csproj base name, any case), for
                     -Suite projects. A name that matches no test project fails the run. (Not
                     -Projects: PowerShell variable names ignore case, so that parameter would
                     be the same variable as the $projects list below, and assigning the list
                     to a [string] parameter flattens it into one string.)
.PARAMETER ProjectTimeoutSec
                     Per-project time limit. Past it the project's test processes are stopped,
                     the project is reported stalled (rc=124) — a stall, never a verdict — and
                     the run moves on to the next project. 0 (the default) means the repo's
                     WIN_TEST_PROJECT_TIMEOUT from scripts/win-test.env, else 600.
.PARAMETER EnvFileForwarded
                     Set by the orchestrator when --env-file forwarded credentials. Projects the
                     repo lists in WIN_TEST_SKIP_WITHOUT_ENV_FILE join the broad suites (all,
                     modern) only when it is set.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $RepoDir,
  [ValidateSet('unit','integration','smoke','all','modern','projects')] [string] $Suite = 'integration',
  [string] $RunId = '',
  [string] $ProjectNames = '',
  [int] $ProjectTimeoutSec = 0,
  [switch] $EnvFileForwarded
)
$ErrorActionPreference = 'Stop'

# Failure until proven otherwise: exit paths that never reach the pass/fail verdict
# (lock timeout, restore/build throw) must still report non-zero in the sentinel.
$script:rc  = 1
$script:err = $null
# The machine-readable verdict line (see the summary block at the end of the run). Stays
# null on paths that never reach a verdict — a lock timeout or a build throw — so the
# orchestrator prints nothing rather than a summary of a run that did not happen.
$script:summary = $null

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
  # Two build systems live behind the one `dotnet test` verdict, and the project's SHAPE
  # — not its filename — decides which one a project gets:
  #
  #   classic   packages.config, .NET Framework 4.x, no Sdk attribute on <Project>. The
  #             recipe is the repos' own (runegate audit/TEST_STRATEGY.md + CLAUDE.md):
  #             nuget restore -> msbuild build (VS BuildTools, via vswhere) -> dotnet test
  #             --no-build. NOT a bare `dotnet test` (that assumes PackageReference restore
  #             and fails on packages.config). Verified/tuned on the first Slice-1 run.
  #   sdk-style <Project Sdk="...">. PackageReference, restores and builds itself under
  #             `dotnet test`, using the MSBuild bundled with the SDK that the project
  #             pins. It must NOT go through the VS BuildTools MSBuild: that copy lags the
  #             SDK (Build Tools 17.14 vs the 18.0 that SDK 10.0.400 demands), so SDK
  #             resolution fails before a single test runs.
  #
  # Routing used to follow the filename — *.Tests.<Suite>.csproj meant classic, and only
  # the 'modern' glob's *.Tests.csproj went to a self-building `dotnet test`. That broke
  # the day a repo kept the classic names but migrated the projects: qrypto-omni's
  # QryptoOmni.Tests.{Unit,Integration,...}.csproj are SDK-style net10, matched the
  # classic glob, were fed to MSBuild 17, and every one failed SDK resolution with no test
  # run. The name predicts nothing; the file's own <Project> element is the truth. Any
  # repo that migrates off .NET Framework hits the same thing, and the E2E runner builds
  # these same projects on this box — so the shape check is the durable fix, not a newer
  # Build Tools.

  # Select test projects by naming convention (*.Tests.<Suite>.csproj); 'all' runs every
  # *.Tests.*.csproj EXCEPT E2E (live staging + real secrets — the scheduled GH Action's
  # job, not this appliance's — spec §X2) and the two SUPPORT LIBRARIES the suites borrow
  # from: Fixtures (shared test data/helpers) and Support. Neither is a runnable suite —
  # they carry no test adapter, so each executes zero tests and would trip the §X5
  # zero-tests-fails-loud rule, failing an otherwise green run on a library that is doing
  # exactly what it was written to do. Excluding them here (rather than special-casing
  # their result below) keeps §X5 itself absolute: every project we DO run must execute
  # tests. Support joined this list after a green runegate classic run reported "2
  # project(s) failed" — one of them PGCrypto.Tests.Support, which has no tests by design.
  # 'modern' = the test projects that follow the <Project>.Tests.csproj convention
  # (PGCrypto.Admin.Api.Tests, PGCrypto.API.Audit.Tests, PGCrypto.Backend.Worker.Tests,
  # ...) and so match none of the *.Tests.<Suite>.csproj suite globs. The glob only
  # decides WHICH projects are in the suite; how each is built is decided per file below.
  # 'projects' reaches both shapes (Foo.Tests.csproj and Foo.Tests.Unit.csproj) and is then
  # narrowed to exactly the names asked for, below.
  $pattern = switch ($Suite) {
    'all'      { '*.Tests.*.csproj' }
    'modern'   { '*.Tests.csproj' }
    'projects' { '*.Tests*.csproj' }
    default    { "*.Tests.$Suite.csproj" }
  }
  if ($Suite -eq 'projects' -and -not $ProjectNames.Trim()) { throw "win-test-run: -Suite projects needs -ProjectNames <name>[,<name>...]" }
  if ($Suite -ne 'projects' -and $ProjectNames.Trim())      { throw "win-test-run: -ProjectNames is only valid with -Suite projects" }
  # The exclusion accepts either naming order: the classic suffix form
  # (Foo.Tests.E2E.csproj) and the SDK-style form the 'modern' glob reaches
  # (Foo.E2E.Tests.csproj). Matching only the classic order would let an E2E project
  # through on 'modern' — exactly the suite that must never run on this appliance.
  $projects = @(Get-ChildItem -Path $RepoDir -Recurse -Filter $pattern -ErrorAction SilentlyContinue |
              Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' -and
                             $_.Name -notmatch '\.(Tests\.(E2E|Fixtures|Support)|(E2E|Fixtures|Support)\.Tests)\.' })
  if (-not $projects) { throw "win-test-run: no test projects matched '$pattern' under $RepoDir" }

  # --- -Suite projects: exactly the named projects -----------------------------------
  # For iterating on one area without paying for a whole suite. Names match the .csproj
  # base name, case-insensitively. One that matches nothing fails the run and lists what
  # does exist, rather than quietly running less than was asked for.
  if ($Suite -eq 'projects') {
    $byName = @{}
    foreach ($p in $projects) { $byName[[IO.Path]::GetFileNameWithoutExtension($p.Name).ToLowerInvariant()] = $p }
    $wanted  = @($ProjectNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $missing = @($wanted | Where-Object { -not $byName.ContainsKey($_.ToLowerInvariant()) })
    if ($missing.Count -gt 0) {
      $known = ($projects | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) } | Sort-Object) -join ', '
      throw ("win-test-run: no test project named {0}. Test projects in this repo: {1}" -f ($missing -join ', '), $known)
    }
    $projects = @($wanted | ForEach-Object { $byName[$_.ToLowerInvariant()] })
  }

  # --- projects that need forwarded credentials --------------------------------------
  # A repo can name projects that verify nothing unless --env-file forwarded credentials
  # (WIN_TEST_SKIP_WITHOUT_ENV_FILE in its scripts/win-test.env) — a smoke suite against a
  # live environment that otherwise passes in a fraction of a second having checked
  # nothing. Leave those out of the broad suites unless credentials came along, and say so
  # in the log and the summary. Asking for one by name — its own suite, or -Suite
  # projects — still runs it.
  $notRun = @()
  if (-not $EnvFileForwarded -and $Suite -in @('all', 'modern') -and $env:WIN_TEST_SKIP_WITHOUT_ENV_FILE) {
    $needsEnv = @($env:WIN_TEST_SKIP_WITHOUT_ENV_FILE -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $notRun   = @($projects | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) } |
                  Where-Object { $needsEnv -contains $_ })
    if ($notRun.Count -gt 0) {
      Write-Host ("win-test-run: not running {0} — the repo marks it as needing credentials (WIN_TEST_SKIP_WITHOUT_ENV_FILE) and none were forwarded with --env-file" -f ($notRun -join ', '))
      $projects = @($projects | Where-Object { $notRun -notcontains [IO.Path]::GetFileNameWithoutExtension($_.Name) })
    }
  }
  if (-not $projects) { throw "win-test-run: every project '$pattern' selected needs credentials, and none were forwarded with --env-file" }

  # --- the per-project time limit ----------------------------------------------------
  # A test host that stops making progress — deadlocked, or crashed and left waiting — used
  # to hold the whole run until the orchestrator's suite timeout, and every project after
  # it went unrun. Each project now gets its own limit. The operator's value (passed in as
  # -ProjectTimeoutSec) wins, then the repo's scripts/win-test.env, then 600 s: several
  # times the slowest healthy project, so reaching it means stuck, not slow.
  if ($ProjectTimeoutSec -le 0) {
    $ProjectTimeoutSec = 600
    if ($env:WIN_TEST_PROJECT_TIMEOUT) {
      $parsed = 0
      if ([int]::TryParse($env:WIN_TEST_PROJECT_TIMEOUT, [ref]$parsed) -and $parsed -gt 0) { $ProjectTimeoutSec = $parsed }
      else { Write-Host "win-test-run: ignoring WIN_TEST_PROJECT_TIMEOUT='$($env:WIN_TEST_PROJECT_TIMEOUT)' (not a positive whole number of seconds)" }
    }
  }
  if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
    throw "win-test-run: Start-ThreadJob is unavailable (it ships with PowerShell 7), so the per-project time limit cannot be enforced"
  }
  Write-Host "win-test-run: per-project time limit ${ProjectTimeoutSec}s"

  # Shape check. SDK-style is any of the three spellings MSBuild accepts: an Sdk attribute
  # on the root <Project>, an <Import Sdk="..."/>, or a <Sdk Name="..."/> child. A file
  # that is none of those is classic. Regex rather than [xml]: a csproj that will not
  # parse should fail in the build with MSBuild's own diagnostic, not here with ours.
  function Test-SdkStyleProject([string] $Path) {
    $text = Get-Content -Path $Path -Raw
    return ($text -match '<Project\b[^>]*\sSdk\s*=' -or
            $text -match '<Import\b[^>]*\sSdk\s*='  -or
            $text -match '<Sdk\b[^>]*\sName\s*=')
  }
  $classic  = @($projects | Where-Object { -not (Test-SdkStyleProject $_.FullName) })
  $sdkStyle = @($projects | Where-Object {      Test-SdkStyleProject $_.FullName  })
  Write-Host ("win-test-run: {0} project(s) selected by '{1}': {2} classic (msbuild), {3} sdk-style (dotnet test)" -f `
              @($projects).Count, $pattern, $classic.Count, $sdkStyle.Count)
  foreach ($p in $sdkStyle) { Write-Host "win-test-run:   sdk-style: $($p.Name)" }

  # --- 3a. prebuild the CLASSIC projects' solutions ------------------------------------
  # Only when there is something classic to build, and only the solutions that actually
  # contain a selected classic project. Building a solution because it sits at the repo
  # root is what fed qrypto-omni's SDK-style solution to MSBuild 17; a solution that holds
  # none of the classic projects we are about to test has no business in this pass.
  #
  # Which solutions to consider: a dedicated *.Tests.sln (kash-cards has one) is
  # self-contained, so it wins outright. Otherwise EVERY root *.sln is a candidate, not
  # just the first: a repo can carry more than one root solution (runegate post-admin-v2
  # has both Runegate.sln and the net8 PGCrypto.Admin.Api.sln). Building only the
  # alphabetically-first one left the other solution's test DLLs unbuilt, so `dotnet test
  # --no-build` reported them as "test source file not found" — a spurious failure that
  # looked like a suite verdict. Membership is read from the .sln's own Project() lines.
  if ($classic.Count -gt 0) {
    $slns = Get-ChildItem $RepoDir -Filter *.Tests.sln -ErrorAction SilentlyContinue
    if (-not $slns) { $slns = Get-ChildItem $RepoDir -Filter *.sln -ErrorAction SilentlyContinue }
    if (-not $slns) { throw "win-test-run: classic test projects selected but no .sln found under $RepoDir" }

    function Get-SolutionProjectPaths([System.IO.FileInfo] $Sln) {
      $dir = $Sln.DirectoryName
      Get-Content -Path $Sln.FullName | ForEach-Object {
        if ($_ -match '^\s*Project\("\{[^}]+\}"\)\s*=\s*"[^"]*",\s*"([^"]+)"') {
          $rel = $Matches[1] -replace '/', '\'
          [IO.Path]::GetFullPath((Join-Path $dir $rel))
        }
      }
    }
    $classicPaths = @($classic | ForEach-Object { $_.FullName })
    $buildSlns = @()
    $covered   = @{}
    foreach ($sln in $slns) {
      $members = @(Get-SolutionProjectPaths $sln)
      $hit = @($classicPaths | Where-Object { $members -contains $_ })
      if ($hit.Count -gt 0) {
        $buildSlns += $sln
        foreach ($h in $hit) { $covered[$h] = $true }
      }
    }
    # A classic project that the membership scan places in no candidate solution: say so,
    # then fall back to building EVERY candidate (the pre-shape-routing behaviour) rather
    # than guess. Either the project really is unreferenced — in which case `dotnet test
    # --no-build` will report "test source file not found" below, as it always did — or
    # the .sln path spelling defeated the scan, in which case the full build still covers
    # it. A throw here would turn a working classic run red on a path quirk.
    $orphans = @($classicPaths | Where-Object { -not $covered.ContainsKey($_) })
    if ($orphans.Count -gt 0) {
      Write-Host ("win-test-run: WARNING classic project(s) found in none of {0}: {1} — building every candidate solution" -f `
                  (($slns | ForEach-Object { $_.Name }) -join ', '), ($orphans -join ', '))
      $buildSlns = @($slns)
    }
    Write-Host ("win-test-run: solutions to prebuild: " + (($buildSlns | ForEach-Object { $_.Name }) -join ', '))

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $msbuild = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild `
                          -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
    if (-not $msbuild) { throw "win-test-run: MSBuild not found via vswhere" }

    foreach ($sln in $buildSlns) {
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
  }
  else { Write-Host "win-test-run: no classic projects selected — skipping the nuget/msbuild pass" }

  # Classic packages.config projects keep their VSTest adapter (e.g. xunit.runner.visualstudio)
  # in the repo-local packages dir, which dotnet test does not probe by default — without it
  # discovery finds ZERO tests and still exits 0. Hand vstest every restored adapter dir.
  # SDK-style projects resolve their adapter through PackageReference and get none of this.
  $adapterArgs = @()
  Get-ChildItem -Path (Join-Path $RepoDir 'packages') -Recurse -Filter '*testadapter.dll' -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty DirectoryName -Unique |
    ForEach-Object { $adapterArgs += @('--test-adapter-path', $_) }

  # --- tests that cannot run on this appliance, by construction --------------------
  # win-test.sh syncs the worktree with `rsync --exclude '.git/'` — deliberately, since
  # the history is large and no test needs it. But a repo can carry tests that shell out
  # to git against their own checkout (runegate's gitignore-anchor regression tests run
  # `git check-ignore`). On the box those do not fail because the code regressed; they
  # fail with "fatal: not a git repository" because the thing they inspect was never
  # shipped here. Counting that as a suite failure poisons an otherwise green run and
  # trains the reader to discount real red — so exclude them, LOUDLY: the filter is
  # printed below and the count rides in the machine-readable summary, so a skip is
  # always visible and never mistaken for a pass.
  #
  # This is the narrow case "the sync cannot carry what the test reads". It is NOT a
  # place to silence a test that genuinely fails on Windows — that is a real verdict and
  # must stay red. A repo extends the list from its own scripts/win-test.env
  # (WIN_TEST_EXCLUDE_CLASSES=Foo,Bar), versioned with its tests.
  $gitDependentClasses = @('Issue1943_GitignoreDataAnchorRegressionTests')
  if ($env:WIN_TEST_EXCLUDE_CLASSES) {
    $gitDependentClasses += ($env:WIN_TEST_EXCLUDE_CLASSES -split ',' |
                             ForEach-Object { $_.Trim() } | Where-Object { $_ })
  }
  $gitDependentClasses = @($gitDependentClasses | Select-Object -Unique)
  $filterArgs = @()
  if ($gitDependentClasses.Count -gt 0) {
    # vstest filter grammar: FullyQualifiedName!~X&FullyQualifiedName!~Y (substring, ANDed
    # so every listed class is excluded). One --filter argument; repeating the flag would
    # keep only the last.
    $expr = ($gitDependentClasses | ForEach-Object { "FullyQualifiedName!~$_" }) -join '&'
    $filterArgs = @('--filter', $expr)
    Write-Host "win-test-run: excluding $($gitDependentClasses.Count) class(es) that need the .git dir the sync omits: $($gitDependentClasses -join ', ')"
  }

  $failed = 0
  $projectStats = @()
  foreach ($p in $projects) {
    $name = [IO.Path]::GetFileNameWithoutExtension($p.Name)
    # By shape (see 3 above), never by suite name. Classic projects were prebuilt by the
    # msbuild pass (--no-build keeps dotnet test off packages.config restore) and need
    # the repo-local adapter dirs. SDK-style projects restore and build themselves —
    # they are not all members of a root .sln either (PGCrypto.API.Audit.Tests is
    # deliberately sln-decoupled), so a solution build could not cover them anyway.
    $isSdk = $sdkStyle.FullName -contains $p.FullName
    $shape = if ($isSdk) { 'sdk-style' } else { 'classic' }
    Write-Host "win-test-run: dotnet test $name ($shape)"
    $buildArgs   = if ($isSdk) { @() } else { @('--no-build', '--no-restore') }
    $projAdapter = if ($isSdk) { @() } else { $adapterArgs }
    # The results dir survives between runs (the sync excludes tmp/), so a TRX left by an
    # earlier run would be read as this one's if this project never wrote its own — which is
    # exactly what a stopped project does. Clear it first.
    $trx = Join-Path $results "$name.trx"
    Remove-Item $trx -Force -ErrorAction SilentlyContinue

    # The per-project watchdog. A thread job inside this process — not a child process, so it
    # holds none of the SSH session's handles — sleeps out the limit. If the project is still
    # running then, it records the stall and stops the test processes this project started:
    # test hosts first, which is what lets `dotnet test` itself return, then after a grace
    # period any dotnet process still left from the project (a hung build or vstest). Start
    # time is the ownership test: the box lock means this runner is the only one here, so
    # anything started since the project began belongs to it.
    $stallMarker = Join-Path $results "$name.stalled"
    Remove-Item $stallMarker -Force -ErrorAction SilentlyContinue
    $watchdog = Start-ThreadJob -ArgumentList $ProjectTimeoutSec, (Get-Date), $stallMarker, $PID -ScriptBlock {
      param($limitSec, $since, $marker, $runnerPid)
      function Stop-StartedSince([string[]] $names) {
        Get-Process -Name $names -ErrorAction SilentlyContinue |
          Where-Object { $_.Id -ne $runnerPid -and $(try { $_.StartTime -ge $since } catch { $false }) } |
          Stop-Process -Force -ErrorAction SilentlyContinue
      }
      Start-Sleep -Seconds $limitSec
      Set-Content -Path $marker -Value (Get-Date -Format o)
      Stop-StartedSince @('testhost*', 'vstest.console')
      Start-Sleep -Seconds 30
      Stop-StartedSince @('dotnet')
    }
    $projOut = $null
    & dotnet test $p.FullName @buildArgs --nologo @projAdapter @filterArgs `
        --logger "trx;LogFileName=$name.trx" --results-directory $results `
        *>&1 | Tee-Object -FilePath (Join-Path $results "$name.log") -Append | Tee-Object -Variable projOut
    $rcTest  = $LASTEXITCODE
    $stalled = Test-Path $stallMarker
    Stop-Job -Job $watchdog -ErrorAction SilentlyContinue
    Remove-Job -Job $watchdog -Force -ErrorAction SilentlyContinue
    if ($stalled) {
      $rcTest = 124
      Write-Host "win-test-run: $name was still running at the ${ProjectTimeoutSec}s per-project limit, so its test processes were stopped. This is a stall, not a test verdict; the counts below are whatever finished first."
    }
    # A project that discovers/executes zero tests must FAIL the run (spec §X5: a run that
    # could not execute is a loud failure, never a silent pass) — vstest exits 0 for it.
    $executed = 0; $passed = 0; $failedTests = 0; $total = 0
    if (Test-Path $trx) {
        $counters    = ([xml](Get-Content $trx)).TestRun.ResultSummary.Counters
        $executed    = [int]$counters.executed
        $passed      = [int]$counters.passed
        $failedTests = [int]$counters.failed
        $total       = [int]$counters.total
    }
    # 'total' counts what was DISCOVERED, 'executed' what actually ran, so the difference
    # is everything skipped — [Fact(Skip=...)] and anything the --filter above removed.
    $skipped = [Math]::Max(0, $total - $executed)
    $projOk  = $true
    if ($rcTest -ne 0) { $failed++; $projOk = $false }
    elseif ($executed -eq 0) { Write-Host "win-test-run: $name executed ZERO tests — failing loud (spec X5)"; $failed++; $projOk = $false }
    # A test host that crashes mid-run (a background thread throwing, say) aborts the run:
    # every counter is green, only the exit code is red, and the tests the host never
    # reached are simply missing from the counts. Say so, so the reader looks at the crash
    # in the log instead of hunting a failing test, and doesn't take the pass count for the
    # whole project.
    if ($rcTest -ne 0 -and -not $stalled -and $failedTests -eq 0 -and $passed -gt 0 -and
        (($projOut | Out-String) -match 'Test host process crashed')) {
      Write-Host "win-test-run: $name — no test failed, but its test host crashed and the run was aborted, so tests after the crash did not run (see $name.log). Counted as a failure."
    }
    # One machine-readable line per project, so a reader never has to correlate a
    # Passed!/Failed! console line with the project that produced it.
    Write-Host ("WIN-TEST-PROJECT name={0} rc={1} passed={2} failed={3} skipped={4} total={5} stalled={6}" -f `
                $name, $rcTest, $passed, $failedTests, $skipped, $total, [int]$stalled)
    $projectStats += [pscustomobject]@{
        Name = $name; Ok = $projOk; Passed = $passed; Failed = $failedTests
        Skipped = $skipped; Total = $total; Stalled = $stalled
    }
    Touch-Heartbeat
  }

  if ($failed -gt 0) { Write-Host "win-test-run: $failed project(s) failed."; $script:rc = 1 }
  else               { Write-Host "win-test-run: all suites passed.";        $script:rc = 0 }

  # --- the one line a session should read ------------------------------------------
  # Before this existed the runner printed no final verdict, so every caller scraped each
  # project's Passed!/Failed! line out of a 200k-line log and re-derived the answer — and
  # the exit code it was cross-checking against was itself wrong (see the two exclusions
  # above). One line, fixed key=value shape, also carried in done.json so the orchestrator
  # can echo it without parsing the log at all.
  $sumPassed  = ($projectStats | Measure-Object -Property Passed  -Sum).Sum
  $sumFailed  = ($projectStats | Measure-Object -Property Failed  -Sum).Sum
  $sumSkipped = ($projectStats | Measure-Object -Property Skipped -Sum).Sum
  $okCount    = @($projectStats | Where-Object { $_.Ok }).Count
  $excludedLabel = if ($gitDependentClasses.Count -gt 0) { $gitDependentClasses -join '+' } else { 'none' }
  # stalled= names the projects stopped at the per-project limit; notrun= the projects left
  # out for want of forwarded credentials. Neither is a pass, so both ride in the verdict.
  $stalledNames = @($projectStats | Where-Object { $_.Stalled } | ForEach-Object { $_.Name })
  $stalledLabel = if ($stalledNames.Count -gt 0) { $stalledNames -join '+' } else { 'none' }
  $notRunLabel  = if ($notRun.Count -gt 0) { $notRun -join '+' } else { 'none' }
  # No '"' anywhere in this string: it is embedded in done.json, which the orchestrator
  # reads with a sed capture bounded by the next quote.
  $script:summary = ("WIN-TEST-SUMMARY suite={0} projects={1}/{2} passed={3} failed={4} skipped={5} excluded={6} stalled={7} notrun={8} rc={9}" -f `
      $Suite, $okCount, $projectStats.Count,
      [int]$sumPassed, [int]$sumFailed, [int]$sumSkipped, $excludedLabel, $stalledLabel, $notRunLabel, $script:rc)
  Write-Host $script:summary
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
    @{ runId = $RunId; rc = $script:rc; error = $script:err; summary = $script:summary
       finishedAt = (Get-Date -Format o) } |
      ConvertTo-Json -Compress | Set-Content -Path (Join-Path $results 'done.json')
  } catch { Write-Host "win-test-run: couldn't write done.json ($_)" }
}

exit $script:rc
