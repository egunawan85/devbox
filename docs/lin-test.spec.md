# lin-test — spec

> The contract: what must be true of the lin-test appliance and its runner. Source of
> truth for the feature. Durable. For *why*, see [lin-test.overview.md](./lin-test.overview.md).
> The appliance is a `devbox` deployment, so the base box contract in
> [devbox.spec.md](./devbox.spec.md) (network, access, config) still applies where this
> spec does not say otherwise; its Windows sibling is [win-test.spec.md](./win-test.spec.md).

Each requirement is observable — you can check whether a given setup satisfies it.

## R — Role & shape

- **R1** lin-test is an **Azure / Ubuntu 24.04** deployment whose sole job is running a
  project's check (build, lint, tests, Docker-backed suites) off the shared Linux devbox;
  it is **not** a development workspace.
- **R2** It is provisioned as the profile **`lin-test`** (`deploy/targets/lin-test.conf`).
  RG **`lin-test-rg`**, VM **`lin-test`**, in the same subscription and region as win-test,
  so `down` removes exactly this appliance.
- **R3** SKU default **`Standard_D4as_v7`** (4 vCPU / 16 GB), OS disk **64 GB Premium
  SSD**. Four cores to match the devbox a check is tuned on; 16 GB because a check builds,
  lints and runs two test runs beside a database at once. The disk is the only thing that
  persists between runs (§S4) and is billed while the box is deallocated. Size, disk and
  region are configurable in the profile.
- **R4** The box carries the **engine**, not the project: git, rsync, a C toolchain, Node
  (the profile's `NODE_MAJOR` line) with corepack enabled, Docker Engine usable without
  sudo, and the Playwright Chromium libraries with their AppArmor grant
  ([devbox.spec T6]). Source arrives per run (§S).
- **R5** The box is **credential-free**. `up` gives it no clone of this repo, no Claude
  Code, no forwarded SSH agent and no vault; the profile says so with `CREDENTIAL_FREE=1`,
  and the `vault` subcommands refuse it. Nothing a run sends is secret (§S2, §X3). The one
  identity the box holds is its own managed identity, which can deallocate this VM and do
  nothing else (§L5).
- **R5a** The box **trusts the code it runs** and is shared: a run has Docker (root on the
  box) and its folders persist, so one project's run could in principle disturb another's
  folder. That is accepted because every project on it is the operator's own and the box
  holds nothing worth taking; it is the reason §R5 is absolute. A symlink in a worktree is
  synced as a link, never followed, so a link to a secret outside the worktree does not
  carry the secret.
- **R6** Access is **key-only SSH on port 2222**, the only inbound rule, authorized for the
  machine identity of the box that ran `up` (the Linux devbox — [devbox.spec A6]). There is
  no password on the VM at all, and agent forwarding is off in its sshd.

## L — Lifecycle (the box owns it)

- **L1** The box is **deallocated by default**; it runs only while a run needs it.
- **L2** The **runner only ever starts** the box (`az vm start`, idempotent). It never
  stops or deallocates it — so concurrent sessions cannot stop the box under one another.
  A runner that finds the box mid-deallocation waits for that to finish before starting it.
- **L3** A **box-side idle monitor** (a systemd timer, every 5 minutes, as root)
  deallocates the box when **no run is active AND** it has been idle longer than
  `IDLE_MINUTES` (default 10). *Active* = the run lock (§C1) is held. *Idle* is measured
  from the newer of the heartbeat (§C2) and the boot time, so a box that was just started
  has a full window before its first heartbeat. The monitor keeps the lock from its
  decision until its deallocate call and stands down if the heartbeat moved meanwhile, so
  a run arriving in that moment is not started on a box that is about to go.
- **L4** The idle monitor is also the **crash-safety net**. The lock is a kernel `flock`,
  released when its holder dies however it dies, so a killed run cannot pin the box; and a
  dead run's heartbeat goes stale. There is no path that leaves the box running
  indefinitely after activity stops.
- **L5** **Deallocate, not power off**: an OS shutdown leaves the VM allocated and billed.
  The monitor calls ARM with the VM's system-assigned managed identity (token from the
  instance metadata service; no credential on disk), which holds the single-action role
  `devbox-self-deallocator` scoped to this VM. The OS disk persists, keeping §S4's
  per-branch folders warm.
- **L6** The monitor is installed by `up` and `toolchain` for profiles that set
  `IDLE_MINUTES`, and only for them: a workspace must never turn itself off.

## S — Source sync & workspace on the box

- **S1** A worktree is synced to **`$CI_DIR/<repo>/<branch>`** (default `/srv/ci`), one
  folder per branch per repository, by **rsync over SSH**. `<repo>` is the name of the
  repository's main checkout plus a short hash of its path — the same for every linked
  worktree, different for two repositories that share a folder name. Both names are
  reduced to `[A-Za-z0-9._-]`; a branch name that had to be changed carries a short hash
  of the original, so `feat/x` and `feat-x` never share a folder. A checkout at a bare
  commit is `detached-<commit>`.
- **S1a** The sync compares **content**, not size and time, so an edit can never be
  skipped; and it is time-limited to finish before the box stops waiting for it (§C3).
- **S2** What is synced is **what git knows about** in the worktree: tracked files plus
  untracked files that are not ignored (`git ls-files --cached --others
  --exclude-standard`). Ignored files — `node_modules`, build output, `tmp/`, `.env` —
  never leave the devbox. git decides rather than rsync's own reading of `.gitignore`,
  which gets negations (`!.env.example`) wrong.
- **S3** Uncommitted working-tree edits **are** included (the point is to test in-progress
  work), so the sync is from the working tree, not a git fetch.
- **S4** The branch folder is **kept between runs**, so installs and builds are warm. The
  sync only adds and updates; a file deleted from the worktree is removed on the box by
  comparing this sync's file list with the previous one for that branch. The list is sent
  before the files, and a sync that is given up on partway is added to the branch's
  record, so files it did deliver are still reconciled by the next run. `--clean` wipes
  the folder first.
- **S5** The folder holds a **stand-in git repository**: one snapshot commit of what is
  there, re-made each run, with no history, no remote and no credentials — so a check
  that asks git for the project's files works. A check that needs real history or a
  remote fails there, and that is a finding to report, not something to work around.
- **S6** Folders are **self-garbage-collected** each run, under the lock: drop those
  unused for more than `CI_RETAIN_DAYS` (default 14) and those of the run's own
  repository whose branch no longer exists there; evict least-recently-used first while
  free disk is under `CI_MIN_FREE_GB` (default 20). Never the folder of the run in
  progress. GC never fails a run.

## C — Concurrency

- **C1** Runs are **serialized by a box-wide lock**; concurrent invocations **queue**, they
  do not fail. Rationale: a check starts its own services on fixed local ports (anvil's
  Postgres on `127.0.0.1:5435`), so two at once would collide. One process holds the lock
  from **before the sync until after the command**, so two runs on the same branch cannot
  interleave their files either.
- **C2** Each run maintains a **heartbeat** for as long as it lives — queued, waiting for
  its sync, and running — that §L3 reads. A queued run keeps the box alive.
- **C3** Lock acquisition **times out** (default 60 min) rather than hanging forever, and a
  run whose sync never arrives gives the lock back after 15 min: a stuck or vanished peer
  surfaces as an error (exit 75), never as an endless wait.
- **C4** Nothing the command leaves running can hold the lock or outlive its turn: it is
  started with the lock's descriptor closed, whatever is still running in its process
  group when it exits is stopped before the lock is given up, and if the runner itself is
  killed outright its command is stopped within seconds and its heartbeat ends. Docker
  containers are the daemon's, not the command's, and are left as the project left them.
- **C5** There is **one box, shared** by every session. If throughput ever matters, the
  remedy is a second appliance, not parallel runs on this one.

## X — Execution & results

- **X1** A run executes **one command**, as shell text, in the branch folder, as the
  unprivileged login user, with stdin closed. The command is an argument (`--cmd`, or
  everything after `--`).
- **X2** With no command the **project says what its check is**: `LIN_TEST_CMD=` in its
  committed `scripts/lin-test.env`; else, for a `package.json` that pins pnpm and has a
  `check` script, `corepack pnpm install --frozen-lockfile && corepack pnpm check`.
  Otherwise the run is **refused** — it never guesses.
- **X2a** The box has **only what the command makes**. A check whose tests run only when
  something was built on the machine beforehand (a local Docker image, a downloaded
  browser) will skip those tests there — the same total, fewer executed. A project that
  wants them run names the build in its `LIN_TEST_CMD`; the skipped count in §X9 is how
  the difference shows.
- **X3** **Nothing secret goes to the appliance.** There is no credential-forwarding
  channel. If a check needs a secret to pass, that is a finding to report.
- **X4** The runner's **exit code is the command's** (0 iff it exited 0). Codes that are
  not a verdict on the code: **124** the command passed its limit and was stopped; **75**
  the run never executed (lock or sync timeout); **130** it was abandoned. A run that
  could not start (box unreachable, no config, no command) is a **loud failure**, never a
  silent pass.
- **X5** The command has a **time limit enforced on the box** (`LIN_TEST_TIMEOUT`, default
  40 min, or the repo's value in `scripts/lin-test.env`): past it, the command's whole
  process group is stopped. Enforced there so a caller that has gone away cannot leave a
  hung run holding the lock.
- **X6** Completion is signalled by an **artifact, not the SSH channel**: the box-side
  runner's final act is writing `done.json` (run id, exit code, seconds, error, summary),
  atomically and once. The run is detached on the box and outlives a dropped connection;
  the live output stream is a convenience and may drop without affecting the verdict.
- **X7** The orchestrator **never blocks indefinitely**: every poll is itself
  time-limited, a box that stops answering for two minutes on the clock — while queued or
  while running — is reported as lost contact, and past the command's limit plus a margin
  it exits 124 with diagnostics. A caller that
  leaves without a verdict tells the box to abandon the run.
- **X8** The run's **log and verdict are fetched** into the tested worktree's
  `tmp/lin-test/<run id>/` (`tmp/lin-test/latest` points at the newest) — not the caller's
  current directory. A run that claims success without its verdict fetched is reported as
  a **failure**: green needs evidence.
- **X9** The run ends with a **machine-readable line**:

  ```
  LIN-TEST-SUMMARY repo=<r> branch=<b> rc=<n> seconds=<n> counts=vitest runs=<k> passed=<n> failed=<n> skipped=<n>
  LIN-TEST-SUMMARY repo=<r> branch=<b> rc=<n> seconds=<n> counts=none
  ```

  `rc` is the verdict. The counts are read from the test runner's own summary lines in
  the log (vitest's `Tests  N passed | M failed`), summed over every test run in it;
  `counts=none` when the output has no summary the runner recognizes — never zeros that
  would read as "nothing failed".

## I — Invocation & wiring

- **I1** The operator/agent entry point is **`/lin-test`** on the Linux devbox, which calls
  `~/.claude/scripts/lin-test-launch.sh` (detached; logs to the worktree's `./tmp/lin-test/`,
  appends `WRAPPER_EXIT <rc>`) or `~/.claude/scripts/lin-test.sh` (foreground). The
  launcher holds no lock and refuses nothing: overlapping runs are expected and queue on
  the box (§C1).
- **I2** The **box-side runner is not installed on the box**: the orchestrator copies its
  own copy over at the start of every run, so the two halves cannot drift apart.
- **I3** Box identity + tunables reach the runner via
  **`~/.config/devbox/lin-test/runner.env`**, written by `devbox -p lin-test up`. If it is
  absent the runner **fails with a clear "stand up the appliance first"** message.
- **I4** The runner reaches the box by SSH **from inside its script**, with the devbox's
  machine key, never a forwarded agent. The devbox's guard against ad-hoc SSH is
  unchanged: an agent still cannot compose a connection to the box itself. The host the
  script connects to comes only from a `runner.env` under `~/.config/devbox/`, and its
  host, port and user are checked before use — the script cannot be pointed at a
  destination of the caller's choosing.
- **I5** Policy lives where it's loaded on demand: the **rule** in global CLAUDE.md (a
  full check runs on the devbox one at a time, through a lock; when the lock is taken →
  `/lin-test`), the **procedure** in the
  command + scripts + this doc, the **what-the-check-is** in each project's own repo (§X2).

## Verification

- `tests/lin-test.test.sh` exercises the box-side runner against a scratch directory (lock
  and queueing, sync hand-off and deletions, the stand-in repository, limits, abandonment,
  the verdict and its counts, pruning), the idle monitor's decision in dry-run, and the
  command resolution of §X2. No network.
- Live, on the appliance: `devbox -p lin-test up` from nothing, `doctor`, a full
  `/lin-test` of a project's check with counts compared against the same check on the
  devbox, two runs asked for at once, and the box found deallocated (`az vm list -d`)
  after being left alone.
