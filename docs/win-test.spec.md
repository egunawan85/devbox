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
  (§X2) **and Fixtures** — `*.Tests.Fixtures` is the shared test-data/helpers library
  the suites borrow from, not a runnable suite; it executes zero tests and would
  otherwise trip §X5's fail-loud rule.
- **X2** The **staging** E2E/Playwright run stays **out of scope** here — it needs a live
  staging env and real secrets, and runs as a scheduled GitHub Action. A **local** E2E run
  is in scope via `--suite e2e`, which routes past the generic runner to the repo's own
  box-side runner (`scripts/win-test-e2e.ps1`): it deploys the IIS stack + SPA on the box
  and runs Playwright against the local origin, using the §R4 SQL Server on
  `localhost:1433`.
- **X3** Runs are **credential-free**: no vault materialization in the hot path (the
  in-scope suites are hermetic — LocalDB integrated auth, in-process `TestServer`, mocked
  externals, in-test secret injection).
- **X4** Each project emits a **TRX + console log** under `<repo>/tmp/win-test/`, fetched
  back to the operator's `./tmp/win-test/`.
- **X5** The runner's **exit code mirrors the suite** (0 iff every project passed). A run
  that could not execute (box unreachable, no config, no matching projects) is a **loud
  failure**, never a silent pass.
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
  `WIN_TEST_TIMEOUT` (default 60 min) it aborts — capturing diagnostics (box power
  state, remote process list, log tail), fetching partial results — and exits **124**
  with an explicit "possible hang" message.
- **X8** Result fetch is **loud**: a failed fetch is reported, and a run that claims pass
  without a TRX from this run fetched locally is reported as a **failure** (green needs
  evidence — X5).

## I — Invocation & wiring

- **I1** The operator/agent entry point is **`/win-test`** on the Linux box, which calls
  `~/.claude/scripts/win-test.sh`. There is intentionally **no** `deploy/devbox test` alias.
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
