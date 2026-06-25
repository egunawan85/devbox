# azure.sh — Azure provider for the devbox CLI (the 'windows' profile). Implements the
# provider contract (prov_*) that lib/common.sh calls; sourced after common.sh when
# PROVIDER=azure. Uses the `az` CLI — Azure itself is the source of truth (no state file).
# Idempotency is keyed on the VM name (DROPLET_NAME) within a resource group.
#
# Auth is interactive (`az login` on the operator's machine); the subscription is pinned
# per-profile (SUBSCRIPTION_ID) and selected by prov_ready. Mirrors the no-Terraform,
# no-state-file design of providers/digitalocean.sh.
#
# Status: read-only ops (auth/query/status) are wired; VM/NSG create + destroy land in
# the next slice (the first `az vm create` is the billable step — gated).

# Azure CLI on some Windows profiles (Windows Server, an Azure VM, or a service-account
# profile) can't encrypt its token cache with DPAPI and dies with "[WinError 5] access
# denied" — on `az login` AND on every later `az` call that reads the cache. Disabling
# token-cache encryption is the documented workaround; tokens then sit unencrypted under
# ~/.azure, which is acceptable on an operator box that already holds these credentials.
# Export it here so every `az` the harness runs (this provider + os/windows.sh) inherits
# it. An operator whose machine encrypts the cache fine can pre-set
# AZURE_CORE_ENCRYPT_TOKEN_CACHE=true to keep encryption — the ':=' below preserves it.
: "${AZURE_CORE_ENCRYPT_TOKEN_CACHE:=false}"
export AZURE_CORE_ENCRYPT_TOKEN_CACHE

# az_persist_token_cache_pref — persist the encrypt-token-cache preference into
# ~/.azure/config so it sticks across shells and covers the operator's *manual* `az login`,
# not just the harness process that inherits the env var above (the env var alone can't fix
# a login the operator runs themselves in a fresh shell). `az config set` writes plain text
# and needs no auth, so this is safe to run before the login check in prov_ready. Idempotent:
# skips the write when the config already matches, so `devbox up` stays quiet on the steady
# state. Honors a pre-set AZURE_CORE_ENCRYPT_TOKEN_CACHE=true operator (keeps encryption).
az_persist_token_cache_pref() {
  local want=${AZURE_CORE_ENCRYPT_TOKEN_CACHE:-false}
  [ "$(az config get core.encrypt_token_cache --query value -o tsv 2>/dev/null)" = "$want" ] && return 0
  if az config set "core.encrypt_token_cache=$want" -o none 2>/dev/null; then
    log "persisted core.encrypt_token_cache=$want in ~/.azure/config (DPAPI WinError 5 workaround)"
  else
    warn "could not persist core.encrypt_token_cache=$want; falling back to the env var for harness az calls"
  fi
}

# Validate the Azure-specific config this provider needs (the core validates the rest).
az_require_conf() {
  : "${SUBSCRIPTION_ID:?set SUBSCRIPTION_ID in the windows profile config (deploy/targets/windows.conf)}"
  : "${RESOURCE_GROUP:?set RESOURCE_GROUP in the windows profile config}"
}

# prov_ready — ensure az is installed + logged in, and select the pinned subscription.
prov_ready() {
  need az
  az_require_conf
  az_persist_token_cache_pref   # write ~/.azure/config before the auth check (needs no login)
  az account show >/dev/null 2>&1 \
    || die "az is not logged in — run 'az login' (or 'az login --use-device-code'), then re-run.
       The DPAPI '[WinError 5] access denied' token-cache workaround is already persisted in
       ~/.azure/config (core.encrypt_token_cache=false), so 'az login' should now succeed."
  az account set --subscription "$SUBSCRIPTION_ID" 2>/dev/null \
    || die "could not select subscription '$SUBSCRIPTION_ID' — check 'az account list'"
}

# prov_exists — echo the VM's resource id if it exists in the resource group, else empty.
prov_exists() {
  az vm show -g "$RESOURCE_GROUP" -n "$DROPLET_NAME" --query id -o tsv 2>/dev/null || true
}

# prov_ip — echo the VM's public IPv4 (empty if none / not created yet).
prov_ip() {
  az vm list-ip-addresses -g "$RESOURCE_GROUP" -n "$DROPLET_NAME" \
    --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv 2>/dev/null || true
}

# prov_wait_ip — poll for the public IP to appear (up to ~60s). Echoes it; non-zero if absent.
prov_wait_ip() {
  local ip i=0
  while [ "$i" -lt 30 ]; do
    ip=$(prov_ip); [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
    i=$((i + 1)); sleep 2
  done
  return 1
}

# prov_status — print the VM row + an ssh hint (read-only).
prov_status() {
  az vm show -d -g "$RESOURCE_GROUP" -n "$DROPLET_NAME" \
    --query "{name:name, ip:publicIps, power:powerState, size:hardwareProfile.vmSize, region:location}" \
    -o table 2>/dev/null \
    || { log "no VM '$DROPLET_NAME' in resource group '$RESOURCE_GROUP' (subscription $SUBSCRIPTION_ID)"; return 0; }
  local ip; ip=$(prov_ip)
  [ -n "$ip" ] && log "ssh: ssh -A -p $SSH_PORT $DEVBOX_USER@$ip"
}

# ensure_resource_group — create the RG if absent (free; idempotent). Used by prov_provision
# (next slice), not at status/query time. Defined here so the create path is self-contained.
ensure_resource_group() {
  az group show -n "$RESOURCE_GROUP" >/dev/null 2>&1 && return 0
  log "creating resource group '$RESOURCE_GROUP' in $REGION"
  az group create -n "$RESOURCE_GROUP" -l "$REGION" -o none \
    || die "failed to create resource group '$RESOURCE_GROUP'"
}

# ensure_nsg — create/reconcile the network security group: inbound tcp/$SSH_PORT only, no
# RDP. Azure NSGs default-deny inbound, so this single allow rule is the whole inbound policy
# (the N1/N4 control). Idempotent.
ensure_nsg() {
  az network nsg show -g "$RESOURCE_GROUP" -n "$FIREWALL_NAME" >/dev/null 2>&1 \
    || { log "creating NSG '$FIREWALL_NAME'"; az network nsg create -g "$RESOURCE_GROUP" -n "$FIREWALL_NAME" -l "$REGION" -o none || die "failed to create NSG '$FIREWALL_NAME'"; }
  log "reconciling NSG '$FIREWALL_NAME' (inbound tcp/$SSH_PORT only, no RDP)"
  az network nsg rule create -g "$RESOURCE_GROUP" --nsg-name "$FIREWALL_NAME" \
    --name allow-ssh --priority 1000 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes '*' --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges "$SSH_PORT" -o none 2>/dev/null \
  || az network nsg rule update -g "$RESOURCE_GROUP" --nsg-name "$FIREWALL_NAME" \
    --name allow-ssh --priority 1000 --destination-port-ranges "$SSH_PORT" --access Allow -o none \
  || die "failed to set NSG allow-ssh rule"
}

# prov_provision — RG + NSG + Windows VM (no RDP rule) + first-boot provision.ps1 via the
# Custom Script Extension, then return once the box is reachable. Sets PROVISIONED_IP. The
# admin password Azure requires at create is random and discarded: it is never used (no RDP
# path; SSH is key-only), so it can't be a standing credential.
prov_provision() {
  need openssl
  ensure_resource_group
  ensure_nsg
  local pw; pw=$(openssl rand -base64 24)
  log "creating VM '$DROPLET_NAME' ($SIZE, Windows Server 2022, $REGION) — no RDP rule"
  az vm create -g "$RESOURCE_GROUP" -n "$DROPLET_NAME" \
    --image "$IMAGE" --size "$SIZE" \
    --admin-username "$DEVBOX_USER" --admin-password "$pw" \
    --nsg "$FIREWALL_NAME" --nsg-rule NONE \
    --public-ip-sku Standard --tags "$TAG" -o none \
    || die "az vm create failed"
  unset pw
  local ip; ip=$(prov_wait_ip) || die "VM created but no public IP appeared within ~60s"
  log "VM at $ip — running first-boot provision.ps1 via run-command (a few minutes)"
  # Deliver provision.ps1 to the guest agent as script DATA (not a command line). This
  # avoids the Windows command-line length limit the CustomScript EncodedCommand path hits
  # for non-trivial scripts ("The command line is too long"). Runs as SYSTEM; @file keeps
  # the script off the local arg list too.
  local script; script=$(mktemp "${TMPDIR:-/tmp}/devbox-provision.XXXXXX")
  os_render_firstboot > "$script"
  if ! az vm run-command invoke -g "$RESOURCE_GROUP" -n "$DROPLET_NAME" \
        --command-id RunPowerShellScript --scripts "@$script" -o none; then
    rm -f "$script"; die "provision.ps1 (run-command) failed — check boot diagnostics / C:\\devbox-provision.log on the box"
  fi
  rm -f "$script"
  PROVISIONED_IP="$ip"
}

# prov_destroy — delete the whole resource group (VM, NSG, public IP, disk, NIC — no orphaned
# billable resources) and prune the box from known_hosts. $1 = ip (optional).
prov_destroy() {
  local ip=${1:-}
  log "deleting resource group '$RESOURCE_GROUP' (VM + NSG + IP + disk + NIC)"
  az group delete -n "$RESOURCE_GROUP" --yes -o none || warn "resource group '$RESOURCE_GROUP' delete failed or already gone"
  if [ -n "$ip" ]; then
    ssh-keygen -R "[$ip]:$SSH_PORT" >/dev/null 2>&1 || true
    ssh-keygen -R "$ip"             >/dev/null 2>&1 || true
  fi
  log "done. (Azure resource-group teardown leaves nothing billable.)"
}
