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
  need openssl; need iconv; need base64
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
  log "VM at $ip — running first-boot provision.ps1 via Custom Script Extension (a few minutes)"
  # provision.ps1 -> EncodedCommand (PowerShell wants base64 of UTF-16LE). Runs as SYSTEM.
  # az vm extension set blocks until the CSE finishes, so on return the box is provisioned.
  local enc; enc=$(os_render_firstboot | iconv -t UTF-16LE | base64 | tr -d '\n')
  az vm extension set -g "$RESOURCE_GROUP" --vm-name "$DROPLET_NAME" \
    --name CustomScriptExtension --publisher Microsoft.Compute --version 1.10 \
    --protected-settings "{\"commandToExecute\":\"powershell -ExecutionPolicy Bypass -EncodedCommand $enc\"}" \
    -o none || die "Custom Script Extension (provision.ps1) failed — check boot diagnostics / C:\\devbox-provision.log on the box"
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
