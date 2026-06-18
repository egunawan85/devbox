#!/usr/bin/env sh
# install.sh — link the devbox claude-config payload into ~/.claude (idempotent).
#
# Symlinks CLAUDE.md, settings.json, hooks/git-write-guard.js, and every file under
# commands/ from this repo's claude-config/ into ~/.claude, so a later `git pull`
# updates the live config with no reinstall. New files dropped into commands/ are
# picked up automatically on the next run.
# Never touches settings.local.json or any other ~/.claude content.
# Safe to re-run; any pre-existing real file at a target is backed up, not clobbered.
#
# Override the destination (e.g. for testing):  CLAUDE_HOME=/tmp/x ./install.sh
set -eu

# Directory this script lives in == the payload source.
SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEST=${CLAUDE_HOME:-$HOME/.claude}

mkdir -p "$DEST" "$DEST/hooks" "$DEST/commands"

link() { # $1 = source file, $2 = destination path
  src=$1
  dest=$2
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    printf '  ok        %s\n' "$dest"
    return
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    bak="$dest.bak.$(date +%Y%m%d%H%M%S)"
    mv -- "$dest" "$bak"
    printf '  backed up %s -> %s\n' "$dest" "$bak"
  fi
  ln -s -- "$src" "$dest"
  printf '  linked    %s -> %s\n' "$dest" "$src"
}

echo "devbox: installing claude-config"
echo "  from $SRC"
echo "  into $DEST"
link "$SRC/CLAUDE.md"                "$DEST/CLAUDE.md"
link "$SRC/settings.json"            "$DEST/settings.json"
link "$SRC/hooks/git-write-guard.js" "$DEST/hooks/git-write-guard.js"

# Link every file under commands/ (auto-discovers new command files on each run).
for cmd in "$SRC"/commands/*; do
  [ -e "$cmd" ] || continue   # no glob match -> skip the literal pattern
  link "$cmd" "$DEST/commands/$(basename -- "$cmd")"
done

if [ -e "$DEST/settings.local.json" ]; then
  echo "  preserved $DEST/settings.local.json"
fi
echo "devbox: done."
