# deploy/ — DigitalOcean devbox provisioning

Stands up a Linux **devbox** on DigitalOcean and installs the `claude-config/`
payload onto it. Tooling: `doctl` + `cloud-init` + a bash CLI — **no Terraform, no
state file** (DigitalOcean itself is the source of truth). Contract:
[../docs/devbox.spec.md](../docs/devbox.spec.md).

## Files

| File | What |
|---|---|
| `devbox` | Operator CLI: `up` / `configure` / `ssh` / `status` / `render` / `down`. |
| `install.sh` | Symlinks `devbox` onto your `PATH` (one-time, so you can run bare `devbox`). |
| `cloud-init.yaml` | First-boot template: creates the user, hardens SSH, installs the toolchain. |
| `targets/*.conf.example` | Per-profile config templates — copy to `targets/<profile>.conf` (gitignored) and edit. |

## One-time setup

1. `doctl auth init` (or `export DIGITALOCEAN_ACCESS_TOKEN=...`).
2. `cp deploy/targets/default.conf.example deploy/targets/default.conf` and edit — set
   `SSH_PUBKEY_FILES` to your laptop **and** desktop public keys.
3. Make sure your private key is loaded in your SSH agent (`ssh-add -l`) — the box
   reuses it via agent forwarding for git; nothing is stored on the box.
4. One-time: put the CLI on your `PATH` so you can run it as bare `devbox` from
   anywhere. From the project root:

   ```sh
   deploy/install.sh
   ```

   It symlinks `deploy/devbox` into a writable PATH dir (prefers `~/.local/bin`).
   Safe to re-run; `deploy/install.sh --uninstall` removes it. (The CLI resolves the
   symlink, so it still reads `deploy/targets/default.conf` and `deploy/cloud-init.yaml` from
   the repo.)

## Usage

**One command does everything:**

```sh
devbox up         # provision + configure + vault (init/unseal) + load all secrets
```

`up` is idempotent — run it again any time to re-converge (re-configure, re-unseal a
rebooted vault, re-load secrets). The rest are for granular control / day-to-day:

```sh
devbox ssh        # connect (agent-forwarded)
devbox status     # show the droplet
devbox configure  # re-install config only (existing box)
devbox render     # print the rendered cloud-init — no API calls (safe to inspect)
devbox doctor     # check operator prereqs (machine identity, provider CLI/auth) — read-only
devbox vault up        # bring the vault to ready (start + init/unseal as needed)
devbox vault load myapp # (re)push one project's ~/.config/devbox/<profile>/secrets/myapp.env
devbox vault refresh myapp # load + re-materialize into a live session (no re-login)
devbox vault status    # initialized / sealed?
devbox down       # destroy droplet + firewall
```

## Windows / Azure (the `windows` profile)

The same CLI provisions a **Windows Server 2022 build box on Azure** for the classic
.NET-Framework repos (MSBuild + SQL Server Express + the OpenBao vault). Select it with
`-p rg` (or `DEVBOX_PROFILE=rg`); it reads `targets/rg.conf` instead of
`targets/default.conf`. The default profile is unchanged — the two coexist on one laptop.

One-time setup:

1. `az login` once on the **operator** machine (browser, or `az login --use-device-code`). The
   subscription is pinned per-profile in `targets/rg.conf` (`SUBSCRIPTION_ID`), so it never
   depends on the globally-active subscription.

   **`[WinError 5]` DPAPI token-cache failure** (the CLI can't encrypt its MSAL token cache and
   `az login` dies with "Encryption failed: [WinError 5] ... Consider disable encryption") shows
   up in two places, each handled automatically:
   - **On the devbox itself** (you `az login` over SSH on the Windows box): `configure`/`up`
     sets `AZURE_CORE_ENCRYPT_TOKEN_CACHE=false` (User scope) on the box every run, so a fresh
     SSH session's `az login` just works. Nothing to do — re-run `devbox -p rg up`.
   - **On a Windows operator machine**: the provider sets the same env var in-process and
     persists `core.encrypt_token_cache=false` to the operator's `~/.azure/config` before the
     login check. A macOS/Linux operator is left untouched (it encrypts fine).

   To do it by hand: `az config set core.encrypt_token_cache=false` (or
   `$env:AZURE_CORE_ENCRYPT_TOKEN_CACHE="false"` for one shell), then log in again. The CLI then
   stores tokens unencrypted under `~/.azure`.
2. `cp deploy/targets/rg.conf.example deploy/targets/rg.conf` and edit — set
   `SUBSCRIPTION_ID` and `SSH_PUBKEY_FILES`.
3. Windows OpenSSH **can't forward your agent**, so project-repo git uses **`gh` over HTTPS**:
   after the box is up, `devbox -p rg ssh` in and run `gh auth login` once. Git is
   pre-wired to use `gh` as its HTTPS credential helper at provision time, so `git clone
   https://github.com/…` works right after — no `gh auth setup-git`, and no Git Credential
   Manager / `wincredman` (which can't persist over a headless SSH session). (The
   `claude-config` payload is delivered push-from-laptop during `configure` — no key needed.)

```sh
devbox -p rg up         # create VM + provision + configure + vault + load + toolchain (first up: +~20-30 min for the build stack)
devbox -p rg toolchain  # (re)install the build toolchain on its own — `up` already runs it once (idempotent via a marker)
devbox -p rg ssh        # connect (key-only, port 2222; no RDP)
devbox -p rg vault ...  # same vault subcommands as Linux
devbox -p rg down       # destroy the VM + NSG + disk
```

**Secrets on Windows differ from Linux at rest.** Linux materializes app `.env`s to
tmpfs (RAM); Windows has no tmpfs, so a **SYSTEM Scheduled Task** (60s poll + boot +
logon/logoff events) materializes them to the **encrypted OS disk** while you have ≥1 SSH
session and the vault is unsealed, and **wipes them at the last logout** (tracked manifest;
a pre-existing real file is never touched). There is a ≤60s window after the last logout
before the wipe fires. See `docs/devbox.spec.md` §E8.

## Machine identity — box-to-box SSH (unattended runs)

A deployed devbox is sometimes the **operator** for *another* deployment: the Linux
devbox stands up and drives the `win-test` Windows appliance (`devbox -p win-test up`,
then `/win-test` per run). For a scheduled/unattended run there is **no forwarded Mac
agent** on the box, so the box needs its **own resident SSH key** — and copying your
personal key onto a cloud box is exactly what the spec forbids.

So `configure` (and therefore every `up`) **auto-provisions a machine identity on each
Linux box**: an ed25519 keypair at `~/.ssh/id_ed25519` (`0600`), **generated on the box**,
created only if absent — an existing key is never overwritten (a missing `.pub` is
re-derived from the private half). Spec: `docs/devbox.spec.md` A6.

- **Why no passphrase:** the key exists *for* unattended use — there is no human or
  keychain in a scheduled run to unlock it. The compensating controls are scope and
  revocability, not a passphrase.
- **Scope:** the key grants access **only where its pubkey is explicitly authorized**
  (e.g. baked into the win-test appliance's `authorized_keys` at provision time). It is
  never a copy of a device key, so your personal key's blast radius is untouched.
  Linux boxes only — Windows boxes are SSH *targets*, not clients, and get none.
- **How it wires up win-test:** `targets/win-test.conf` keeps the default
  `SSH_PUBKEY_FILES="$HOME/.ssh/id_ed25519.pub"`, which is evaluated **on the machine
  running `devbox -p win-test up`** — the Linux devbox. Because the machine identity is
  auto-provisioned there, that default now works out of the box: the appliance
  authorizes the Linux box's machine key, and unattended `/win-test` runs log in with it.
- **Operator tools come with it:** `configure` also installs the **Azure CLI** on each
  Linux box (Microsoft apt repo, idempotent) — the box needs `az` both to stand up the
  appliance and per run (`az vm start`). And for appliance profiles (those with `CI_DIR`
  set), `up` writes **`~/.config/devbox/<profile>/runner.env`** — the box identity +
  tunables the `/win-test` runner reads; it's regenerated on every `up`, so a re-created
  appliance's fresh IP lands there automatically.
- **Revoke:** remove the pubkey from the target box's `authorized_keys` (or re-provision
  the target after dropping it from `SSH_PUBKEY_FILES`). **Rotate:** delete
  `~/.ssh/id_ed25519{,.pub}` on the box, re-run `devbox configure` (generates a fresh
  pair), and re-authorize targets.
- **Check before you rely on it:** `devbox -p <profile> doctor` verifies the operator
  prereqs with actionable failures — the pubkeys in `SSH_PUBKEY_FILES` exist, a
  **resident** private key is present (an ssh-agent alone only covers interactive use),
  and the profile's provider CLI is installed + logged in (`az` for Azure profiles,
  `doctl` for DigitalOcean). `up` runs the key checks itself before touching the
  provider, so a missing identity fails loudly up front instead of deep in a render.

**Still manual, by design** (interactive/one-time operator steps — `doctor` verifies
them, nothing automates them): `az login` (or `doctl auth init`; the `az` *binary* is
auto-installed on Linux boxes, the *login* is yours), setting `SUBSCRIPTION_ID`, and
editing `targets/<profile>.conf`.

## Secrets — the on-box vault

App secrets are served by an **OpenBao vault running on the devbox in production mode**,
bound to `127.0.0.1`. It's reachable **only from inside an SSH session**, so your SSH
login is the access gate. Storage is a `file` backend — the vault's data is **encrypted
at rest on disk** ("sealed") and unusable until you unseal it with your key.

The durable home for the *values* is your **laptop**: keep one plaintext file per
project under `~/.config/devbox/<profile>/secrets/` (the `SECRETS_DIR` in your config):

```
~/.config/devbox/<profile>/secrets/myapp.env     # KEY=value lines, edited in your editor
```

**File mode.** Not every secret is an env: deployment config that can't live in the
repo (a `.sql` enablement script, a `.pem` key, an `.xml` config) goes in the same
tree and rides the same pipeline. Anything that **doesn't** end in `.env` is stored
verbatim (base64 in the vault, under the reserved kv key `__file__`) and materialized
byte-for-byte on the box. The project name **keeps the extension** — that's what
distinguishes it from an env project of the same stem:

```
~/.config/devbox/<profile>/secrets/ramp-enablement.sql       # project ramp-enablement.sql
~/.config/devbox/<profile>/secrets/runegate/server.pem       # project runegate.server.pem
```

Hidden files (and anything under a hidden folder) are ignored, so `.DS_Store` never
lands in the vault. Everything else in `secrets/` is treated as a secret and pushed —
don't keep notes or READMEs in there. An `.env` may not define a variable named
`__file__` (it's the file-mode marker; `vault load` rejects it).

With many projects the flat pool gets cluttered — you can organize `secrets/` into
folders. Path separators join with dots to form the project name, so these are the
**same project** (`kash-cards.deploy.prd`, the name used with `vault load`, in
`secrets.map`, and as the vault path):

```
~/.config/devbox/<profile>/secrets/kash-cards.deploy.prd.env    # flat
~/.config/devbox/<profile>/secrets/kash-cards/deploy.prd.env    # foldered
```

Folders are laptop-side organization only — nothing on any box changes when you
reorganize. Two files that resolve to the same project name are an error (`vault load`
dies rather than letting one shadow the other), and `devbox doctor` verifies every
`secrets.map` project still resolves to exactly one local file.

Values are taken **literally** — `KEY=value` stores `value`; `KEY="value"` stores the
quotes too. `export KEY=value` is fine; comments/blanks/junk are ignored; CRLF is
tolerated.

**`devbox up` already does all of the vault setup** — it brings OpenBao up, runs
`init` on a fresh box (saving the unseal key + root token to
`~/.config/devbox/vault-keys.json` on your laptop), unseals, and loads every
secret file under `~/.config/devbox/<profile>/secrets/` (`.env` and file mode alike).
The individual commands below are only for granular control:

```sh
devbox vault up          # start + init/unseal (same readiness as `up`)
devbox vault unseal      # re-unseal after a reboot, from your saved key
devbox vault load myapp  # (re)push just one project to secret/myapp
devbox vault refresh myapp  # load myapp (or all, if omitted) + restart the
                            # session-secrets service so a live SSH session picks
                            # up the new values without a logout/login
```

After editing a `~/.config/devbox/<profile>/secrets/<proj>.env`, `devbox vault refresh <proj>` pushes
it to the vault and re-materializes the on-tmpfs `.env` in any active login session
(it restarts `devbox-secrets.service`). With no active session it just loads the
vault — the secret materializes on the next login. Omit the project name to refresh
every project, or pass a group prefix to refresh one family: `devbox vault refresh
qrypto-omni` loads every `qrypto-omni.*` project (dot boundary — `runegate` never
matches `runegate-infra`).

If the box reboots, OpenBao **auto-starts (sealed)** via its systemd unit
(`devbox-vault.service`), so the server is back up and `devbox vault unseal`
reopens it from your saved key (no re-init). If for some reason the server isn't running,
`devbox vault up` starts it and unseals in one step. (Server logs:
`~/.config/devbox/openbao.log` or `journalctl -u devbox-vault`.)

**Auto-seal TTL (optional).** Set `AUTOSEAL_TTL` (e.g. `5min`) in your profile's conf and the
vault re-seals that long after each unseal — a hard timer, reset on every `vault unseal`.
A systemd timer on the box (`devbox-vault-autoseal.timer`) does it, using a **seal-only**
token (policy `devbox-sealer`, capability `sys/seal` only — it can lock the vault but
**cannot read any secret**; root stays on your laptop). This re-locks a forgotten-unsealed
vault even after you disconnect. It does **not** wipe `.env` files already materialized to
tmpfs (those still die at logout) — it just blocks new reads/loads until you re-unseal.

Then, on the box, an app reads them:

```sh
source ~/.config/devbox/vault.env          # sets BAO_ADDR + BAO_TOKEN for this box
bao kv get -mount=secret myapp             # view
# inject into the environment (jq's @sh shell-quotes values, so spaces/specials are safe):
set -a; eval "$(bao kv get -mount=secret -format=json myapp \
  | jq -r '.data.data | to_entries[] | "\(.key)=\(.value|@sh)"')"; set +a
```

> Note: `@sh` makes *values* injection-safe, but the **key** becomes an env var name —
> so don't name a secret after a shell-sensitive variable (`PATH`, `LD_PRELOAD`,
> `BASH_ENV`, …). `vault load` only accepts `NAME=value` keys, which keeps this safe.

Tear the box down → its vault storage and keys are gone → on the next box, `vault up` +
`vault init` + `vault load` again (**re-init per box**: each box gets fresh keys).

### On-login materialization into app `.env` / config files (optional)

If your app reads a `.env` *file* (rather than env vars) — or a file-mode secret like a
`.pem`/`.sql`/`.xml` — devbox can materialize the vault secrets into those files **on SSH
login** and wipe them **when your last session ends** — keeping plaintext only in RAM
(tmpfs), never on the box's disk.

Opt in by creating a manifest at `~/.config/devbox/<profile>/secrets.map` (copy the format from
`deploy/secrets.map.example`) that maps each vault project to its destination path on the box.
It lives in that profile's external home (alongside its `secrets/` and `vault-keys.json`), so
each deployment has its own — and the dest paths are OS-specific (Linux `/home/...` vs Windows
`C:\...`). Example (`~/.config/devbox/default/secrets.map`):

```
frontend             /home/eddyg/apps/frontend/.env
backend              /home/eddyg/apps/backend/.env
ramp-enablement.sql  /home/eddyg/apps/backend/deploy/ramp-enablement.sql
```

`configure`/`up` then installs a hook + a systemd **user** service on the box. On login it
symlinks each project's secrets into its dest — KEY=value lines for an env project, the
original bytes for a file-mode one (a link into `/dev/shm` tmpfs); on the **last** logout
or dropped connection it wipes them (logind reference-counts your sessions, so a second
open session is never disturbed). The project name and the dest filename are independent,
so many apps can each use a plain `.env` (the directory disambiguates).

Caveats: the vault must be **unsealed first** (`vault unseal` from your laptop) — if it's
sealed at login the hook skips with a notice (`systemctl --user restart devbox-secrets`
after unsealing). Cleanup only removes the symlink + the RAM copy — never a real file you
placed there, nor your local `./secrets` or the vault. Plaintext still lives in RAM while
in use (inherent — see runtime exposure in the spec); this only removes the at-rest-on-disk
exposure of Case-2 file materialization.

> **"Logout" means your *last* session ends — including ones you forgot about.** Cleanup
> fires when logind stops your user manager, i.e. when **no** `eddyg` session remains. A
> **VS Code Remote-SSH** window leaves a `vscode-server` running on the box (a live
> session) even after you close the editor, so the wipe won't fire until that ends too —
> via VS Code's "Kill VS Code Server on Host" / "Close Remote Connection", its idle
> auto-shutdown, or a reboot. Same goes for a lingering `tmux`/`mosh`/backgrounded process.
> To confirm a wipe, check from *outside* a session (a root watcher) — logging in to look
> re-materializes it. (tmpfs is gone on reboot regardless.)

**Honest notes:**
- **Production mode**, single unseal key (1-of-1). The vault starts **sealed**
  (encrypted on disk); your **unseal key + root token live on your laptop**
  (`vault-keys.json`, `0600`) and the unseal key is fed in per session — the box never
  stores the unseal key.
- The box holds only a **scoped token** (policy `devbox-app`, limited to `secret/*`),
  not root — written to owner-only `0600` files (`vault.env`, `~/.bao-token`) for
  `load`/reads. Neither the unseal key nor any token is passed on the command line —
  they travel via stdin/env, so `ps` / `/proc/<pid>/cmdline` can't leak them.
- On a DigitalOcean droplet there's no swap, so `disable_mlock=true` doesn't risk
  paging secret memory to disk.
- **If `vault init` is interrupted** (SSH drops) after it initializes but before the
  keys reach your laptop, that box's vault is unrecoverable — `vault unseal` will tell
  you to tear down and re-provision. (No data lost; the durable copy is on your laptop.)
- Net: the vault is network-isolated (localhost-only) and sealed at rest — your SSH
  login is the gate. The residual is the inherent runtime exposure: any code running as
  `eddyg` while the vault is *unsealed* can read the scoped token, and a secret in use
  is plaintext in that process's memory.

## What you get (per the spec)

- Droplet `devbox` (Ubuntu 24.04, `sgp1`, `s-2vcpu-4gb`), user `eddyg` (passwordless sudo).
- SSH on **port 2222**, key-only, no root login, agent forwarding allowed.
- Firewall: **inbound tcp/2222 only**, outbound open.
- Toolchain: `git`, `gh`, Node LTS, Claude Code CLI, Azure CLI (installed by `configure` —
  the box operates Azure-hosted peer deployments like win-test; `az login` is yours).
- `claude-config/` installed into `~/.claude` via `install.sh`.

## First-session auth (interactive, no secrets at rest)

- **git** works immediately via your forwarded key.
- **Claude**: run `claude` and log in.
- **GitHub API**: `gh auth login` (git itself already works via SSH).

## Security notes & gotchas

- **Agent forwarding only after the host key is pinned.** The CLI's first contact to a
  box is **without** `-A`; it pins the host key (`accept-new`), and only then does
  `configure`/`ssh` forward your agent with strict key checking. This stops a MITM on
  first connect from harvesting your forwarded agent. Residual: the host key itself is
  trusted on first use (TOFU) — for maximum assurance, read the box's host-key
  fingerprint from the DigitalOcean console and pre-seed `known_hosts`.
- **GitHub host keys are pinned on the box.** `cloud-init` fetches GitHub's host keys
  over TLS into `/etc/ssh/ssh_known_hosts`, so the box's clone uses strict checking (no
  TOFU on GitHub). If that fetch fails at boot, the first clone fails loudly rather than
  trusting an unknown key.
- **Recovery if a box gets stuck mid-boot.** SSH is reachable only on 2222 *after*
  cloud-init applies the port change; the firewall blocks 22 the whole time. If
  cloud-init fails before that (or sshd can't bind 2222 — in which case `devbox-ready`
  is deliberately not written and `up` reports a timeout), use the **DigitalOcean web
  console** to get in.
- **Bad-VM detector (auto-recreate).** DigitalOcean occasionally hands you a droplet that
  boots "active" but is wedged at the hypervisor — no SSH, no ping, the web console won't
  even attach. That's infrastructure, not your config. `up` detects this fast: during
  provisioning it temporarily allows **ICMP from your public IP only** (auto-removed when
  done) and pings for liveness. No response within `LIVENESS_TIMEOUT` (default 240s) ⇒
  bad VM ⇒ it destroys the droplet and recreates on a fresh host (up to
  `PROVISION_ATTEMPTS`, default 2). It also catches a box that dies *mid-install*
  (`DEATH_STREAK` consecutive missed pings after being alive). Tune via your profile's conf;
  set `LIVENESS_PROBE=off` to disable (falls back to the SSH-only `READINESS_TIMEOUT`
  wait). A single dropped ping never triggers a false verdict — liveness needs only one
  success, and "died" needs a sustained streak.
- **Ubuntu 24.04 SSH socket.** 24.04 socket-activates SSH, so the listening port is
  set by `ssh.socket`, not just `sshd_config`. `cloud-init.yaml` overrides both, then
  verifies sshd is actually listening on the port before signaling ready.
- **Two operator machines.** Register both public keys in `SSH_PUBKEY_FILES` so you
  can reach the box from either. No state to sync between them.
- **`SSH_PUBKEY_FILES` paths can't contain spaces** (space/newline-separated list).
- **`down`** deletes the droplet + firewall and prunes the box from your `known_hosts`,
  but **leaves your DigitalOcean SSH keys registered** (public, free, reused — see spec
  D4 carve-out).
- **Supply chain.** `cloud-init` installs Node via the NodeSource script and `gh` /
  Claude Code from upstream over TLS — inherent to from-scratch provisioning on an
  outbound-open box. Pin versions/checksums if you want to harden this.
- **git-write-guard coverage.** The guard gates direct git writes and common wrapped
  forms, plus a conservative fallback for `sh -c`/`bash -c`/`eval`/`xargs git`. Known
  *not* covered: a git write hidden behind a shell keyword (`...; then git push`) or
  fed to `xargs` via stdin (`echo push | xargs git`). It's a safety prompt, not a
  sandbox — never the sole control.
