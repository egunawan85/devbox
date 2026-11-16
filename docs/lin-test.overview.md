# lin-test — overview

> Why the appliance exists and the mental model. Durable. For the contract (what must be
> true), see [lin-test.spec.md](./lin-test.spec.md). For its Windows sibling, see
> [win-test.overview.md](./win-test.overview.md); for the box it hangs off, see
> [devbox.overview.md](./devbox.overview.md).

## Why

Several Claude sessions share one Linux **devbox** — 4 cores, 8 GB. A project's full check
is sized for that whole machine: anvil's `corepack pnpm check` builds, lints, and runs
about 1,300 tests, some against a Postgres it starts in Docker, and takes about seven
minutes with the box to itself. Two of those at once, and tests start failing on
timeouts. The failures say nothing about the code; they say the box was busy.

A bigger devbox would cost its full price around the clock to absorb a load that is there
a few minutes at a time. So the check goes somewhere else instead: a second Linux box
that is **off unless a run is happening**, the way win-test already works for the suites
that need Windows.

## Mental model

> **devbox is a workspace I live on. lin-test is an appliance I call.**

```
   Linux devbox (workspace)                          Azure lin-test (appliance)
  ┌──────────────────────────┐                      ┌─────────────────────────────┐
  │ edit code, git worktrees │   /lin-test          │  Ubuntu 24.04               │
  │ quick tests locally      │ ────────────────────►│  Node + corepack, Docker    │
  │                          │  1 wake (az start)   │  Playwright libraries       │
  │ several sessions at once │  2 take the run lock │  /srv/ci/<repo>/<branch>    │
  │                          │  3 rsync worktree    │   (kept warm between runs)  │
  │ log + verdict ◄──────────│  4 run the check     │  no Claude, no vault,       │
  │  ./tmp/lin-test/<run>/   │  5 fetch the result  │  no secrets                 │
  └──────────────────────────┘                      └─────────────────────────────┘
                                                       deallocates itself when idle
```

## How a run feels

I'm in an anvil worktree and want the full check before a PR, and the devbox is busy.
Claude runs `/lin-test`. The box wakes if it was off, my worktree's files — uncommitted
edits included — sync to that branch's folder on the box, and `corepack pnpm install
--frozen-lockfile && corepack pnpm check` runs there with four cores to itself. The
output streams back; at the end there is one line with the exit code and the test
counts, and the full log is in `./tmp/lin-test/`. If another session's check is already
on the box, mine waits its turn and says so. Ten idle minutes later the box turns
itself off.

Measured on the appliance in November 2026, with anvil's check (about 1,290 tests):

| | |
|---|---|
| Wake from deallocated to the first SSH answer | 35 s |
| The check, branch folder warm | about 4 min 40 s |
| The check, first run of a branch (cold install, database image pull) | about 5 min 20 s |
| A second run asked for at the same moment | its own run plus the first one's |
| Idle to deallocated | 10 to 15 min (ten idle minutes, checked every five) |
| `devbox -p lin-test up` from nothing | under 5 min |

## Key choices

- **Appliance, not workspace — and credential-free.** lin-test holds the *engine* (Node,
  Docker, the Playwright libraries), not my code and nothing of mine: no Claude Code, no
  vault, no forwarded agent, no clone of this repo. What reaches it is the files git
  knows about in one worktree, and one command. A check that needs a secret to pass is a
  finding about that check, not a reason to send the secret.
- **Runs queue; they do not run side by side.** A check starts its own services on fixed
  local ports — anvil's Postgres on `127.0.0.1:5435` — so two at once on one box would
  collide exactly as two devbox sessions do. One box-wide lock, held from before the sync
  until after the command, makes them take turns. This is the simplest thing that is
  correct, and it is what win-test does. The alternative — a port per run — would mean
  changing each project to suit the appliance.
- **One box, shared by every session.** A box each would cost more disk and more cold
  starts and buy nothing while runs queue anyway. If the queue ever hurts, add a second
  appliance.
- **The box owns its own lifecycle.** The runner only ever *starts* it. A timer on the box
  deallocates it once no run holds the lock and it has been idle ten minutes — a real
  deallocate, because a VM that is merely powered off is still billed. So parallel
  sessions can't stop the box out from under each other, and a run that dies cannot leave
  it on.
- **git decides what is synced.** The files git tracks plus the untracked ones it does not
  ignore — so `node_modules`, build output and `.env` stay home, and the box's copy of a
  branch keeps its own installs warm between runs. The box gets a stand-in git repository
  (one snapshot commit, no history, no remote) because a check may reasonably ask git
  what the project's files are.
- **The project says what its check is.** `scripts/lin-test.env` in the repo, or the
  obvious thing for a pnpm project with a `check` script. A project that says neither
  gets a refusal, not a guess.
- **The runner travels with the run.** The box-side half is copied over each time rather
  than installed, so there is no second copy on the box to drift from the devbox's.

## What it costs

Prices are Azure's public pay-as-you-go rates for Linux in southeastasia, November 2026.

| | |
|---|---|
| `Standard_D4as_v7` (4 vCPU / 16 GB) while running | $0.228 / hour |
| 64 GB Premium SSD (P6), always | $10.21 / month |
| Static public IP, always | $3.65 / month |
| **Off, per month** | **about $14** |
| One isolated run (the run plus its ten idle minutes) | about $0.08 |
| The same VM left on all month | about $166 |

The size was chosen for the room it had as much as its price: the `D4ads_v7` win-test
uses is the same generation at $0.286/hour, but its vCPU family's quota was nearly spent,
and its extra local disk is of no use to a box that deallocates between runs.

## Out of scope (for now)

- Parallel runs on one box (see above).
- Forwarding secrets to a run. win-test has a narrow channel for that because some of its
  suites cannot run without one; nothing here needs it yet, and not having it is what
  makes "credential-free" a property of the box rather than a habit.
- Suites that need real git history or a remote: the box's copy has neither.
- Pruning Docker images. The box prunes its own branch folders, not what a check pulls;
  with one small database image that is nothing, and `down` + `up` is the reset if it
  ever is something.
