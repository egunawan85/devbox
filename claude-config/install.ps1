# install.ps1 — link the devbox claude-config payload into ~/.claude (idempotent). Windows
# mirror of install.sh.
#
# Symlinks CLAUDE.md, settings.json, hooks/git-write-guard.js, and every file under commands/
# and scripts/ from this repo's claude-config/ into ~/.claude, so a later `git pull` updates
# the live config with no reinstall. New files dropped into commands/ or scripts/ are picked
# up automatically on the next run. Never touches settings.local.json or any other ~/.claude
# content. Safe to re-run; any pre-existing real file at a target is backed up, not clobbered.
#
# Uses symbolic links: the devbox login user is the box admin, which holds the privilege to
# create them (no Developer Mode needed). Run under Windows PowerShell 5.1+ or pwsh.
#
# Override the destination (e.g. for testing):  $env:CLAUDE_HOME='X'; .\install.ps1
$ErrorActionPreference = 'Stop'

# Directory this script lives in == the payload source.
$SRC  = $PSScriptRoot
$DEST = if ($env:CLAUDE_HOME) { $env:CLAUDE_HOME } else { Join-Path $HOME '.claude' }

foreach ($d in @($DEST, (Join-Path $DEST 'hooks'), (Join-Path $DEST 'commands'), (Join-Path $DEST 'scripts'))) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
}

function Link-File([string]$src, [string]$dest) {
  $cur = Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
  if ($cur -and $cur.LinkType -eq 'SymbolicLink' -and (@($cur.Target)[0] -eq $src)) {
    Write-Host "  ok        $dest"; return
  }
  if ($cur) {
    $bak = "$dest.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Move-Item -LiteralPath $dest -Destination $bak -Force
    Write-Host "  backed up $dest -> $bak"
  }
  New-Item -ItemType SymbolicLink -Path $dest -Target $src | Out-Null
  Write-Host "  linked    $dest -> $src"
}

Write-Host "devbox: installing claude-config"
Write-Host "  from $SRC"
Write-Host "  into $DEST"
Link-File (Join-Path $SRC 'CLAUDE.md')                (Join-Path $DEST 'CLAUDE.md')
Link-File (Join-Path $SRC 'settings.json')            (Join-Path $DEST 'settings.json')
Link-File (Join-Path $SRC 'hooks\git-write-guard.js') (Join-Path $DEST 'hooks\git-write-guard.js')

# Link every file under commands/ and scripts/ (auto-discovers new files on each run).
foreach ($sub in 'commands', 'scripts') {
  $dir = Join-Path $SRC $sub
  if (Test-Path $dir) {
    Get-ChildItem -LiteralPath $dir -File | ForEach-Object {
      Link-File $_.FullName (Join-Path (Join-Path $DEST $sub) $_.Name)
    }
  }
}

if (Test-Path (Join-Path $DEST 'settings.local.json')) {
  Write-Host "  preserved $(Join-Path $DEST 'settings.local.json')"
}
Write-Host "devbox: done."
