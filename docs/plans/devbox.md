# devbox — build plan

> Ephemeral build checklist. **Delete this file when the feature ships.** Tracks
> *how* we reach [../devbox.spec.md](../devbox.spec.md); the spec tracks *what* must
> be true. This is the live working doc — update Status + Worklog as we go.

## Status

- **Phase:** 0 ✅, 1 ✅, 2 (DigitalOcean) 🔨 built + statically verified; **live apply
  pending** (gated on operator token + go-ahead). Azure/Windows = Phase 2b (deferred).
- **Branch:** `feat/devbox-deploy` (off `main`).
- **Next action:** operator runs `doctl auth init`, fills `deploy/devbox.conf`, then
  we do a gated `devbox up` (real infra, costs money) and verify end-to-end (Phase 3).
- **Blocked on:** nothing to build; live apply needs the DO token + explicit approval.

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
    ├── devbox                   # operator CLI (bash): up / configure / down / ssh / status
    ├── cloud-init.yaml          # first-boot template: user, SSH hardening, toolchain
    ├── devbox.conf.example      # config template (copy to devbox.conf, gitignored)
    └── README.md                # component setup + gotchas
    #  (Azure/Windows provisioning lands in its own subdir later)
```

Note: moving `CLAUDE.md` into `claude-config/` keeps the deployable payload
self-contained, but means this repo no longer auto-loads it as its own project
instructions. If we want devbox-repo-specific agent guidance, add a separate root
`CLAUDE.md` (or `.claude/CLAUDE.md`) later — decide during Phase 0.

## Tooling decision

- **Provision → `doctl` + `cloud-init` + bash** (chosen over Terraform). `doctl` is
  already installed; no new deps. **No state file** — DigitalOcean is the source of
  truth: the CLI queries "is there a droplet named `devbox`?" for idempotency and
  deletes by name/tag for teardown. (Mooted the "where does TF state live?" question.)
  Trade-off: idempotency is hand-rolled, no plan-preview — fine for one box. Revisit
  Terraform only if this grows into managing real infrastructure.
- **Configure → install script over SSH**, driven by the `deploy/devbox` bash CLI
  (operator is macOS). Same script serves the config-only path (D2).
- `cloud-init` does box + user + SSH hardening + toolchain only (no secrets, no repo).
  The repo clone + `install.sh` happen in `configure`, over an agent-forwarded SSH
  session — so a private repo clones via the operator's forwarded key, not a key at
  rest on the box.
- _Azure/Windows (Terraform or `az` CLI) deferred to its own phase._
- _Ansible deferred_ — revisit only if config grows beyond "link files + install a
  few packages."

## Checklist

### Phase 0 — restructure & cross-OS payload (C3, C4) — ✅ DONE (in `main`)
- [x] GitHub repo renamed `claude-config` → `devbox`; `main` pushed. Local checkout
      dir rename (`claude-configs/` → `devbox/`) left to operator (can't rename the
      session's anchored cwd mid-run).
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

### Phase 2 — DigitalOcean provisioning (P, D, N, A) — 🔨 BUILT, not yet applied
- [x] `deploy/cloud-init.yaml`: user `eddyg` (sudo), 2 device keys, SSH hardening
      (port 2222, no password, no root, agent forwarding), 24.04 socket port override,
      toolchain (git, gh, Node LTS, Claude Code). No secrets, no repo at boot.
- [x] `deploy/devbox` CLI (doctl + bash): `up` / `configure` / `ssh` / `status` /
      `render` / `down`. Idempotent via "does droplet exist?"; firewall = inbound
      tcp/2222 only, outbound open; ensures DO ssh keys; `configure` clones repo over
      forwarded agent + runs `install.sh` + verifies toolchain & guard.
- [x] `deploy/devbox.conf.example`, `deploy/README.md`, root `.gitignore`
      (ignores `devbox.conf`).
- [x] Static verification: `bash -n` clean; `render` produces valid cloud-init YAML
      (ruby-checked), correct substitution, exactly 2 keys, no leftover placeholders.
- [x] External red-team (no Critical) → fixed H1 (existence keyed on name, not IP →
      no duplicate droplet), H2 (firewall reconciled to spec every run, not name-only),
      M1 (verify sshd listener on port; don't swallow socket-restart failure),
      M2 (no agent forwarding until host key pinned), M3 (pin GitHub host keys in
      cloud-init; strict clone), M4 (guard wrapper bypasses + quoted-env regex),
      M5 (prune known_hosts on down; spec D4 carve-out for keys), L1/L2/L4. L3/L5
      documented. Re-verified: bash OK, guard 19/19, render valid YAML.
- [ ] **Live apply (gated):** needs operator's DO token (`doctl auth init`) + the two
      real pubkeys + explicit go-ahead. Costs money / creates real infra.

### Phase 2c — env/secrets (`devbox env`) — POST-RT, design captured (spec §E)
- [ ] `devbox env push [subpath]` / `pull [subpath]`: rsync the local sparse-shadow
      store (`~/devbox-secrets/`, mirrors `proj/`) to/from the box; `pull` filters to
      `.env*`. Editing/organizing stays in the operator's editor.
- [ ] Deliver into **tmpfs** on the box (RAM-only, gone on reboot), not the project
      dir on disk (E1).
- [ ] Add `AcceptEnv DEVBOX_*` to the SSH hardening + document a `SendEnv` snippet
      (optional env injection path).
- [ ] Vault: deferred — when adopted, lean SOPS+age; unlock credential stays on the
      operator machine (forwarded), never at rest on the box (E5).

### Phase 2b — Azure / Windows (deferred)
- [ ] Windows VM provisioning (`az` CLI or Terraform), NSG inbound 2222 only, no RDP.
- [ ] `install.ps1` (Windows): mirror `install.sh`; verify on the Azure box.

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
- **2026-06-16** Decisions for Phase 2: interactive auth (no secrets at rest),
  region SGP (`sgp1`), local gitignored state, size `s-2vcpu-4gb`, Ubuntu 24.04, SSH
  port 2222. Pushed `main` to GitHub (`egunawan85/devbox`); renamed the repo. Note:
  `terraform` is NOT installed locally (`doctl` is) — tooling choice for `deploy/`
  reopened (doctl+bash vs install Terraform).
- **2026-06-16** Phase 2 (DigitalOcean) built with **doctl + cloud-init + bash** (no
  Terraform/state). Added `deploy/{devbox, cloud-init.yaml, devbox.conf.example,
  README.md}` + root `.gitignore`. CLI: up/configure/ssh/status/render/down. Fixed two
  bugs during verification: BSD-awk multi-line `-v` (switched key injection to
  getline-from-file) and the marker string also matching the header comment (now
  whole-line match). Added `GIT_SSH_COMMAND=accept-new` so the box's clone over the
  forwarded agent doesn't choke on GitHub's host key. Static checks pass; **live apply
  not run** (no DO token here, and it's gated infra). Opened a review worktree at
  `/Users/eddyg/Dev/proj/devbox-rt` (branch `rt/devbox-deploy` @ `bde789c`) for an
  external red-team; awaiting findings.
- **2026-06-16** Design session: env/secrets management. Captured as spec §E. Decisions:
  box is a conduit not a store; `.env` secrets = sparse shadow of `proj/`
  (`~/devbox-secrets/`), `devbox env push|pull` only (edits in the editor); deliver into
  **tmpfs** (no plaintext at rest); runtime exposure is inherent (mitigate by scoping /
  short-lived creds / dev-vs-prod split / target-pulls-own-secrets). Vault deferred
  (lean SOPS+age; HashiCorp Vault overkill). Queued as Phase 2c (post-RT). Discussed
  SSH-agent-forwarding mechanics (challenge-response signing) for vault unlock.
- **2026-06-16** External RT came back (no Critical; 2 High, 5 Medium, 5 Low). Worked
  through all: fixed H1, H2, M1–M5, L1, L2, L4 in `deploy/devbox` + `cloud-init.yaml` +
  `git-write-guard.js`; documented L3/L5; amended spec D4 (SSH-key carve-out).
  Notable: dropped agent forwarding until the host key is pinned (M2); reconcile the
  firewall every run since it's the sole N1 control (H2); existence keyed on droplet
  name not IP to avoid a duplicate billable droplet (H1); guard gained a conservative
  wrapper fallback for `sh -c`/`eval`/`xargs git` (M4). Re-verified statically (bash
  -n, guard 19/19, render→valid YAML, L1 rejects bad input). RT worktree
  `/Users/eddyg/Dev/proj/devbox-rt` can be removed. Still gated: live `up`.
