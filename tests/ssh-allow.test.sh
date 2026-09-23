#!/usr/bin/env sh
# Regression suite for claude-config/scripts/ssh-allow.sh.
#
# Covers the two things the allow list depends on: that a malformed or ambiguous entry
# can never enter it, and that add/rm are exact and idempotent. Runs against a throwaway
# list under ./tmp/ — never the real ~/.config/devbox/ssh-allow.
#
# Run: sh tests/ssh-allow.test.sh   (no dependencies, no network)
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$HERE")
SSH_ALLOW="$ROOT/claude-config/scripts/ssh-allow.sh"

mkdir -p "$ROOT/tmp"
SSH_ALLOW_FILE="$ROOT/tmp/test-manager-list"
export SSH_ALLOW_FILE
rm -f "$SSH_ALLOW_FILE"

pass=0
fail=0

# ok <label> <expected-exit> <args...>
ok() {
  label=$1; want=$2; shift 2
  out=$(sh "$SSH_ALLOW" "$@" 2>&1); got=$?
  if [ "$got" -eq "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  FAIL  $label"
    echo "        want exit $want, got $got"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

check() { # check <label> <condition-result>
  if [ "$2" -eq 0 ]; then pass=$((pass + 1))
  else echo "  FAIL  $1"; fail=$((fail + 1)); fi
}

listed() { [ -f "$SSH_ALLOW_FILE" ] && grep -q "^$1" "$SSH_ALLOW_FILE"; }

echo "ssh-allow:"

ok "add a valid entry"            0 add eddyg@20.6.44.181 "win-test box"
listed "eddyg@20.6.44.181"; check "entry is in the file after add" $?

ok "add is idempotent"            0 add eddyg@20.6.44.181
[ "$(grep -c "^eddyg@20.6.44.181" "$SSH_ALLOW_FILE")" = "1" ]
check "add did not duplicate the entry" $?

ok "add a second entry"           0 add eddyg@10.0.0.5
ok "list"                         0 list

# Every rejection below is a form that must never reach the list: a name the DNS could
# re-point, a spelling that resolves to a different address than it reads as, or a
# pattern that would widen the list beyond one host.
ok "reject a hostname"            1 add eddyg@example.com
ok "reject a bare ip"             1 add 20.6.44.181
ok "reject an octal octet"        1 add eddyg@020.6.44.181
ok "reject an out-of-range octet" 1 add eddyg@20.6.44.999
ok "reject three octets"          1 add eddyg@20.6.44
ok "reject a CIDR range"          1 add eddyg@20.6.44.0/24
ok "reject a wildcard user"       1 add '*@20.6.44.181'
ok "reject an empty user"         1 add @20.6.44.181
ok "reject a double @"            1 add a@b@20.6.44.181
ok "reject a shell metachar"      1 add 'eddyg;rm -rf @20.6.44.181'
ok "reject an IPv6 address"       1 add 'eddyg@::1'
ok "reject a decimal-form ip"     1 add eddyg@3232235781

[ "$(grep -c . "$SSH_ALLOW_FILE")" = "2" ]
check "no rejected entry reached the file" $?

ok "rm an existing entry"         0 rm eddyg@10.0.0.5
listed "eddyg@10.0.0.5"; [ $? -ne 0 ]
check "entry is gone after rm" $?
ok "rm a missing entry"           1 rm eddyg@10.0.0.5
listed "eddyg@20.6.44.181"; check "rm left the other entry alone" $?

ok "no subcommand"                2 ''
ok "unknown subcommand"           2 frobnicate

perms=$(ls -l "$SSH_ALLOW_FILE" | cut -c1-10)
[ "$perms" = "-rw-------" ]
check "list file is 0600 (is $perms)" $?

echo "ssh-allow: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
