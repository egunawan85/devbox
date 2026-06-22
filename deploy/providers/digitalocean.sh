# digitalocean.sh — DigitalOcean provider for the devbox CLI (the default 'linux' profile).
# Implements the provider contract (prov_*) that lib/common.sh calls; sourced after
# common.sh when PROVIDER=digitalocean. Uses doctl — DigitalOcean itself is the source of
# truth (no state file). Idempotency is keyed on the droplet NAME.

doctl_ready() {
  need doctl
  doctl account get >/dev/null 2>&1 || die \
    "doctl is not authenticated — run 'doctl auth init' or set DIGITALOCEAN_ACCESS_TOKEN"
}

# ---- DigitalOcean helpers (idempotent: DO is the state) --------------------

# Existence is keyed on NAME, not IP — a droplet can exist before its IP is
# assigned, and keying on IP would let `up` create a duplicate (H1).
droplet_id() {
  doctl compute droplet list --format ID,Name --no-header \
    | awk -v n="$DROPLET_NAME" '$2==n {print $1; exit}'
}

droplet_ip() {
  doctl compute droplet list --format Name,PublicIPv4 --no-header \
    | awk -v n="$DROPLET_NAME" '$1==n {print $2; exit}'
}

# `droplet create --wait` returns when the droplet is active, but its PublicIPv4 can
# take a few more seconds to appear in the list API — so a single droplet_ip read
# right after create intermittently comes back empty. Poll (up to ~60s) instead of
# dying on the first empty read. Echoes the IP; non-zero if it never appeared.
wait_for_ip() {
  local ip i=0
  while [ "$i" -lt 30 ]; do
    ip=$(droplet_ip); [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
    i=$((i + 1)); sleep 2
  done
  return 1
}

# Delete the droplet (by name), wait for it to actually disappear, and prune it from
# known_hosts (M5). Leaves the firewall/tag/ssh-keys intact — used both by `down` and by
# the bad-VM retry, which recreates onto the same firewall. $1 = IP to prune (optional).
delete_droplet() {
  local ip=${1:-} i=0
  log "deleting droplet '$DROPLET_NAME'"
  doctl compute droplet delete "$DROPLET_NAME" --force >/dev/null 2>&1 || true
  while [ "$i" -lt 30 ] && [ -n "$(droplet_id)" ]; do i=$((i + 1)); sleep 3; done
  if [ -n "$ip" ]; then
    ssh-keygen -R "[$ip]:$SSH_PORT" >/dev/null 2>&1 || true
    ssh-keygen -R "$ip"             >/dev/null 2>&1 || true
  fi
}

ensure_ssh_keys() { # echoes a comma-joined list of DO ssh-key IDs for our pubkeys
  local ids="" f fp existing name id
  for f in $SSH_PUBKEY_FILES; do
    [ -f "$f" ] || die "ssh public key not found: $f"
    fp=$(ssh-keygen -E md5 -lf "$f" | awk '{print $2}' | sed 's/^MD5://')
    existing=$(doctl compute ssh-key list --format ID,FingerPrint --no-header \
      | awk -v fp="$fp" '$2==fp {print $1; exit}')
    if [ -n "$existing" ]; then
      id=$existing
    else
      name="devbox-$(basename "$f" .pub)"
      log "importing ssh key '$name' into DigitalOcean"
      id=$(doctl compute ssh-key import "$name" --public-key-file "$f" \
        --format ID --no-header)
    fi
    ids="${ids:+$ids,}$id"
  done
  printf '%s' "$ids"
}

# DO's firewall API requires any tag referenced in --tag-names to ALREADY exist
# (unlike droplet create, which auto-creates tags). The firewall is created before
# the first droplet, so we must create the tag up-front. Idempotent.
ensure_tag() {
  doctl compute tag get "$TAG" >/dev/null 2>&1 && return 0
  log "creating tag '$TAG'"
  doctl compute tag create "$TAG" >/dev/null \
    || die "failed to create tag '$TAG'"
}

# The firewall is the ONLY control enforcing "inbound 2222 only" (N1), so we never
# trust a name match blindly — we reconcile it to spec every run (H2). DO's firewall
# update/create both take the full desired state, so we just (re)assert it.
ensure_firewall() {
  local id inbound outbound
  inbound="protocol:tcp,ports:$SSH_PORT,address:0.0.0.0/0,address:::/0"
  outbound="protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 protocol:udp,ports:all,address:0.0.0.0/0,address:::/0 protocol:icmp,address:0.0.0.0/0,address:::/0"
  id=$(doctl compute firewall list --format ID,Name --no-header \
    | awk -v n="$FIREWALL_NAME" '$2==n {print $1; exit}')
  if [ -n "$id" ]; then
    log "reconciling firewall '$FIREWALL_NAME' to spec (inbound tcp/$SSH_PORT only, tag '$TAG', outbound open)"
    doctl compute firewall update "$id" \
      --name "$FIREWALL_NAME" --tag-names "$TAG" \
      --inbound-rules "$inbound" --outbound-rules "$outbound" \
      --format ID --no-header >/dev/null \
      || die "failed to reconcile firewall '$FIREWALL_NAME' — refusing to proceed (N1 control unverified)"
  else
    log "creating firewall '$FIREWALL_NAME' (inbound tcp/$SSH_PORT only, outbound open)"
    doctl compute firewall create \
      --name "$FIREWALL_NAME" --tag-names "$TAG" \
      --inbound-rules "$inbound" --outbound-rules "$outbound" \
      --format ID --no-header >/dev/null
  fi
}

# ---- bad-VM liveness probe ------------------------------------------------
# A wedged DigitalOcean host boots "active" but never services the network (no SSH, no
# ICMP, console won't even attach). The firewall is normally tcp/$SSH_PORT-only, and that
# port opens only late in cloud-init — so without an out-of-band signal we can't tell
# "slow install" from "dead box" for ~20 min. ICMP from the operator's IP gives that
# signal in minutes; we add the rule only for the probe window and revoke it after.

operator_ip() { # echo the operator's public IPv4 (cached); empty if undiscoverable
  if [ -z "${OPERATOR_IP+x}" ]; then
    OPERATOR_IP=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null \
      || curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)
  fi
  printf '%s' "$OPERATOR_IP"
}

ping_alive() { # 0 if host answers one ICMP echo within ~2s (portable mac/linux)
  case "$(uname)" in
    Darwin) ping -c1 -t2 "$1" >/dev/null 2>&1 ;;
    *)      ping -c1 -W2 "$1" >/dev/null 2>&1 ;;
  esac
}

# Add ('on') or remove ('off') a scoped ICMP inbound rule from the operator's IP, so the
# liveness probe can ping. No-op (returns 0) if the IP can't be found or the firewall is
# absent — the probe then simply degrades to SSH-only detection.
firewall_set_icmp() {
  local mode=$1 fw opip
  opip=$(operator_ip); [ -n "$opip" ] || return 0
  fw=$(doctl compute firewall list --format ID,Name --no-header \
    | awk -v n="$FIREWALL_NAME" '$2==n {print $1; exit}')
  [ -n "$fw" ] || return 0
  if [ "$mode" = on ]; then
    doctl compute firewall add-rules    "$fw" --inbound-rules "protocol:icmp,address:$opip/32" >/dev/null 2>&1 || true
  else
    doctl compute firewall remove-rules "$fw" --inbound-rules "protocol:icmp,address:$opip/32" >/dev/null 2>&1 || true
  fi
}

# Wait for a box, distinguishing a healthy-but-installing box from a wedged bad VM.
#   $2 = "on" to use the ICMP liveness probe (caller must have allowed ICMP first).
# Returns: 0 ready | 1 readiness timeout (alive but cloud-init never finished) | 2 bad VM.
wait_for_box() {
  local ip=$1 probe=${2:-off}
  local t0=$SECONDS first_alive=0 fails=0 elapsed
  if [ "$probe" = on ]; then
    log "waiting for $ip:$SSH_PORT — liveness <= ${LIVENESS_TIMEOUT}s, then cloud-init <= ${READINESS_TIMEOUT}s"
  else
    log "waiting for SSH on $ip:$SSH_PORT and cloud-init to finish (a few minutes)"
  fi
  while :; do
    elapsed=$(( SECONDS - t0 ))
    if os_box_ready "$ip"; then log "box is ready"; return 0; fi
    if [ "$probe" = on ]; then
      if ping_alive "$ip"; then first_alive=1; fails=0; else fails=$((fails + 1)); fi
      # Never came alive within the liveness window => wedged at the hypervisor (bad VM).
      if [ "$first_alive" -eq 0 ] && [ "$elapsed" -ge "$LIVENESS_TIMEOUT" ]; then
        warn "no liveness from $ip after ${LIVENESS_TIMEOUT}s (no ICMP, no SSH) while DO reports 'active' — almost certainly a BAD DigitalOcean VM, not your config"
        return 2
      fi
      # Was alive, then went dark for DEATH_STREAK probes => died mid-install (OOM/host).
      if [ "$first_alive" -eq 1 ] && [ "$fails" -ge "$DEATH_STREAK" ]; then
        warn "$ip stopped responding for ~$((DEATH_STREAK * PROBE_INTERVAL))s after being alive — likely died mid-install (OOM/host failure)"
        return 2
      fi
    fi
    if [ "$elapsed" -ge "$READINESS_TIMEOUT" ]; then
      # No probe and nothing ever responded: can't prove bad-VM, but it never came up.
      [ "$probe" = on ] && [ "$first_alive" -eq 0 ] && return 2
      warn "timed out after ${READINESS_TIMEOUT}s waiting on $ip — reachable but cloud-init never wrote devbox-ready; check /var/log/cloud-init-output.log via '$(basename "$0") ssh'"
      return 1
    fi
    sleep "$PROBE_INTERVAL"
  done
}

provision_droplet() {
  local key_ids; key_ids=$(ensure_ssh_keys)
  [ -n "$key_ids" ] || die "no ssh keys resolved"
  ensure_tag        # firewall's --tag-names requires the tag to pre-exist
  ensure_firewall
  local probe=off
  if [ "$LIVENESS_PROBE" = on ] && [ -n "$(operator_ip)" ]; then
    probe=on
    log "enabling temporary ICMP liveness probe from $(operator_ip) (auto-removed when done)"
    firewall_set_icmp on
    trap 'firewall_set_icmp off' EXIT   # ensure the ICMP rule is revoked even on error
  fi
  local attempt=1 rc ip ud
  while [ "$attempt" -le "$PROVISION_ATTEMPTS" ]; do
    [ "$PROVISION_ATTEMPTS" -gt 1 ] && log "provisioning attempt $attempt/$PROVISION_ATTEMPTS"
    ud=$(mktemp); render_cloud_init >"$ud"
    log "creating droplet '$DROPLET_NAME' ($SIZE, $IMAGE, $REGION)"
    doctl compute droplet create "$DROPLET_NAME" \
      --region "$REGION" --size "$SIZE" --image "$IMAGE" \
      --ssh-keys "$key_ids" --tag-names "$TAG" \
      --user-data-file "$ud" --wait \
      --format ID,PublicIPv4 --no-header >/dev/null
    rm -f "$ud"
    if ip=$(wait_for_ip); then
      log "droplet at $ip"
      wait_for_box "$ip" "$probe"; rc=$?
    else
      warn "droplet created but no public IP after ~60s"; rc=2
    fi
    if [ "$rc" -eq 0 ]; then PROVISIONED_IP="$ip"; return 0; fi
    if [ "$rc" -eq 2 ] && [ "$attempt" -lt "$PROVISION_ATTEMPTS" ]; then
      warn "attempt $attempt failed (bad VM) — destroying and recreating on a fresh host"
      delete_droplet "${ip:-}"
      attempt=$((attempt + 1)); continue
    fi
    [ "$rc" -eq 2 ] && die "provisioning failed after $attempt attempt(s): kept landing on wedged DigitalOcean hosts. Try again shortly, or a different REGION/SIZE (raise PROVISION_ATTEMPTS to retry more)."
    die "provisioning: $ip is reachable but cloud-init never finished within ${READINESS_TIMEOUT}s — '$(basename "$0") ssh' and check /var/log/cloud-init-output.log"
  done
  die "provisioning failed after $PROVISION_ATTEMPTS attempt(s)"
}

# ---- provider contract (called by lib/common.sh) ---------------------------
prov_ready()    { doctl_ready; }
prov_exists()   { droplet_id; }          # echoes the droplet id if it exists, else empty
prov_ip()       { droplet_ip; }
prov_wait_ip()  { wait_for_ip; }
prov_provision(){ provision_droplet; }   # sets PROVISIONED_IP; auto-recreates on a bad VM

# Tear down the provider resources for this box: droplet (+ known_hosts prune, via
# delete_droplet) and the firewall. $1 = ip (may be empty). Reused DO SSH keys are left
# registered by design (spec D4 carve-out).
prov_destroy() {
  local ip=${1:-}
  [ -n "$ip" ] && delete_droplet "$ip"
  local fw_id
  fw_id=$(doctl compute firewall list --format ID,Name --no-header \
    | awk -v n="$FIREWALL_NAME" '$2==n {print $1; exit}')
  if [ -n "$fw_id" ]; then
    log "deleting firewall '$FIREWALL_NAME'"
    doctl compute firewall delete "$fw_id" --force
  fi
  log "done. (Reused DigitalOcean SSH keys are left registered by design.)"
}

# Print a human-readable status line for the box (the droplet row + an ssh hint).
prov_status() {
  doctl compute droplet list --format ID,Name,PublicIPv4,Region,Status,Tags --no-header \
    | awk -v n="$DROPLET_NAME" 'NR==1||$2==n'
  local ip; ip=$(droplet_ip)
  [ -n "$ip" ] && log "ssh: ssh -A -p $SSH_PORT $DEVBOX_USER@$ip" || log "no droplet named '$DROPLET_NAME'"
}
