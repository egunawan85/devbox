# azure.sh — Azure provider for the devbox CLI (Windows and Linux images). Implements the
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

# Azure CLI on a *Windows* operator can't encrypt its token cache with DPAPI and dies with
# "[WinError 5] access denied" — on `az login` AND on every later `az` call that reads the
# cache. Disabling token-cache encryption is the documented workaround. We apply it ONLY when
# the operator's own machine is Windows: a macOS/Linux operator encrypts its cache fine and
# must NOT have it downgraded (this would rewrite its tokens unencrypted). The Windows *guest*
# devbox gets the same workaround applied per-user by os/windows.sh:os_configure — that path,
# not this one, is what fixes `az login` run on the box itself.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) _az_operator_is_windows=1 ;;
  *)                    _az_operator_is_windows=0 ;;
esac
if [ "$_az_operator_is_windows" = 1 ]; then
  # In-process default for every `az` the harness runs on a Windows operator. An operator who
  # wants to keep encryption can pre-set AZURE_CORE_ENCRYPT_TOKEN_CACHE=true — ':=' preserves it.
  : "${AZURE_CORE_ENCRYPT_TOKEN_CACHE:=false}"
  export AZURE_CORE_ENCRYPT_TOKEN_CACHE
fi

# az_persist_token_cache_pref — on a Windows operator, persist the encrypt-token-cache
# preference into ~/.azure/config so it sticks across shells and covers the operator's *manual*
# `az login`, not just the harness process that inherits the env var above. `az config set`
# writes plain text and needs no auth, so it's safe before the login check in prov_ready.
# No-op on a macOS/Linux operator (nothing to work around there). Idempotent: skips the write
# when the config already matches, so `devbox up` stays quiet on the steady state.
az_persist_token_cache_pref() {
  [ "$_az_operator_is_windows" = 1 ] || return 0
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
  : "${SUBSCRIPTION_ID:?set SUBSCRIPTION_ID in the profile config (deploy/targets/$DEVBOX_PROFILE.conf)}"
  : "${RESOURCE_GROUP:?set RESOURCE_GROUP in the profile config (deploy/targets/$DEVBOX_PROFILE.conf)}"
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
  # A credential-free box is never offered the operator's agent, so the hint doesn't either.
  local fwd=-A; [ "${CREDENTIAL_FREE:-0}" = 1 ] && fwd=-a
  [ -n "$ip" ] && log "ssh: ssh $fwd -p $SSH_PORT $DEVBOX_USER@$ip"
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

# prov_provision — RG + NSG + VM (inbound tcp/$SSH_PORT only) + first boot, then return
# once the box is reachable. Sets PROVISIONED_IP. The image's OS decides how the first
# boot is delivered; everything around it is shared.
prov_provision() {
  ensure_resource_group
  ensure_nsg
  case "$OS" in
    windows) az_create_windows_vm ;;
    linux)   az_create_linux_vm ;;
    *) die "the azure provider has no VM recipe for OS='$OS'" ;;
  esac
}

# Linux: no password exists at all — the login user is created key-only from
# SSH_PUBKEY_FILES, and first boot is cloud-init, handed over as custom data. The VM is
# reachable only once cloud-init has moved sshd to $SSH_PORT (the NSG admits nothing
# else), so "ready" is the OS module's readiness probe, not the create call returning.
# OS_DISK_GB / OS_DISK_SKU are optional; unset, Azure's defaults for the image apply.
az_create_linux_vm() {
  local f keys=() disk=() ud
  for f in $SSH_PUBKEY_FILES; do
    [ -f "$f" ] || die "ssh public key not found: $f"
    keys+=("$f")
  done
  [ -n "${OS_DISK_GB:-}" ]  && disk+=(--os-disk-size-gb "$OS_DISK_GB")
  [ -n "${OS_DISK_SKU:-}" ] && disk+=(--storage-sku "$OS_DISK_SKU")
  ud=$(mktemp "${TMPDIR:-/tmp}/devbox-cloud-init.XXXXXX")
  os_render_firstboot > "$ud" || { rm -f "$ud"; die "could not render the first-boot config"; }
  log "creating VM '$DROPLET_NAME' ($SIZE, $IMAGE, $REGION) — key-only SSH, inbound tcp/$SSH_PORT only"
  if ! az vm create -g "$RESOURCE_GROUP" -n "$DROPLET_NAME" \
        --image "$IMAGE" --size "$SIZE" \
        --admin-username "$DEVBOX_USER" --authentication-type ssh --ssh-key-values "${keys[@]}" \
        --custom-data "$ud" "${disk[@]}" \
        --nsg "$FIREWALL_NAME" --nsg-rule NONE \
        --public-ip-sku Standard --tags "$TAG" -o none; then
    rm -f "$ud"; die "az vm create failed"
  fi
  rm -f "$ud"
  local ip; ip=$(prov_wait_ip) || die "VM created but no public IP appeared within ~60s"
  log "VM at $ip — waiting for cloud-init (packages, Node, sshd on $SSH_PORT)"
  wait_box_ready "$ip" \
    || die "VM '$DROPLET_NAME' ($ip) never reported ready within ${READINESS_TIMEOUT}s — check the serial log: az vm boot-diagnostics get-boot-log -g $RESOURCE_GROUP -n $DROPLET_NAME"
  PROVISIONED_IP="$ip"
}

# az_ensure_self_deallocator — let the VM turn ITSELF off, and nothing more. Two
# idempotent layers, re-ensured on every call:
#   1. a system-assigned managed identity on the VM — how the box calls ARM with no
#      credential stored on it (its watcher gets tokens from the metadata service);
#   2. the single-action custom role devbox-self-deallocator (deallocate, nothing else),
#      scoped to THIS VM only and granted to that identity — a compromised box can turn
#      itself off, and that is all.
# Shared by every appliance profile, whatever its OS; the watcher itself is the OS
# module's business.
az_ensure_self_deallocator() {
  need az
  log "ensuring managed identity + deallocate-only role on $DROPLET_NAME"
  az vm identity assign -g "$RESOURCE_GROUP" -n "$DROPLET_NAME" >/dev/null \
    || die "could not assign a system-assigned identity to $DROPLET_NAME"
  local principal vmid
  principal=$(az vm show -g "$RESOURCE_GROUP" -n "$DROPLET_NAME" --query identity.principalId -o tsv)
  vmid=$(az vm show -g "$RESOURCE_GROUP" -n "$DROPLET_NAME" --query id -o tsv)
  [ -n "$principal" ] && [ -n "$vmid" ] || die "could not read the VM's identity/id"
  if [ -z "$(az role definition list --name devbox-self-deallocator --query '[0].roleName' -o tsv)" ]; then
    az role definition create --role-definition "{
      \"Name\": \"devbox-self-deallocator\",
      \"Description\": \"May deallocate a VM. Nothing else. Used by devbox appliance self-shutdown.\",
      \"Actions\": [\"Microsoft.Compute/virtualMachines/deallocate/action\"],
      \"AssignableScopes\": [\"/subscriptions/$SUBSCRIPTION_ID\"]
    }" >/dev/null || die "could not create the devbox-self-deallocator role definition"
    log "created custom role devbox-self-deallocator (deallocate action only)"
  fi
  if [ -z "$(az role assignment list --assignee "$principal" --role devbox-self-deallocator --scope "$vmid" --query '[0].id' -o tsv 2>/dev/null)" ]; then
    # A freshly minted principal can 404 in AAD for a minute — retry, don't fail the up.
    local granted=0 i
    for i in 1 2 3 4 5; do
      if az role assignment create --assignee-object-id "$principal" --assignee-principal-type ServicePrincipal \
           --role devbox-self-deallocator --scope "$vmid" >/dev/null 2>&1; then granted=1; break; fi
      log "role assignment not accepted yet (AAD propagation) -- retry $i/5 in 15s"
      sleep 15
    done
    [ "$granted" = 1 ] || die "could not grant devbox-self-deallocator to the VM's identity"
  fi
}

# Windows: the admin password Azure requires at create is random and discarded — it is
# never used (no RDP path; SSH is key-only), so it can't be a standing credential. First
# boot is provision.ps1, run by the guest agent.
az_create_windows_vm() {
  need openssl
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
