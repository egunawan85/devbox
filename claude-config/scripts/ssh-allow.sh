#!/usr/bin/env sh
# ssh-allow.sh — manage the SSH allow list enforced by hooks/ssh-host-guard.js.
#
# The guard hook blocks every ad-hoc ssh/scp/sftp/rsync the agent composes unless the
# destination appears in this list. This script is the ONLY sanctioned way to edit it.
#
#   ssh-allow.sh list                                  show the list
#   ssh-allow.sh add eddyg@20.6.44.181 "win-test box"  permit a destination (note optional)
#   ssh-allow.sh rm  eddyg@20.6.44.181                 revoke it
#
# The agent is denied this script (permissions.deny in settings.json) and denied shell
# writes to the list file (the guard hook). That is the whole point: if the agent could
# add entries, the allow list would authorize nothing. Run it yourself — in a Claude
# session, prefix with `!` so it executes as you rather than as a tool call:
#
#   ! ~/.claude/scripts/ssh-allow.sh add eddyg@20.6.44.181
#
# Entries are exactly user@IPv4 — no hostnames, no ~/.ssh/config nicknames, no CIDR, no
# wildcards. A literal IP is the one form that cannot be quietly re-pointed somewhere
# else by a DNS record or a config file you did not read, so what you approve here is
# exactly what gets connected to.
#
# List file: ~/.config/devbox/ssh-allow (0600), override with SSH_ALLOW_FILE.
# Format: one `user@ip` per line, optional `# note`; blank lines and #-comments ignored.
set -eu

PROG=ssh-allow
LIST=${SSH_ALLOW_FILE:-$HOME/.config/devbox/ssh-allow}

die() { echo "$PROG: $*" >&2; exit 1; }

usage() {
  # Spelled with the path it was actually invoked by: ~/.claude/scripts is not on PATH
  # on a devbox, so a bare name here would be a command the reader cannot run.
  cat >&2 <<EOF
usage: $0 list
       $0 add <user@ip> [note]
       $0 rm  <user@ip>

list file: $LIST
EOF
  exit 2
}

# An octet-by-octet IPv4 check. Rejects leading zeros deliberately: inet_aton reads
# 0177.0.0.1 as octal 127.0.0.1, so two spellings of one address would be two different
# strings in the list — an ambiguity an allow list cannot afford.
valid_ip() {
  printf '%s\n' "$1" | awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/) exit 1
        if (length($i) > 1 && substr($i, 1, 1) == "0") exit 1
        if ($i + 0 > 255) exit 1
      }
      exit 0
    }'
}

# Split user@ip and validate both halves. A second @ lands in the user half, where the
# character-class check rejects it.
valid_entry() {
  _e=$1
  case $_e in *@*) ;; *) return 1 ;; esac
  _u=${_e%@*}
  _i=${_e##*@}
  case $_u in
    '' | -* ) return 1 ;;
    *[!A-Za-z0-9._-]* ) return 1 ;;
  esac
  [ "${#_u}" -le 32 ] || return 1
  valid_ip "$_i"
}

# True when $1 is already the first field of some line in the list.
has_entry() {
  [ -f "$LIST" ] || return 1
  awk -v want="$1" '$1 == want { found = 1; exit } END { exit !found }' "$LIST"
}

cmd_list() {
  if [ ! -f "$LIST" ] || [ ! -s "$LIST" ]; then
    echo "$PROG: allow list is empty ($LIST)"
    echo "       nothing may be reached by ad-hoc ssh until you add a destination."
    return 0
  fi
  cat "$LIST"
}

cmd_add() {
  [ $# -ge 1 ] || usage
  entry=$1
  note=${2:-}
  valid_entry "$entry" || die "not a valid user@ip: '$entry'
       Entries must be a username and a literal IPv4 address, e.g. eddyg@20.6.44.181
       (no hostnames, no ssh config nicknames, no ranges)."
  if has_entry "$entry"; then
    echo "$PROG: $entry is already allowed"
    return 0
  fi
  mkdir -p "$(dirname "$LIST")"
  umask 077
  if [ -n "$note" ]; then
    # Strip newlines from the note so one entry can never become two lines.
    note=$(printf '%s' "$note" | tr -d '\n\r')
    printf '%s\t# %s\n' "$entry" "$note" >> "$LIST"
  else
    printf '%s\n' "$entry" >> "$LIST"
  fi
  chmod 600 "$LIST"
  echo "$PROG: added $entry"
}

cmd_rm() {
  [ $# -ge 1 ] || usage
  entry=$1
  if ! has_entry "$entry"; then
    die "$entry is not in the allow list ($LIST)"
  fi
  tmp=$(mktemp "${LIST}.XXXXXX")
  # Write a sibling temp and rename over, so a failure mid-write can never leave a
  # truncated list (which would fail open for nothing and closed for everything).
  awk -v want="$entry" '$1 != want' "$LIST" > "$tmp"
  chmod 600 "$tmp"
  mv -- "$tmp" "$LIST"
  echo "$PROG: removed $entry"
}

[ $# -ge 1 ] || usage
sub=$1
shift
case $sub in
  list | ls)          cmd_list "$@" ;;
  add)                cmd_add "$@" ;;
  rm | remove | del)  cmd_rm "$@" ;;
  help | -h | --help) usage ;;
  *) echo "$PROG: unknown command: $sub" >&2; usage ;;
esac
