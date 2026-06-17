#!/usr/bin/env bash
# install.sh — put the devbox CLI on your PATH so you can run `devbox` from anywhere.
#
# Symlinks deploy/devbox into a writable directory on your PATH. The CLI resolves
# the symlink, so it still reads deploy/devbox.conf and deploy/cloud-init.yaml from
# the repo. Safe to re-run; never clobbers a non-symlink.
#
# Usage:
#   deploy/install.sh                # auto-pick a writable PATH dir (prefers ~/.local/bin)
#   deploy/install.sh ~/bin          # install into a specific directory
#   deploy/install.sh --uninstall    # remove the devbox symlink(s) we created
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TARGET="$SCRIPT_DIR/devbox"

c_ok=$'\033[1;32m'; c_info=$'\033[1;34m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_off=$'\033[0m'
info() { printf '%s==>%s %s\n' "$c_info" "$c_off" "$*"; }
ok()   { printf '%s✓%s %s\n'   "$c_ok"   "$c_off" "$*"; }
warn() { printf '%swarn:%s %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

[ -x "$TARGET" ] || die "can't find the devbox CLI at $TARGET"

on_path()  { case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac; }
CANDIDATES=("$HOME/.local/bin" "$HOME/bin" /usr/local/bin /opt/homebrew/bin)

# Prefer a directory that's already on PATH and writable; else fall back to ~/.local/bin.
pick_bindir() {
  local d
  for d in "${CANDIDATES[@]}"; do
    if on_path "$d" && [ -d "$d" ] && [ -w "$d" ]; then echo "$d"; return; fi
  done
  echo "$HOME/.local/bin"
}

uninstall() {
  local d link removed=0
  for d in "${CANDIDATES[@]}"; do
    link="$d/devbox"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$TARGET" ]; then
      rm -f "$link"; ok "removed $link"; removed=1
    fi
  done
  [ "$removed" = 1 ] || warn "no devbox symlink pointing at $TARGET found"
}

main() {
  case "${1:-}" in
    --uninstall|-u) uninstall; exit 0 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac

  local bindir=${1:-$(pick_bindir)} link
  mkdir -p "$bindir" || die "can't create $bindir"
  [ -w "$bindir" ] || die "$bindir is not writable"
  link="$bindir/devbox"

  # Only ever replace our own symlink (or nothing) — never a real file you put there.
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    die "$link exists and is not a symlink — refusing to overwrite"
  fi

  ln -sf "$TARGET" "$link"
  ok "linked $link -> $TARGET"

  if on_path "$bindir"; then
    info "ready — run: devbox help"
  else
    warn "$bindir is not on your PATH yet; add it, then restart your shell:"
    printf '    echo '\''export PATH="%s:$PATH"'\'' >> ~/.zshrc && exec zsh\n' "$bindir"
  fi
}

main "$@"
