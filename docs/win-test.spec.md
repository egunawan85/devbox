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
  `unit|integration|smoke`; **`all`** runs every `*.Tests.*.csproj` **except E2E**.
- **X2** The **E2E/Playwright staging suite is out of scope** here — it needs a live
  staging env and real secrets, and runs as a scheduled GitHub Action.
- **X3** Runs are **credential-free**: no vault materialization in the hot path (the
  in-scope suites are hermetic — LocalDB integrated auth, in-process `TestServer`, mocked
  externals, in-test secret injection).
- **X4** Each project emits a **TRX + console log** under `<repo>/tmp/win-test/`, fetched
  back to the operator's `./tmp/win-test/`.
- **X5** The runner's **exit code mirrors the suite** (0 iff every project passed). A run
  that could not execute (box unreachable, no config, no matching projects) is a **loud
  failure**, never a silent pass.

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
auto-provisioned by its `configure`. §L box-side idle-monitor, §R engine install, and
§S rsync-on-Windows are wired and verified when the appliance is provisioned and the
suites run green end-to-end.
