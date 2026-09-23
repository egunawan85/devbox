#!/usr/bin/env sh
# install.sh — link the devbox claude-config payload into ~/.claude (idempotent).
#
# Symlinks CLAUDE.md, settings.json, and every file under hooks/, commands/ and
# scripts/ from this repo's claude-config/ into ~/.claude, so a later `git pull`
# updates the live config with no reinstall. New files dropped into hooks/, commands/
# or scripts/ are picked up automatically on the next run.
# Never touches settings.local.json or any other ~/.claude content.
# Safe to re-run; any pre-existing real file at a target is backed up, not clobbered.
#
# Override the destination (e.g. for testing):  CLAUDE_HOME=/tmp/x ./install.sh
set -eu

# Directory this script lives in == the payload source.
SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEST=${CLAUDE_HOME:-$HOME/.claude}

mkdir -p "$DEST" "$DEST/hooks" "$DEST/commands" "$DEST/scripts"

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
link "$SRC/CLAUDE.md"     "$DEST/CLAUDE.md"
link "$SRC/settings.json" "$DEST/settings.json"

# Link every file under hooks/ (auto-discovers new hooks on each run). Globbed rather
# than named one by one: a hook that settings.json references but the installer never
# linked is a guard that silently does not run.
for hk in "$SRC"/hooks/*; do
  [ -e "$hk" ] || continue
  link "$hk" "$DEST/hooks/$(basename -- "$hk")"
done

# Link every file under commands/ (auto-discovers new command files on each run).
for cmd in "$SRC"/commands/*; do
  [ -e "$cmd" ] || continue   # no glob match -> skip the literal pattern
  link "$cmd" "$DEST/commands/$(basename -- "$cmd")"
done

# Link every file under scripts/ (helper scripts the commands shell out to).
for scr in "$SRC"/scripts/*; do
  [ -e "$scr" ] || continue
  link "$scr" "$DEST/scripts/$(basename -- "$scr")"
done

if [ -e "$DEST/settings.local.json" ]; then
  echo "  preserved $DEST/settings.local.json"
fi
echo "devbox: done."
