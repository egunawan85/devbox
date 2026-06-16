# deploy/ — DigitalOcean devbox provisioning

Stands up a Linux **devbox** on DigitalOcean and installs the `claude-config/`
payload onto it. Tooling: `doctl` + `cloud-init` + a bash CLI — **no Terraform, no
state file** (DigitalOcean itself is the source of truth). Contract:
[../docs/devbox.spec.md](../docs/devbox.spec.md).

## Files

| File | What |
|---|---|
| `devbox` | Operator CLI: `up` / `configure` / `ssh` / `status` / `render` / `down`. |
| `cloud-init.yaml` | First-boot template: creates the user, hardens SSH, installs the toolchain. |
| `devbox.conf.example` | Config template — copy to `devbox.conf` (gitignored) and edit. |

## One-time setup

1. `doctl auth init` (or `export DIGITALOCEAN_ACCESS_TOKEN=...`).
2. `cp deploy/devbox.conf.example deploy/devbox.conf` and edit — set
   `SSH_PUBKEY_FILES` to your laptop **and** desktop public keys.
3. Make sure your private key is loaded in your SSH agent (`ssh-add -l`) — the box
   reuses it via agent forwarding for git; nothing is stored on the box.

## Usage

```sh
deploy/devbox up         # provision (if absent) + configure, end to end
deploy/devbox ssh        # connect (agent-forwarded)
deploy/devbox status     # show the droplet
deploy/devbox configure  # re-install config on the existing box (config-only path)
deploy/devbox render     # print the rendered cloud-init — no API calls (safe to inspect)
deploy/devbox vault up        # ensure the OpenBao server is running on the box
deploy/devbox vault init      # first time on a box: init + unseal, saves keys to laptop
deploy/devbox vault load myapp # push ~/devbox-secrets/myapp.env into the vault
deploy/devbox down       # destroy droplet + firewall
```

## Secrets — the on-box vault

App secrets are served by an **OpenBao vault running on the devbox in production mode**,
bound to `127.0.0.1`. It's reachable **only from inside an SSH session**, so your SSH
login is the access gate. Storage is a `file` backend — the vault's data is **encrypted
at rest on disk** ("sealed") and unusable until you unseal it with your key.

The durable home for the *values* is your **laptop**: keep one plaintext file per
project under `~/devbox-secrets/` (the `SECRETS_DIR` in your config):

```
~/devbox-secrets/myapp.env     # KEY=value lines, edited in your editor
```

Values are taken **literally** — `KEY=value` stores `value`; `KEY="value"` stores the
quotes too. `export KEY=value` is fine; comments/blanks/junk are ignored; CRLF is
tolerated.

First time on a fresh box, then per project:

```sh
deploy/devbox vault up          # start the server (it comes up SEALED)
deploy/devbox vault init        # init + unseal; saves the unseal key + root token to
                                #   ~/.config/devbox/vault-keys.json on your laptop
deploy/devbox vault load myapp  # push myapp's secrets to secret/myapp
```

If the box reboots, the vault re-seals — `deploy/devbox vault unseal` reopens it from
your saved key (no re-init).

Then, on the box, an app reads them:

```sh
source ~/.config/devbox/vault.env          # sets BAO_ADDR + BAO_TOKEN for this box
bao kv get -mount=secret myapp             # view
# inject into a process at launch:
export $(bao kv get -mount=secret -format=json myapp | jq -r '.data.data|to_entries[]|"\(.key)=\(.value)"')
```

Tear the box down → its vault storage and keys are gone → on the next box, `vault up` +
`vault init` + `vault load` again (**re-init per box**: each box gets fresh keys).

**Honest notes:**
- **Production mode**, single unseal key (1-of-1). The vault starts **sealed**
  (encrypted on disk); your **unseal key lives on your laptop** (`vault-keys.json`,
  `0600`) and is fed in per session — the box never stores the unseal key.
- The **root token** is needed for `load`/reads, so it's written to owner-only `0600`
  files on the box (`vault.env`, `~/.bao-token`). It (and the unseal key) are never
  passed on the command line — they travel via stdin/env, so `ps` / `/proc/<pid>/cmdline`
  can't leak them.
- On a DigitalOcean droplet there's no swap, so `disable_mlock=true` doesn't risk
  paging secret memory to disk.
- Net: the vault is network-isolated (localhost-only) and sealed at rest — your SSH
  login is the gate. The residual is the inherent runtime exposure: any code running as
  `eddyg` while the vault is *unsealed* can read the token, and a secret in use is
  plaintext in that process's memory.

## What you get (per the spec)

- Droplet `devbox` (Ubuntu 24.04, `sgp1`, `s-2vcpu-4gb`), user `eddyg` (passwordless sudo).
- SSH on **port 2222**, key-only, no root login, agent forwarding allowed.
- Firewall: **inbound tcp/2222 only**, outbound open.
- Toolchain: `git`, `gh`, Node LTS, Claude Code CLI.
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
