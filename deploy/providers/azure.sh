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

# Validate the Azure-specific config this provider needs (the core validates the rest).
az_require_conf() {
  : "${SUBSCRIPTION_ID:?set SUBSCRIPTION_ID in the windows profile config (deploy/targets/windows.conf)}"
  : "${RESOURCE_GROUP:?set RESOURCE_GROUP in the windows profile config}"
}

# prov_ready — ensure az is installed + logged in, and select the pinned subscription.
prov_ready() {
  need az
  az_require_conf
  az account show >/dev/null 2>&1 \
    || die "az is not logged in — run 'az login' (or 'az login --use-device-code'), then retry"
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

# prov_provision — create the NSG (inbound SSH only, no RDP) + Windows VM, run provision.ps1
# via Custom Script Extension, wait for ready. The first `az vm create` is billable, so this
# is intentionally not implemented until the next slice (and behind your explicit go-ahead).
prov_provision() {
  die "azure prov_provision: VM bring-up is the next slice (#6) — and the first 'az vm create' is the billable step, gated on your go-ahead. Config + auth + read-only ops are wired; run 'devbox -p windows status' to exercise them."
}

# prov_destroy — tear down the box. Will delete the whole resource group (no orphaned
# billable resources) + prune known_hosts. Implemented alongside prov_provision (#6).
prov_destroy() {
  die "azure prov_destroy: not implemented yet (#6) — will delete resource group '$RESOURCE_GROUP' and prune known_hosts."
}
