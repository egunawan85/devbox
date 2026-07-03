# win-test — overview

> Why the appliance exists and the mental model. Durable. For the contract (what must be
> true), see [win-test.spec.md](./win-test.spec.md). For the box itself, see
> [devbox.overview.md](./devbox.overview.md).

## Why

I develop on the Linux **devbox**, but two projects (`runegate`, `kash-cards`) have test
suites that **only run on Windows** — they target .NET Framework 4.8 and SQL Server
LocalDB, neither of which exists on Linux. I don't want to develop on Windows just to run
those tests, and I don't want to pay for a Windows box that sits idle 24/7 (the old
workspace box idled at ~4% CPU and still cost ~$360/mo).

So Windows stops being a place I *work* and becomes a thing I *call*: an ephemeral
**test appliance**. It wakes on demand, runs a suite against a synced copy of my
worktree, hands back the results, and deallocates itself. I stay on Linux the whole time.

## Mental model

> **devbox is a workspace I live on. win-test is an appliance I call.** Naming follows
> role — the moment a box stops being somewhere I develop, it stops being a "devbox".

```
   Linux devbox (workspace)                         Azure win-test (appliance)
  ┌──────────────────────────┐                     ┌────────────────────────────┐
  │ edit code, git worktrees │   /win-test         │  Windows Server            │
  │ run unit tests locally   │ ───────────────────►│  .NET SDK + MSBuild        │
  │                          │  1 wake (az start)  │  SQL Server LocalDB        │
  │ claude + gh over HTTPS   │  2 rsync worktree   │  OpenSSH server            │
  │                          │  3 dotnet test      │  C:\ci\<branch> (per-branch)│
  │ results ◄────────────────│  4 fetch TRX        │                            │
  └──────────────────────────┘                     └────────────────────────────┘
                                                      self-deallocates when idle
   cost: pay only for the minutes tests actually run  ── target ~$40/mo, down from ~$360
```

## How a run feels

I'm in a `runegate` worktree and ask for the integration tests. Claude knows (from the
global rule + the project's CLAUDE.md) that these need Windows, so it runs `/win-test`.
The box wakes (~60s the first time, instant if still warm from a recent run), my worktree
syncs over, `dotnet test` runs on real Windows against LocalDB, and the pass/fail comes
back into `./tmp/win-test/`. The box turns itself off a while later. I never opened an RDP
session or thought about Windows.

## Key choices

- **Appliance, not workspace.** win-test holds the test *engine* (SDK, MSBuild, LocalDB),
  not my code. Worktrees are synced in per run; nothing to develop on, nothing to back up.
- **Credential-free.** The unit + integration suites are hermetic — LocalDB integrated
  auth, in-process `TestServer`, mocked externals, secrets injected in-test. The appliance
  never needs my vault to run them. (The E2E/staging suite *does* need real secrets, so it
  stays where it belongs: a scheduled GitHub Action, not this box.)
- **Deallocated by default — ephemerality is what saves the money, not the SKU.** It's off
  unless a run is happening, so compute cost tracks actual use (the ~90% saving). It runs
  a fixed-perf `D4ads_v7` (same family as the old box): burstable was the instinct, but
  it's unavailable on this subscription *and* moot — you don't pay for idle you don't have,
  and during a run you want full throughput to finish and deallocate.
- **The box owns its own lifecycle.** A box-side idle-monitor deallocates it once no run
  is active and it's been idle a while. The Linux runner only ever *starts* it — so
  parallel sessions can't stop the box out from under each other; they just queue.
- **Clean cutover from the old box.** win-test is built fresh with role-matching names,
  not renamed in place — so it sheds the old workspace's baggage and proves the repo can
  reproduce it.

## Out of scope (for now)

- Porting the suites off Windows (net48 → net8, LocalDB → containerized SQL). A real
  migration; not worth it just to retire a VM.
- Running the E2E/Playwright staging suite here — that's the scheduled GitHub Action's job.
- Parallel test execution on one box — the shared LocalDB forces serialization. If
  throughput ever matters, stand up a second appliance and shard.
