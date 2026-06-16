#!/usr/bin/env node
// git-write-guard.js — PreToolUse hook for Bash / PowerShell tool calls.
//
// Emits an "ask" permission decision when a shell command runs a git WRITE or
// network operation, even when wrapped in git global options (-C <path>,
// -c key=val, --git-dir=, --work-tree=), an absolute path (/usr/bin/git), env
// prefixes (GIT_DIR=.git git ...), the PowerShell call operator (& git ...), or
// chained (git pull; if ($?) { git push }). Read-only git (status/log/diff/...)
// is left silent so it flows through the normal allow rule. Non-git commands are
// ignored. Prints nothing + exits 0 when no gate is needed (defers to the normal
// permission flow).
//
// One cross-OS implementation: run via `node` on Linux, Windows, and macOS.

'use strict';
const fs = require('fs');

// git subcommands that write the repo / working-tree / history or hit the network.
const WRITE_SUBS = new Set([
  'push', 'pull', 'fetch', 'clone', 'merge', 'commit', 'rebase', 'reset',
  'revert', 'checkout', 'switch', 'restore', 'add', 'rm', 'mv', 'apply', 'am',
  'cherry-pick', 'clean', 'stash',
]);

// git global options that consume a following separate argument.
const OPT_WITH_ARG = new Set([
  '-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path',
  '--config-env', '--super-prefix',
]);

// Resolve the git subcommand a single command segment runs, or null if it isn't git.
function gitSubcommand(segment) {
  let s = segment.trim();
  if (s === '') return null;
  let m;
  // strip leading env-var assignments: FOO=bar BAZ="/a b" git ...
  // (value may be quoted and contain spaces).
  while ((m = /^[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*)\s+(.*)$/.exec(s))) s = m[1].trim();
  // strip PowerShell call / dot-source operators: & git ..., &"git" ..., . git ...
  while ((m = /^&\s*(.*)$/.exec(s)) || (m = /^\.\s+(.*)$/.exec(s))) s = m[1].trim();
  // extract the executable: quoted (may contain spaces) or first bare token
  let exe = null, rest = '';
  if ((m = /^"([^"]+)"\s*(.*)$/.exec(s)) || (m = /^'([^']+)'\s*(.*)$/.exec(s))) {
    exe = m[1]; rest = m[2];
  } else if ((m = /^(\S+)\s*(.*)$/.exec(s))) {
    exe = m[1]; rest = m[2];
  }
  if (!exe) return null;
  const leaf = exe.split(/[\\/]/).pop().toLowerCase();
  if (leaf !== 'git' && leaf !== 'git.exe') return null;
  const tokens = rest.split(/\s+/).filter(Boolean);
  let i = 0;
  while (i < tokens.length) {
    const t = tokens[i];
    if (OPT_WITH_ARG.has(t)) { i += 2; continue; } // option + its separate value
    if (/^--[^=]+=/.test(t)) { i += 1; continue; } // --opt=value
    if (t.startsWith('-')) { i += 1; continue; }   // other global flags
    return t.toLowerCase();                         // first non-option = subcommand
  }
  return null;
}

function main() {
  let raw;
  try {
    raw = fs.readFileSync(0, 'utf8');
  } catch {
    process.exit(0);
  }
  if (!raw || !raw.trim()) process.exit(0);

  let cmd;
  try {
    cmd = String(JSON.parse(raw)?.tool_input?.command ?? '');
  } catch {
    process.exit(0);
  }
  if (!cmd.trim()) process.exit(0);

  const ask = (sub) => {
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'ask',
        permissionDecisionReason:
          `git '${sub}' is a write/network operation - requires your approval`,
      },
    }));
    process.exit(0);
  };

  // Split on shell operators ( && || ; | newline ) and PowerShell block /
  // subexpression delimiters ( { } ( ) ) so wrapped commands like
  // `if ($?) { git push }` or `$(git push)` still surface their git segment.
  // Over-splitting inside quoted strings is acceptable: worst case is a spurious
  // "ask", never a missed gate.
  const segments = cmd.split(/&&|\|\||[;|\n{}()]/);
  for (const seg of segments) {
    const sub = gitSubcommand(seg);
    if (sub && WRITE_SUBS.has(sub)) ask(sub);
  }

  // Wrapper fallback (defends against bypasses where git isn't the segment's leaf):
  //   sh -c 'git push' · bash -c "git push" · eval 'git push' · xargs git push
  // Precisely parsing the nested payload is fragile across quoting, so bias toward a
  // (safe) ask: if a known wrapper appears AND a `git <write-subcommand>` sequence is
  // present anywhere, gate it. False positives only cost a spurious prompt.
  const WRAPPER = /\b(?:sh|bash|zsh|dash|ksh|pwsh|powershell|eval|xargs)\b/i;
  const writeAlt = [...WRITE_SUBS].join('|');
  const GIT_WRITE = new RegExp(`\\bgit\\b[\\s\\S]{0,40}?\\b(${writeAlt})\\b`);
  if (WRAPPER.test(cmd)) {
    const m = GIT_WRITE.exec(cmd);
    if (m) ask(m[1].toLowerCase());
  }

  process.exit(0);
}

main();
