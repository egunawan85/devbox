# win-test — spec

> The contract: what must be true of the win-test appliance and its runner. Source of
> truth for the feature. Durable. For *why*, see [win-test.overview.md](./win-test.overview.md).
> The appliance is a `devbox` deployment, so the base box contract in
> [devbox.spec.md](./devbox.spec.md) (providers, network, access, config) still applies;
> this spec adds only what's appliance-specific.

Each requirement is observable — you can check whether a given setup satisfies it.

## R — Role & shape

- **R1** win-test is an **Azure / Windows** deployment whose sole job is running the
  Windows-only test suites; it is **not** a development workspace.
- **R2** It is provisioned as the profile **`win-test`** (`deploy/targets/win-test.conf`),
  distinct from any workspace profile. RG **`win-test-rg`**, VM **`win-test`**.
- **R3** SKU default **`Standard_D4ads_v7`** (4 vCPU / 16 GB). Burstable B-series was
  considered but is unavailable on this subscription/region *and* moot — the box is
  deallocated when idle (§L1), so idle cost is zero regardless, and runs want full
  throughput. Size/region are configurable per [devbox.spec P3].
- **R4** The box carries the **test engine** (.NET SDK + MSBuild + SQL Server LocalDB +
  SQL Server Express listening on `localhost:1433` with loopback integrated auth — the
  E2E deploy's DB target, which LocalDB's port-less user-mode instance can't serve +
  OpenSSH server + `rsync`), **not** the project source. Source arrives per run (§S).

## L — Lifecycle (the box owns it)

- **L1** The box is **deallocated by default**; it runs only while a test run needs it.
- **L2** The **Linux runner only ever starts** the box (`az vm start`, idempotent). It
  never deallocates it — so concurrent sessions cannot stop the box under one another.
- **L3** A **box-side idle-monitor** deallocates the box when **no run is active AND** it
  has been idle > `IDLE_MINUTES` (default 20). "Active/idle" is derived from the run lock
  (§C1) and the heartbeat file (§C2).
- **L4** The idle-monitor is also the **crash-safety net**: a run that dies before
  releasing still leaves a heartbeat that goes stale, so the box still deallocates. There
  is no path that leaves the box running indefinitely after activity stops.
- **L5** `deallocate` (not just OS shutdown) is used, so **compute billing stops**; the
  OS disk persists (keeping the per-branch build caches of §S warm across cycles).

## S — Source sync & workspace on the box

- **S1** A worktree is synced to **`C:\ci\<branch>`** (`CI_DIR`), one dir per branch, via
  **rsync over SSH** — incremental, so warm rebuilds transfer only changed files.
- **S2** The sync **excludes** VCS/build noise (`.git/`, `bin/`, `obj/`, `tmp/`,
  `node_modules/`); the box rebuilds outputs. `--clean` wipes the branch dir first.
- **S3** Uncommitted working-tree edits **are** included (the point is to test in-progress
  work), so sync is from the working tree, not a git fetch.
- **S4** Per-branch dirs are **self-garbage-collected** each run: drop dirs untouched >
  `CI_RETAIN_DAYS` (default 14) and any whose remote branch is gone; hard-evict oldest
  first when free disk < `CI_MIN_FREE_GB` (default 20). GC never fails a test run.

## C — Concurrency

- **C1** Test runs are **serialized by a box-wide lock**. Rationale: the integration
  suites share a single `(localdb)\MSSQLLocalDB` with a fixed `TestRunegate` catalog;
  two runs at once would clobber the same DB. Concurrent invocations **queue** (FIFO),
  they do not fail.
- **C2** Each run maintains a **heartbeat** (updated while holding *and* while waiting for
  the lock) that L3/L4 read. A queued run keeps the box alive.
- **C3** Lock acquisition **times out** (30 min) rather than hanging forever, surfacing a
  stuck peer as an error.

## X — Execution & results

- **X1** Suites are selected by naming convention: `*.Tests.<suite>.csproj` for
  `unit|integration|smoke`; **`all`** runs every `*.Tests.*.csproj` **except E2E**
  (§X2) **and the support libraries** — `*.Tests.Fixtures` and `*.Tests.Support` are
  the shared test-data/helper libraries the suites borrow from, not runnable suites;
  each executes zero tests and would otherwise trip §X5's fail-loud rule. `modern`
  selects the SDK-style `<Project>.Tests.csproj` projects, which match none of the
  classic globs.
- **X1a** **`full`** is an orchestrator-side suite, not a box-side one: it runs `all`
  then `modern` back-to-back on **one boot**, syncing once before and fetching once
  after, so a slice pays the cold start once rather than twice. Its exit code is the
  worst of the two. A suite **failing** does not stop the other — that verdict is still
  worth having from this boot — but a **timeout** does, since a wedged box has nothing
  further to say. Expanded in `win-test.sh` so it works against any box whose runner
  already knows `all` and `modern`, with no box-side change to keep in step.
- **X1b** The suite glob decides **which** projects run; the project's **shape** decides
  **how** each is built. A classic packages.config csproj (no `Sdk` on `<Project>`) is
  prebuilt — `nuget restore` + the VS Build Tools MSBuild — and tested `--no-build` with
  the repo-local test adapters. An SDK-style csproj (`<Project Sdk=...>`, or the
  `<Import Sdk>` / `<Sdk Name>` spellings) restores and builds itself under `dotnet test`,
  **whichever glob its filename matched**, using the MSBuild bundled with the SDK it pins.
  Only solutions that contain a selected classic project are prebuilt; a solution of
  SDK-style projects never reaches Build Tools MSBuild, whose version lags the SDK's
  (17.14 vs the 18.0 that SDK 10.0.400 requires). This is what makes filename
  conventions safe to keep across a .NET Framework → SDK migration: qrypto-omni's
  `QryptoOmni.Tests.<suite>.csproj` are net10, matched the classic glob, and under
  name-based routing every one failed SDK resolution before a test ran. The runner
  prints the classic/sdk-style split and the solutions it will prebuild.
- **X2** The **staging** E2E/Playwright run stays **out of scope** here — it needs a live
  staging env and real secrets, and runs as a scheduled GitHub Action. A **local** E2E run
  is in scope via `--suite e2e`, which routes past the generic runner to the repo's own
  box-side runner (`scripts/win-test-e2e.ps1`): it deploys the IIS stack + SPA on the box
  and runs Playwright against the local origin, using the §R4 SQL Server on
  `localhost:1433`.
- **X3** Runs are **credential-free by default**: no vault materialization in the hot path
  (the hermetic suites need none — LocalDB integrated auth, in-process `TestServer`, mocked
  externals, in-test secret injection). Suites that genuinely configure themselves from the
  **process environment** opt in with **`--env-file <path>`**, which forwards that file's
  `KEY=VALUE` pairs into the suite process. `PGCrypto.Tests.Smoke` is the motivating case:
  it reads its url/key/secret via `Environment.GetEnvironmentVariable` and ships no dotenv
  loader, so with nothing forwarded its Tier 0 gate fails and nothing is actually verified —
  and its secrets cannot ride along in the worktree, since they live in gitignored symlinks
  that §S1's `rsync -az` copies as links that dangle on Windows. The channel is deliberately
  narrow: values travel **base64 over the SSH channel's stdin** into a box-side bootstrap
  that sets them as environment variables and then invokes the normal runner as a child, so
  they appear in **no argv** (the box's process list is readable), **never reach the box's
  disk** (no scp, no temp file — in memory for the run only), and are **never logged** — the
  orchestrator echoes the file path and a count, never a key and never a value, and disables
  xtrace while parsing. Key names must match `^[A-Za-z_][A-Za-z0-9_]*$` and are **rejected,
  not escaped**; values are taken verbatim after the first `=`. A missing, unreadable, or
  pair-less file is a **loud failure** (§X5) rather than a silent unconfigured run — the
  false-green this exists to prevent. So is a non-UTF-8 file: the box decodes with
  `UTF8.GetString`, which substitutes U+FFFD rather than throwing, so a credential carrying
  a stray byte would arrive silently altered and fail just as opaquely. Values interpolated
  into the box-side bootstrap are guarded too — with the flag, a branch name, `CI_DIR`, or
  runner path bearing a quote, backtick, or unintended `$` is refused, since that bootstrap
  is the process holding the credentials. Without the flag the run is unchanged. Distinct from
  the repo-committed `<repo>/scripts/win-test.env` the box-side runner loads for
  **non-secret** config; that loader skips keys already set, so forwarded values win.
- **X4** Each project emits a **TRX + console log** under `<repo>/tmp/win-test/`, fetched
  back to the operator's `./tmp/win-test/`.
- **X5** The runner's **exit code mirrors the suite** (0 iff every project passed). A run
  that could not execute (box unreachable, no config, no matching projects) is a **loud
  failure**, never a silent pass. A project that executes **zero tests** is such a
  failure — vstest exits 0 on "no tests found".
- **X5a** Two things are kept **out of that verdict**, because neither is evidence the
  code is broken, and counting them poisons a green run and trains the reader to
  discount real red:
  1. the §X1 support libraries, excluded from **selection** rather than special-cased
     afterwards — so §X5 itself stays absolute: every project actually run must
     execute tests;
  2. tests that shell out to **git against their own checkout**, which cannot work
     because §S excludes `.git` from the sync (they fail "fatal: not a git
     repository"). Excluded by `--filter` from a named class list the runner carries,
     extensible per repo via `scripts/win-test.env` (`WIN_TEST_EXCLUDE_CLASSES`).

  Both exclusions are **loud, never silent**: the applied filter is printed and the
  class names and counts ride in the §X9 summary, so a skip can never read as a pass.
  This covers only "the sync cannot carry what the test reads" — a test that genuinely
  fails on Windows is a real verdict and stays red.
- **X9** The run ends with a **machine-readable verdict**, so a caller need not scrape
  per-project `Passed!`/`Failed!` lines out of a 200k-line log:

  ```
  WIN-TEST-PROJECT name=<proj> rc=<n> passed=<n> failed=<n> skipped=<n> total=<n>
  WIN-TEST-SUMMARY suite=<s> projects=<ok>/<total> passed=<n> failed=<n> skipped=<n> \
                   excluded=<classes|none> rc=<n>
  ```

  The summary is also carried in the §X6 sentinel, so the orchestrator echoes it
  without reading the console log at all. It stays **absent** on paths that never reach
  a verdict (lock timeout, build throw) — nothing is reported about a run that did not
  happen.
- **X6** Completion is signalled by an **artifact, not the SSH channel**: the box-side
  runner's final act — on pass, fail, or throw — is writing `tmp/win-test/done.json`
  (run id + real exit code). The orchestrator treats that sentinel as the source of truth
  for "finished"; the SSH session exiting is merely the common case. To keep that common
  case working, the runner **tears down LocalDB** (stop, never delete — §L5 keeps the
  catalog) before exiting, so no child process outlives the run holding the session's
  stdio open.
- **X7** The orchestrator **never blocks indefinitely**: while the suite runs it emits a
  periodic heartbeat (elapsed, remote log progress, TRX presence); it short-circuits as
  soon as the sentinel appears (killing a lingering SSH channel); and past
  `WIN_TEST_TIMEOUT` (default 60 min, applied **per suite** — so `full` allows it once
  for each) it aborts — capturing diagnostics (box power state, remote process list, log
  tail), fetching partial results — and exits **124** with an explicit "possible hang"
  message.
- **X8** Result fetch is **loud**: a failed fetch is reported, and a run that claims pass
  without a TRX from this run fetched locally is reported as a **failure** (green needs
  evidence — X5).

## I — Invocation & wiring

- **I1** The operator/agent entry point is **`/win-test`** on the Linux box, which calls
  `~/.claude/scripts/win-test.sh`. There is intentionally **no** `deploy/devbox test` alias.
- **I1a** For a run that outlives the caller — an agent session's foreground command is
  killed after about ten minutes, and a run takes 5–25 — the entry point is
  **`~/.claude/scripts/win-test-launch.sh`**, which takes the same arguments, detaches
  the run (`setsid` + `nohup`, stdin closed), logs to the worktree's own `./tmp/`,
  appends `WRAPPER_EXIT <rc>` when it ends, and prints the log path and PID
  immediately. It enforces §C1's single-tenant rule caller-side with an **flock** held
  by the detached run itself for exactly as long as it lives — deliberately not a scan
  of the process table, which under an agent harness matches any command whose text
  merely mentions the script, including the check itself.
- **I2** Box identity + tunables reach the runner via **`~/.config/devbox/win-test/
  runner.env`**, written by `devbox -p win-test up`. Required keys: `RESOURCE_GROUP`,
  `VM_NAME`, `SSH_HOST`, `SSH_PORT`, `SSH_USER`, `SUBSCRIPTION_ID`, `CI_DIR`,
  `CI_RETAIN_DAYS`, `CI_MIN_FREE_GB`, `IDLE_MINUTES`.
- **I3** If `runner.env` is absent, the runner **fails with a clear "stand up the
  appliance first"** message — it does not guess or half-run.
- **I4** Policy lives where it's loaded on demand: the **rule** in global CLAUDE.md
  (Windows tests → `/win-test`, never fake), the **procedure** in the command + scripts +
  this doc, the **which-suites-and-why** in each project's own CLAUDE.md.

## Status

The repo scaffolding (profile, runner, command, docs, policy) and the §I2 `runner.env`
emission (written by `devbox -p win-test up` on the operator box) are authored; the
operator box's prerequisites (machine SSH identity, Azure CLI — devbox.spec A6/T5) are
auto-provisioned by its `configure`. The §R engine install — including `rsync`, which
lives in the toolchain layer and re-converges automatically when `toolchain.ps1` changes
(the box records the hash of the script that last completed) — and the §S rsync-over-SSH
sync are **verified end-to-end** on the provisioned appliance: a real `/win-test --suite
unit` synced the worktree to `C:\ci\<branch>`, built it, ran the unit suite green with
every test executed, and fetched the TRX back. A project whose TRX shows zero executed
tests fails the run loud (§X5) — vstest alone exits 0 on that. The §L box-side
idle-monitor is **implemented and verified live**: a SYSTEM scheduled task (every 5 min)
probes the §C1 lock for a *live holder* (an exclusive-open test, so a lock file leaked by
a hard-killed run is cleaned up instead of pinning the box — §L4) and measures idleness
from the newer of the §C2 heartbeat and the OS boot time, then deallocates via the VM's
managed identity (a custom role with only the `deallocate` action, scoped to this VM).
Verified on the appliance: held lock blocks deallocation, stale lock is removed, boot
grace holds, and an untouched box self-deallocated after a real `/win-test` run with no
manual step. Installed by `up`/`toolchain` for profiles that set `IDLE_MINUTES`
(hash-converged like the toolchain, so script or `IDLE_MINUTES` changes re-apply).
