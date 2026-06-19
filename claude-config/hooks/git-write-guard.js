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
// Exception: when cwd is inside a worktree under .claude/worktrees/ AND the command's
// only git write ops are add/commit (no wrapper, no other write op), it emits "allow"
// instead — a worktree is an isolated local branch, so committing there can't touch
// main or reach the remote. Any mixed/gated/wrapped command still asks.
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

// Write subcommands that are pre-approved when cwd is inside a git worktree under
// .claude/worktrees/ — a worktree is on its own isolated branch, so add/commit
// there can't touch main and can't reach the remote.
const WORKTREE_OK = new Set(['add', 'commit']);

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

  let cmd, cwd;
  try {
    // PreToolUse hook input is a JSON object with a top-level `cwd` field and the
    // tool args under `tool_input`. Fall back to process.cwd() if `cwd` is absent.
    const parsed = JSON.parse(raw);
    cmd = String(parsed?.tool_input?.command ?? '');
    cwd = String(parsed?.cwd ?? process.cwd() ?? '');
  } catch {
    process.exit(0);
  }
  if (!cmd.trim()) process.exit(0);

  // True when the command runs from inside a git worktree under .claude/worktrees/.
  const inWorktree = /\/\.claude\/worktrees\//.test(cwd);

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

  const allow = (label) => {
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'allow',
        permissionDecisionReason:
          `git ${label} inside a worktree is pre-approved (local, isolated branch)`,
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
  const subs = [];
  for (const seg of segments) {
    const sub = gitSubcommand(seg);
    if (sub && WRITE_SUBS.has(sub)) subs.push(sub);
  }

  // Wrapper fallback (defends against bypasses where git isn't the segment's leaf):
  //   sh -c 'git push' · bash -c "git push" · eval 'git push' · xargs git push
  // Precisely parsing the nested payload is fragile across quoting, so bias toward a
  // (safe) ask: if a known wrapper appears AND a `git <write-subcommand>` sequence is
  // present anywhere, gate it. False positives only cost a spurious prompt.
  const WRAPPER = /\b(?:sh|bash|zsh|dash|ksh|pwsh|powershell|eval|xargs)\b/i;
  const writeAlt = [...WRITE_SUBS].join('|');
  const GIT_WRITE = new RegExp(`\\bgit\\b[\\s\\S]{0,40}?\\b(${writeAlt})\\b`);
  let wrapperSub = null;
  if (WRAPPER.test(cmd)) {
    const m = GIT_WRITE.exec(cmd);
    if (m) wrapperSub = m[1].toLowerCase();
  }

  // Collect, then decide. A command that mixes a safe op with a gated one (e.g.
  // `git add . && git push`) or hides intent behind a wrapper must still ask —
  // we only auto-allow when EVERY detected write op is add/commit and no wrapper
  // is involved.
  const gated = [...subs, ...(wrapperSub ? [wrapperSub] : [])];
  if (gated.length === 0) process.exit(0);            // no git write -> defer

  // Auto-allow ONLY if: in a worktree, no wrapper obscuring intent, and every
  // detected write op is add/commit. Otherwise fail closed to "ask".
  const onlyWorktreeOps = !wrapperSub && subs.length > 0 &&
                          subs.every((s) => WORKTREE_OK.has(s));
  if (inWorktree && onlyWorktreeOps) allow(subs.join('+'));
  else ask(gated[0]);
}

main();
