# devbox — build plan

> Ephemeral build checklist. **Delete this file when the feature ships.** Tracks
> *how* we reach [../devbox.spec.md](../devbox.spec.md); the spec tracks *what* must
> be true. This is the live working doc — update Status + Worklog as we go.

## Status

- **Phase:** 0 ✅, 1 ✅, 2 ✅ (DigitalOcean, RT-hardened), 2c ✅ (OpenBao **prod** vault,
  2× external RT). `devbox up` is now **one command** (provision → configure → vault
  init/unseal → load all secrets), idempotent. All on `main`. Azure/Windows = 2b (deferred).
- **Branch:** `main` (all feature branches merged).
- **Linux path: live-verified (2026-06-17).** Provision + configure + vault + secrets +
  V1/V2/V4 all confirmed on a real DO box (`178.128.85.201`). One note: `AUTOSEAL_TTL=5min`
  is aggressive for interactive admin (see Phase 2c finding).
- **Next action:** Windows/Azure (Phase 2b) is the only build work left. Optional Linux
  follow-up: verify the standalone config-only path (D2, Phase 3) against this same box —
  no new infra needed. Then delete this plan file once Windows ships.
- **Blocked on:** nothing for Linux. Windows/Azure deferred. Also pending (operator,
  non-blocking): rename local checkout `claude-configs/` → `devbox/`.

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
- [x] Q6: no separate root `CLAUDE.md` for repo-local agent guidance — skipped.

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
- [x] **Live apply (2026-06-17):** real droplet `devbox` @ `178.128.85.201` (sgp1) was
      provisioned via this flow and verified end-to-end — cloud-init `done`, `eddyg`,
      toolchain, `~/.claude` install, firewall (only 2222 reachable; 8200 refused from
      net). See Phase 3 / Phase 2c live-verify entries.

### Phase 2c — OpenBao vault on the box (`devbox vault`) — 🔨 BUILT, live-pending
_Decisions (final): **OpenBao production mode** (`file` storage, sealed-on-disk),
single unseal key (1-of-1), **re-init per box**; store = `~/devbox-secrets/<project>.env`;
vault path = `secret/<project>`. (Dev/in-memory mode removed.)_
- [x] cloud-init installs **OpenBao** (pinned `.deb` + SHA256-verified).
- [x] `devbox vault up`: writes the prod HCL config (file storage, listener on
      `127.0.0.1`, TLS off), starts `bao server`, reports initialized/sealed + next step.
- [x] `devbox vault init`: `operator init -key-shares=1 -key-threshold=1`, unseal,
      enable kv-v2 at `secret/`, install root token on box (0600), save unseal key +
      root token to the laptop (`vault-keys.json`, 0600). Keys/token via stdin/env only.
- [x] `devbox vault unseal`: re-unseal from the saved laptop key (post-reboot).
- [x] `devbox vault load <project>`: `.env` → JSON (`jq`) → `secret/<project>` over SSH.
- [x] `devbox vault status`; app-read path documented in `deploy/README`.
- [x] Static verify: `bash -n` clean; no dev-mode remnants; usage shows all vault cmds;
      `env_to_json` unit-tested (export/CRLF/spaces/`=`/junk).
- [x] **Live verify (2026-06-17, box `178.128.85.201`):** V4 DONE — round-trip verified
      this session; teardown ("nothing usable after `down`") verified by the operator in
      a prior run (box kept alive this session).
      Confirmed: prod `bao server` runs as `eddyg` under **system** unit
      `devbox-vault.service` (active/enabled; vendor `openbao.service` disabled), boots
      **sealed**, 1-of-1 shamir, `file` storage; `vault unseal` from the laptop key works;
      `vault load _v4test` (`.env`→JSON→`bao kv put -` stdin) and **read-back from inside
      SSH** with the **scoped app token** round-tripped all 3 keys byte-exact (incl. a URL
      with `=`/`&`); **`:8200` unreachable from the network** (curl from laptop times out —
      only 2222 open); auto-seal timer + `devbox-secrets.service` (E8) present. Test secret
      deleted, vault re-sealed, laptop throwaway removed. **Still unverified:** "nothing
      after teardown" (kept the box — needs an actual `down`).
      ⚠️ Finding: `AUTOSEAL_TTL=5min` re-sealed the vault mid-session and made a cleanup
      `kv delete` fail with 503 — had to re-unseal. Not a bug (E9 by design), but 5min is
      aggressive for interactive admin work; load-then-use promptly, or raise the TTL.

### Phase 2b — Azure / Windows (deferred)
- [ ] Windows VM provisioning (`az` CLI or Terraform), NSG inbound 2222 only, no RDP.
- [ ] `install.ps1` (Windows): mirror `install.sh`; verify on the Azure box.

### Phase 3 — verify & document (V1–V3)
- [x] End-to-end **Linux** (2026-06-17, box `178.128.85.201`): `claude --version`
      (2.1.178) ✅, `gh auth status` healthy (egunawan85, ssh) ✅, guard → `ask` on
      `git commit` + wrapped `git -C … push`, silent on `git status` ✅ (V1), forwarded
      agent visible on box + private `ls-remote` of `egunawan85/devbox` works (V2) ✅.
      _(Windows end-to-end still pending — Phase 2b.)_
- [x] Verify config-only mode against a pre-existing box (D2) — 2026-06-17,
      `configure --host 178.128.85.201`: pinned host key, pulled repo over forwarded
      agent (ff to `7727435`), idempotent install, toolchain+guard verify green,
      session-secrets installed. Re-ran → "Already up to date", converged (D3), exit 0.
- [x] Update root `README.md`; write `deploy/README.md` (deploy runbook done; root
      README's Deploy section now reflects the built Linux path).
- [x] Resolve spec open questions (N3, T4, T2 gh auth, P3 defaults, TF state) — all
      captured in the spec's "Resolved decisions (2026-06-16)" section.
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

**All resolved** — see the spec's "Resolved decisions (2026-06-16)" section. Q1/Q2
auth = interactive (no secrets at rest); Q3 = `sgp1` / `s-2vcpu-4gb` / Ubuntu 24.04;
Q4 (TF state) = moot, no Terraform; Q5 = SSH port 2222; Q6 = no root `CLAUDE.md`. Table
kept for history.

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
- **2026-06-16** Merged Phase 2 to `main` and pushed (`eb0f1de`); internal RT on the
  hardening diff clean (guard 33/33). Removed RT worktree + branches.
- **2026-06-16** Secrets design **redone** after I prematurely started building the
  tmpfs/rsync `devbox env` (reverted, never committed; was also wrongly on `main`).
  Long plain-English alignment → final model: **OpenBao vault on the devbox**, bound to
  `127.0.0.1`, gated by the SSH login (OpenBao has no SSH-key auth, so localhost-behind-
  SSH is the gate). App secrets live **plaintext, structured, on the operator's laptop**
  (durable home) and are pushed in per session via `devbox vault load`; the vault dies
  with the box. The SSH key authenticates *access*, not encryption. Rewrote spec §E
  (E1–E7), V4, overview, and Phase 2c on branch `feat/devbox-vault`. Building next.
- **2026-06-16** Built Phase 2c on `feat/devbox-vault`. E7 = **in-memory** (OpenBao dev
  mode). cloud-init installs OpenBao (latest .deb); CLI gains `vault up`/`load`/`status`
  (localhost-bound dev server, SSH-gated; `.env`→JSON→`secret/<project>` over SSH).
  Config + README updated. Static checks pass (`bash -n`, `env_to_json` unit-tested).
  **Not live-verified** — needs a real box (and a check of OpenBao's `.deb` asset URL).
- **2026-06-16** Switched OpenBao **dev mode → production mode** (operator preference;
  "use root key", then "remove dev mode"). Now: `file` storage (sealed/encrypted on
  disk), listener on `127.0.0.1` TLS-off, single unseal key (1-of-1), **re-init per
  box** (E7). New CLI: `vault up` (start server, report status), `vault init`
  (init+unseal+enable kv+save keys to laptop), `vault unseal` (re-unseal from saved
  key), plus `load`/`status`. Unseal key + root token travel via stdin/env only (never
  argv). Updated spec §E1/E5/E7, README, plan. Static checks pass; live-pending.
- **2026-06-16** Prod-mode vault RTs. Internal: fixed the README app-read one-liner
  (`export $(...)` → `set -a; eval … @sh`, injection-safe) and an ambiguous init error.
  External #2 (credential handling PASSED): fixed H1 (flock fd leaked into `bao server`
  → 2nd `vault up` hung; close `9>&-` + `flock -w`), M1 (interrupted-init catch-22 →
  detect unrecoverable + tell operator to re-provision), M2 (least-privilege: box gets a
  `devbox-app` token scoped to `secret/*`, not root; root stays on laptop), L1–L4. Branch
  `feat/devbox-vault` @ a19d02d. Two RT worktrees still on disk (devbox-vault-rt,
  devbox-vault-rt2). Live-pending.
- **2026-06-17** **First live verification** against a real box (`178.128.85.201`,
  sgp1). Read-only probes: box up as `eddyg`, cloud-init `done` + `devbox-ready` present,
  toolchain all there (claude 2.1.178, gh 2.94, git 2.43, node v24.16, OpenBao 2.5.4);
  `~/.claude` correctly symlinks CLAUDE.md/settings.json/hooks into the cloned repo;
  vault initialized + sealed (prod/file/1-of-1) under **system** unit
  `devbox-vault.service`. Then ran V4: unseal → `vault load _v4test` → read back inside
  SSH (scoped app token) → all keys byte-exact → confirmed `:8200` unreachable from the
  network → deleted the test secret → re-sealed. `gh` not yet authed (interactive, by
  design — operator to run `gh auth login`); V1 gh-check, V2 agent-forward ls-remote, and
  the post-teardown check remain. Observed `AUTOSEAL_TTL=5min` fire mid-session (sealed a
  cleanup `kv delete` out → 503); flagged in Phase 2c. Box kept, vault re-sealed.
- **2026-06-17** Completed live V1/V2 + closed V4. After operator ran `gh auth login`:
  `gh auth status` healthy; guard fires `ask` on `git commit` / wrapped `git -C … push`,
  silent on `git status`; forwarded agent visible on the box (`ssh-add -l` over `-A`) and
  private `git ls-remote git@github.com:egunawan85/devbox` works (V2). V4 round-trip done
  earlier this session; teardown ("nothing after `down`") confirmed by operator from a
  prior run, so box kept alive. Marked Phase 2 live-apply + Phase 3 Linux end-to-end +
  Phase 2c V4 done. Linux path is fully live-verified; only Windows/Azure (2b) + optional
  D2 config-only check remain.
- **2026-06-17** Re-ran the full Phase 2/2c **static** verification against current
  `main` (after bad-VM detector, vault-under-systemd, session-secrets, auto-seal TTL,
  bare-`devbox` install all landed post-RT). All green: `bash -n` on `devbox` +
  both `install.sh`; `node --check` on the guard; `render` → valid cloud-init YAML
  (parses, `#cloud-config`, substitution OK, key injected, no `__PLACEHOLDER__` left,
  ASCII-clean); `env_to_json` unit cases (export/CRLF/spaces/`=`-in-value/junk/empty);
  no dev-mode remnants; all 5 vault subcommands wired + documented; `help` renders.
  The remaining Phase 2/2c items are the **live** tests only (need a real box + DO
  token + spend). Also crossed out: Phase 0 Q6, Phase 3 READMEs + spec-open-questions.
- **2026-06-16** Made `devbox up` one command (provision → configure → vault
  init/unseal → load all `~/devbox-secrets/*.env`), idempotent on re-run. Refactor:
  `vault_start` (server-start, returns seal-status), `vault_bringup` (init/unseal as
  needed), `vault_load_all`, `vault_host` (reuses up's IP). Vault defaults moved to
  `load_conf`. Docs cleaned: spec D1, plan Status, README usage. Linux path complete;
  only the live deployment test remains.
