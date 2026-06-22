# devbox — build plan

> Ephemeral build checklist. **Delete this file when the feature ships.** Tracks
> *how* we reach [../devbox.spec.md](../devbox.spec.md); the spec tracks *what* must
> be true. This is the live working doc — update Status + Worklog as we go.

## Status

- **Phase:** 0 ✅, 1 ✅, 2 ✅ (DigitalOcean, RT-hardened), 2c ✅ (OpenBao **prod** vault,
  2× external RT). `devbox up` is now **one command** (provision → configure → vault
  init/unseal → load all secrets), idempotent. All on `main`. Azure/Windows = 2b
  (**planned 2026-06-22**, see Phase 2b — full Layer A/B/C plan + spec §E amendment; build
  not started).
- **Branch:** `main` (all feature branches merged); Windows planning on `worktree-windows-devbox`.
- **Linux path: live-verified (2026-06-17).** Provision + configure + vault + secrets +
  V1/V2/V4 all confirmed on a real DO box (`178.128.85.201`). One note: `AUTOSEAL_TTL=5min`
  is aggressive for interactive admin (see Phase 2c finding).
- **Next action:** Build Phase 2b (Windows/Azure) per the now-detailed plan — start with a
  live de-risk of Layer B (unattended VS Build Tools + SQL Express on a real Server 2022),
  since the spike is paper-only. Optional Linux follow-up: verify the standalone config-only
  path (D2) against the same box. Then delete this plan file once Windows ships.
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

### Phase 2b — Azure / Windows

> **Scope (decided 2026-06-22).** The Windows box is a **build / test / edit** box, not
> an IIS-hosting box: clone the repos, restore (NuGet), build (MSBuild), run the test
> suites, and edit with Claude — no IIS/WCF hosting (deferred; structure for it, don't
> install it). It carries the **first "project profile"** layered on the base devbox:
> the toolchain for **runegate** + **qrypto-omni** (private `s16rv` repos) — classic
> **.NET Framework 4.6.2/4.7.2 + WCF + ASP.NET**, **SQL Server** (TSQL), built with
> **MSBuild + VS Build Tools** (not `dotnet`), secrets via **Azure Key Vault in prod /
> `.vault` locally**. These genuinely require Windows; they are not portable .NET.

**Design decisions (resolved 2026-06-22).**
- **Provisioner = `az` CLI + PowerShell + bash**, mirroring the DigitalOcean choice (no
  Terraform, no state file — Azure is the source of truth; idempotency by querying VM
  name; teardown by name/resource-group). Lives in `deploy/azure/`, dispatched from the
  same `deploy/devbox` CLI.
- **Box role = build/test/edit.** SQL Server **Express, installed on the box** (not
  Docker, not external). IIS/WCF features deferred to a later "run" role.
- **Secrets = OpenBao ported to Windows** (the operator's choice), serving as the
  **dev-time stand-in for Azure Key Vault**. Materialize into each repo's `.vault`/`.env`
  per the amended **spec §E8 (Windows)**: SYSTEM **60 s watchdog** + **4624/4634 event
  triggers**, reference-count wipe-at-zero, **encrypted-disk-at-rest** on the ephemeral
  box (see §E at-rest note). The repos' own Azure Key Vault path (`inject-secrets.ps1`)
  is untouched — that's their prod deploy concern, not the devbox's.
- **Cross-OS guard needs no port** — `git-write-guard.js` already handles the PowerShell
  call/dot-source operator and runs via `node`.

#### Layer A — base Windows devbox (P, D, N, A, C, T1–T2)
- [ ] `deploy/azure/provision.ps1` — first-boot setup via Azure **Custom Script Extension**
      (the cloud-init analog): create `eddyg` (admin), install + enable **OpenSSH Server**,
      set **PowerShell as the default SSH shell**, harden (key-only, no password, SSH on the
      non-default port, agent forwarding), seed GitHub host keys. No secrets, no repo at boot.
- [ ] `deploy/azure` provisioning in the `devbox` CLI (`az` + bash): create resource group +
      Windows Server 2022 VM; **NSG inbound = SSH port only, no 3389/RDP** (N1/N4); idempotent
      by VM name; `down` deletes the resource group (no orphaned billable resources, D4).
- [ ] Teach `cmd_configure` the **`--os windows`** branch (it hard-rejects today at
      `deploy/devbox:505`): clone/pull over the forwarded agent, run `install.ps1`, run the
      verify block in PowerShell.
- [ ] `claude-config/install.ps1` — mirror `install.sh`: link payload into `~/.claude`
      (**directory junctions** to avoid the Developer-Mode/admin symlink requirement),
      preserve `settings.local.json`, back up pre-existing real files, honor `CLAUDE_HOME`.
- [ ] Base toolchain in `provision.ps1`: git, gh, **Node LTS**, **Claude Code CLI**.

#### Layer B — project toolchain for runegate / qrypto-omni (T3, build/test role)
_Heaviest, least-precedented layer. Installed by `provision.ps1` via **direct MSI/exe +
Chocolatey** — **NOT winget** (absent on Server 2022, see spike). Must handle **reboots
mid-install** (exit 3010) and **Machine-PATH refresh**; raise the readiness budget to
~30–40 min for this box._
- [ ] **VS 2022 Build Tools** — Web dev workload + FW targeting packs (verified recipe below).
- [ ] **NuGet CLI** (`nuget.exe` on PATH), **PowerShell 7**, **Azure CLI** (for the repos'
      own Key Vault path), **go-sqlcmd**.
- [ ] **SQL Server Express 2022** on the box — mixed-mode auth + TCP/1433 (repos use SQL
      auth: `DB_USER`/`DB_PASSWORD`); create the least-privilege `pgcrypto_app` login per
      the repos' `DEPLOY_DB.md`.
- [ ] **Deferred (IIS role):** IIS + WCF Windows features, `deploy-iis.ps1`, HTTPS — not in
      the build/test box; revisit when a "run" role is wanted.
- [ ] Verify: clone each repo over the forwarded agent → `nuget restore` → MSBuild the `.sln`
      → run a test project (e.g. `*.Tests.Unit`) green; `sqlcmd` connects to the local instance.

#### Layer C — OpenBao vault on Windows (E1–E9, amended §E)
- [ ] `provision.ps1` installs **`bao` (Windows)** — pinned `2.5.4`, **SHA256-verified
      against `checksums-windows.txt`** (mirror the Linux discipline).
- [ ] `vault_start` (Windows): write the prod HCL (`file` storage, `127.0.0.1:8200`, TLS
      off), run `bao server` as a **Windows Service** (auto-start, boots sealed — E7).
- [ ] `vault_init` / `unseal` / `load` — reuse the **HTTP-API core** (already OS-agnostic);
      PowerShell wrappers (`Invoke-RestMethod`); keys saved to the laptop, scoped `devbox-app`
      token on the box; unseal key/token off argv.
- [ ] **Session-count materializer** (replaces the Linux tmpfs/logind path — §E8 Windows):
      SYSTEM scheduled task (60 s) + 4624/4634 event triggers; recount eddyg SSH sessions
      (per-connection `sshd.exe` owned by eddyg); materialize vault → repo `.vault`/`.env`
      when ≥1 & unsealed, wipe when zero; only-our-files manifest; boot ⇒ wipe stale.
      Manifest = Windows analog of `secrets.map` (`<project> → repo path`).
- [ ] **Auto-seal TTL** (optional, E9): **Scheduled Task** (not systemd timer) + seal-only token.

#### Spike — verified unattended-install recipe (2026-06-22, paper spike)
_Verified against current vendor docs; **live validation deferred** to first Azure
bring-up (no Server 2022 host on the macOS operator machine)._
- **VS Build Tools (silent):**
  `vs_buildtools.exe --quiet --wait --norestart --nocache --add
  Microsoft.VisualStudio.Workload.WebBuildTools --add
  Microsoft.Net.Component.4.7.2.TargetingPack --add
  Microsoft.Net.Component.4.6.2.TargetingPack --includeRecommended`
  — `--wait` is **mandatory** (bootstrapper returns early otherwise); **exit 3010 =
  reboot-required, treat as success-pending-reboot**, not failure.
- **SQL Express 2022 (silent):**
  `/Q /ACTION=Install /FEATURES=SQLEngine /INSTANCENAME=SQLEXPRESS
  /IACCEPTSQLSERVERLICENSETERMS /SECURITYMODE=SQL /SAPWD=<gen>
  /TCPENABLED=1 /SQLSYSADMINACCOUNTS="BUILTIN\Administrators"`.
- **sqlcmd** = go-sqlcmd (Chocolatey/direct zip); **NuGet** = direct `nuget.exe`;
  **PS7 / Azure CLI** = MSI (per the repos' own `DEPLOY.md`).
- **Cross-cutting gotchas:** winget absent on Server 2022 ⇒ direct downloads/Chocolatey;
  handle reboots (3010) + continuation; refresh Machine PATH so new tools resolve;
  generous readiness timeout; VS Build Tools is multi-GB / several minutes.

#### Open risks / to validate live (first Azure bring-up)
- Unattended VS Build Tools + SQL Express on a real Server 2022 (the spike is paper-only).
- Reboot-during-provision orchestration via CSE (single CSE run vs. boot-continuation task).
- Windows OpenSSH session-count signal (`sshd.exe`-per-connection) under VS Code Remote.
- `bao` as a Windows Service surviving reboot + unseal-after-reboot (E7 on Windows).

#### Original stub (superseded by the above)
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
- **2026-06-22** **Planned Phase 2b (Windows/Azure)** for the first concrete project
  profile: the private `s16rv` repos **runegate** + **qrypto-omni**. Inspected both via
  `gh`: classic **.NET Framework 4.6.2/4.7.2 + WCF + ASP.NET**, SQL Server (TSQL), built
  with **MSBuild + VS Build Tools** (not `dotnet`), IIS deploy, secrets via **Azure Key
  Vault (prod) / `.vault` (local)** — genuinely Windows-only. Operator decisions: box role
  = **build/test/edit** (no IIS hosting yet); **SQL Express on the box**; **OpenBao ported
  to Windows** as the dev-time Key-Vault stand-in. Designed the Windows secrets lifecycle
  in depth (the crux being Windows has no logind/tmpfs): materialize vault → repo
  `.vault`/`.env` on **encrypted-disk-at-rest**, wipe by a **reference count** of eddyg SSH
  sessions — **SYSTEM 60 s watchdog** (authoritative; survives hard-kills, dropped
  connections, crash/reboot) **+ 4624/4634 event triggers** (fast path); wipe-iff-zero in
  both. **Amended spec §E** to be OS-parameterized (E7 boot service, E8 Linux-tmpfs /
  Windows-watchdog, E9 timer/scheduled-task, new at-rest note + V5) so the Windows box
  *satisfies* the contract rather than violating its RAM-only clause. Ran a **paper spike**
  (no Server 2022 host on macOS) verifying the unattended-install recipe against vendor
  docs: VS Build Tools workload/component IDs + `--wait`/exit-3010, SQL Express silent
  switches (mixed-mode + TCP), go-sqlcmd/NuGet/PS7/Azure-CLI install paths, and the key
  gotcha that **winget is absent on Server 2022** (use direct MSI/Choco + reboot/PATH
  handling). Wrote the full Layer A (base Windows box) / B (project toolchain) / C (vault
  port) checklist into Phase 2b. **No provisioning/vault code written yet** — next is a
  live de-risk of Layer B on a real Server 2022. Work on `worktree-windows-devbox`.
