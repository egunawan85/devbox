# devbox — build plan

> Ephemeral build checklist. **Delete this file when the feature ships.** Tracks
> *how* we reach [../devbox.spec.md](../devbox.spec.md); the spec tracks *what* must
> be true. This is the live working doc — update Status + Worklog as we go.

## Status

- **Phase:** 0 ✅, 1 ✅ (Linux) → 2 next (provisioning). `install.ps1` carried into
  Phase 2.
- **Branch:** `feat/devbox-scaffold` (in-place branch off `main`; carries the work).
- **Next action:** Phase 2 — `deploy/` provisioning. First resolve open decisions
  Q1–Q5 below; then DO (Linux) Terraform + the `devbox` CLI.
- **Blocked on:** Q1–Q5 before `deploy/` work has a stable target.

## Target repo structure

Repo/project name: **devbox** (rename the current `claude-configs` checkout).

```
devbox/
├── README.md                    # what this is + how to deploy
├── docs/
│   ├── devbox.overview.md
│   ├── devbox.spec.md
│   └── plans/devbox.md          # this file (ephemeral)
├── claude-config/               # COMPONENT 1: cross-OS payload + installers
│   │                            #   a self-contained ~/.claude mirror
│   ├── CLAUDE.md                # (moved from root)
│   ├── settings.json            # (moved from root)
│   ├── hooks/
│   │   └── git-write-guard.js   # single cross-OS guard, run via node
│   ├── install.sh               # Linux: idempotent link into ~/.claude
│   └── install.ps1              # Windows: idempotent link into ~/.claude
└── deploy/                      # COMPONENT 2: provisioning + orchestration
    ├── devbox                   # operator CLI (bash): up / configure / down
    ├── digitalocean/            # Terraform: Linux droplet + firewall + keys
    ├── azure/                   # Terraform: Windows VM + NSG + keys
    └── README.md                # component setup + gotchas (defer until populated)
```

Note: moving `CLAUDE.md` into `claude-config/` keeps the deployable payload
self-contained, but means this repo no longer auto-loads it as its own project
instructions. If we want devbox-repo-specific agent guidance, add a separate root
`CLAUDE.md` (or `.claude/CLAUDE.md`) later — decide during Phase 0.

## Tooling decision

- **Provision → Terraform** (DO + Azure providers; declares firewall/NSG, SSH-key
  upload, teardown — satisfies D1/D4/N1/N2).
- **Configure → per-OS install scripts over SSH**, driven by the `deploy/devbox`
  bash CLI (operator is macOS). The same installers serve the config-only path (D2).
- _Ansible deferred_ — revisit only if config grows beyond "link files + install a
  few packages." Its Windows story (WinRM/SSH) isn't worth the friction yet.

## Checklist

### Phase 0 — restructure & cross-OS payload (C3, C4) — ✅ DONE (in `main`)
- [x] Create `claude-config/`; move `CLAUDE.md`, `settings.json` into it via `git mv`.
- [x] `git-write-guard.ps1` was corrupted (null bytes + damaged literals `'  reset'`,
      `'am  '`, `'--namesp  ace'`) — removed, not salvaged.
- [x] Rewrote the guard as one cross-OS `git-write-guard.js` (Node). 24/24 test cases
      pass (writes→ask incl. reset/am/-C/-c/env/abs/chained/ps-call; reads→silent).
- [x] Rewrote the hook command in `settings.json` to
      `node "$HOME/.claude/hooks/git-write-guard.js"`; dropped the hardcoded
      `C:/Users/runegate-dev/...` path.
- [ ] Q6: decide whether to add a separate root `CLAUDE.md` for repo-local agent
      guidance (recommend: skip for now).

### Phase 1 — Linux installer (C1, C2) — ✅ DONE
- [x] `install.sh`: idempotently symlink `CLAUDE.md`, `settings.json`,
      `hooks/git-write-guard.js` into `~/.claude/`; preserve `settings.local.json`;
      back up (never clobber) pre-existing real files. Honors `CLAUDE_HOME` override.
- [x] Dogfooded into a throwaway `CLAUDE_HOME` on this Mac: links created,
      local settings preserved, hook fires via installed path, idempotent on re-run.
- [→] `install.ps1` (Windows) deferred to Phase 2 — no `pwsh` here to verify it;
      written & tested on the Azure box alongside Windows bring-up.

### Phase 2 — provisioning (P, D, N, A)
- [ ] `deploy/digitalocean/` Terraform: Ubuntu droplet, `eddyg` (sudo), upload the
      two device public keys, firewall = deny inbound / open outbound.
- [ ] `deploy/azure/` Terraform: Windows Server VM + OpenSSH, `eddyg` (admin), keys,
      NSG = deny inbound / open outbound, no RDP.
- [ ] `install.ps1` (Windows): mirror `install.sh` (symlink payload into `~/.claude`,
      preserve `settings.local.json`, idempotent); verify on the Azure box.
- [ ] Network: firewall opens one non-default SSH port, key-only, no IP allowlist;
      all other inbound denied.
- [ ] SSH: register laptop + desktop public keys; print/template an operator
      `~/.ssh/config` snippet with `ForwardAgent yes` for the host (A4/A5).
- [ ] `deploy/devbox` CLI: `up --provider do|azure`, `configure --host --os`,
      `down`. Reads tokens from env / gitignored file (D5). Reports results (V3).

### Phase 3 — verify & document (V1–V3)
- [ ] End-to-end per OS: provision → connect from a device → `claude --version`,
      `gh auth status`, guard fires on `git commit`, forwarded `git ls-remote` works.
- [ ] Verify config-only mode against a pre-existing box (D2).
- [ ] Update root `README.md`; write `deploy/README.md`.
- [ ] Resolve spec open questions (N3, T4, T2 gh auth, P3 defaults, TF state).
- [ ] **Delete this plan file.**

## Decisions / defaults made
- Two providers/OSes: DO→Linux, Azure→Windows (supersedes earlier Linux-only call).
- Terraform (provision) + bash CLI driving per-OS install scripts (configure).
- No private keys on the box; access via existing device keys + SSH agent forwarding.
- Inbound = one non-default SSH port (key-only, no IP allowlist); open outbound;
  Windows over SSH (no RDP). No Tailscale.
- One feature `devbox`; behavior contract in `CLAUDE.md`, deployment contract in
  `devbox.spec.md`.

## Open decisions

None block Phase 0–1. Resolve before the phase noted.

| # | Decision | Options | Blocks |
|---|---|---|---|
| Q1 | Claude Code auth on the box (spec T4) | API key via env · interactive login first use | Phase 2 |
| Q2 | `gh` auth (spec T2) | token via env · interactive `gh auth login` | Phase 2 |
| Q3 | Sizes/regions (spec P3) | pinned defaults · prompt each deploy | Phase 2 |
| Q4 | Terraform state | local gitignored · remote backend | Phase 2 |
| Q5 | SSH port number | pick one default · per-deploy variable | Phase 2 |
| Q6 | Repo-local `CLAUDE.md` | none · add a separate root one | Phase 0 |

## Worklog

_Append dated entries as work happens (newest last). Today: 2026-06-16._

- **2026-06-16** Phase 0. Moved `CLAUDE.md` + `settings.json` into `claude-config/`
  (`git mv`). Found the working-tree `git-write-guard.ps1` corrupted (106 null bytes,
  damaged string literals that would have broken `reset`/`am`/`--namespace` gating) —
  removed it. Replaced both planned `.sh`+`.ps1` guards with a single cross-OS
  `claude-config/hooks/git-write-guard.js` (Node); 24/24 cases pass. Repointed the
  `settings.json` hook to `node "$HOME/.claude/hooks/git-write-guard.js"`. Repo/dir
  not yet renamed to `devbox` (holding until GitHub push). Committed checkpoint
  `fe16acb` on branch `feat/devbox-scaffold`. Q6 resolved: no separate root
  `CLAUDE.md` for now.
- **2026-06-16** Phase 1. Added `claude-config/install.sh` — idempotent symlink
  installer (CLAUDE.md, settings.json, hooks/git-write-guard.js → ~/.claude), preserves
  `settings.local.json`, backs up pre-existing real files, honors `CLAUDE_HOME`.
  Verified into a throwaway home: links ok, local settings preserved, guard fires via
  the installed `$HOME`-relative path, idempotent on re-run. `install.ps1` deferred to
  Phase 2 (no pwsh locally to verify).
