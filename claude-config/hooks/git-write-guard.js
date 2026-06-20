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
// only git write ops are add/commit/push (no wrapper, no other write op), it emits
// "allow" instead — a worktree is an isolated feature branch, so committing there can't
// touch main, and pushing it just publishes that branch for PR review (never a merge).
// A push that targets main/master still asks, as does any mixed/gated/wrapped command.
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
// .claude/worktrees/ — a worktree is on its own isolated feature branch, so add/commit
// there can't touch main, and pushing that branch only publishes it for PR review.
const WORKTREE_OK = new Set(['add', 'commit', 'push']);

// A push that names main/master as a target bypasses the merge-to-main gate, so it must
// always ask — even from inside a worktree. Matches `... main`, `... master`, `:main`,
// `HEAD:master`, and the fully-qualified refspec `HEAD:refs/heads/main`. The boundary
// before main/master is `:`, whitespace, or a `refs/heads/` prefix — deliberately NOT a
// bare `/`, so a branch like `feature/main` doesn't trip it. False positives (e.g. a
// branch literally named main-fix) only cost a spurious prompt, never a missed gate.
const PUSH_TO_MAIN = /\bpush\b[\s\S]*?(?:[:\s]|refs\/heads\/)(?:HEAD:)?(?:main|master)\b/i;

// git global options that consume a following separate argument.
const OPT_WITH_ARG = new Set([
  '-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path',
  '--config-env', '--super-prefix',
]);

// Shell wrappers whose argument payload is another command — a bypass vector when the
// payload is a git write (sh -c 'git push', eval 'git ...', xargs git ...). A wrapper
// only counts when it is itself in COMMAND POSITION (the executable of a command
// segment), never as a file argument or a word inside prose/commit text.
const WRAPPER_CMDS = new Set([
  'sh', 'bash', 'zsh', 'dash', 'ksh', 'pwsh', 'powershell', 'eval', 'xargs',
]);

// Commands that run another command supplied as their trailing arguments. They sit in
// command position themselves but the real executable (possibly a wrapper) follows them,
// so a wrapper hidden behind one must still be caught.
const EXEC_PREFIX = new Set([
  'env', 'exec', 'command', 'sudo', 'doas', 'su', 'nohup', 'nice', 'setsid',
  'stdbuf', 'time', 'timeout', 'watch', 'ssh',
]);

// Reduce a command segment to [leaf, rest]: the lowercased basename of its executable and
// the remaining argument string, after stripping leading noise (env-var assignments,
// redirections, and the PowerShell call / dot-source operators). Returns [null, ''] when
// the segment is empty. This is the segment's COMMAND POSITION — the only place a real
// executable appears.
function execHead(segment) {
  let s = segment.trim();
  if (s === '') return [null, ''];
  let m;
  // Strip every kind of leading "noise" that can precede the real executable, to a
  // fixpoint so interleavings (`FOO=bar 2>/dev/null sh ...`) fully resolve. Otherwise a
  // wrapper hidden behind a redirect (`>log sh -c 'git push'`) would read as the segment's
  // executable and slip the command-position check.
  let prev;
  do {
    prev = s;
    // env-var assignments: FOO=bar BAZ="/a b" git ... (value may be quoted, contain spaces).
    while ((m = /^[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*)\s+(.*)$/.exec(s))) s = m[1].trim();
    // redirections: >f  >>f  2>f  2>>f  <f  <<<f  &>f  2>&1  (optional fd, optional target).
    while ((m = /^\d*(?:>>|<<<|<<|>&|<&|>|<)\s*(?:"[^"]*"|'[^']*'|&?[^\s;&|<>]+)?\s+(.*)$/.exec(s))) s = m[1].trim();
    // PowerShell call / dot-source operators: & git ..., &"git" ..., . git ...
    while ((m = /^&\s*(.*)$/.exec(s)) || (m = /^\.\s+(.*)$/.exec(s))) s = m[1].trim();
  } while (s !== prev);
  // extract the executable: quoted (may contain spaces) or first bare token
  let exe = null, rest = '';
  if ((m = /^"([^"]+)"\s*(.*)$/.exec(s)) || (m = /^'([^']+)'\s*(.*)$/.exec(s))) {
    exe = m[1]; rest = m[2];
  } else if ((m = /^(\S+)\s*(.*)$/.exec(s))) {
    exe = m[1]; rest = m[2];
  }
  if (!exe) return [null, ''];
  return [exe.split(/[\\/]/).pop().toLowerCase(), rest];
}

// Strip surrounding quotes and any path prefix from a token, then lowercase it — the form
// in which a wrapper executable would appear as a bare token (e.g. "'/bin/sh'" -> "sh").
function tokenLeaf(token) {
  return token.replace(/^['"]+|['"]+$/g, '').split(/[\\/]/).pop().toLowerCase();
}

// True when a segment runs a shell/eval/xargs wrapper in command position — either as the
// segment's own executable, or behind a transparent exec-prefix (sudo/env/timeout/...),
// whose options/values we can't reliably skip, so we scan that segment's tokens for a
// wrapper. Whole-token matching means a `.sh` filename or the word "sh" mid-argument never
// trips it; only a wrapper that is itself a command does.
function segmentHasWrapper(segment) {
  const [leaf] = execHead(segment);
  if (leaf === null) return false;
  if (WRAPPER_CMDS.has(leaf)) return true;
  if (EXEC_PREFIX.has(leaf)) {
    return segment.split(/\s+/).filter(Boolean).some((t) => WRAPPER_CMDS.has(tokenLeaf(t)));
  }
  return false;
}

// Resolve the git subcommand a single command segment runs, or null if it isn't git.
function gitSubcommand(segment) {
  const [leaf, rest] = execHead(segment);
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

  // Split on shell operators ( && || ; | newline ) and PowerShell block /
  // subexpression delimiters ( { } ( ) ) and backtick command substitution so wrapped
  // commands like `if ($?) { git push }`, `$(git push)`, or `` `sh -c 'git push'` ``
  // still surface their inner segment. Over-splitting inside quoted strings is
  // acceptable: worst case is a spurious "ask", never a missed gate.
  const segments = cmd.split(/&&|\|\||[;|\n{}()`]/);

  // True when the command runs from inside a git worktree under .claude/worktrees/.
  // The session cwd is the primary signal, but a session that drives a worktree from
  // the main checkout reaches it with a `cd` inside the command instead — so also honor
  // a cd into a worktree. Trust the cd only when EVERY cd in the command targets a path
  // under .claude/worktrees/; a later `cd` that escapes back out fails closed to ask.
  const cdTargets = [];
  for (const seg of segments) {
    const m = /^\s*cd\s+(?:"([^"]*)"|'([^']*)'|(\S+))/.exec(seg.trim());
    if (m) cdTargets.push(m[1] ?? m[2] ?? m[3] ?? '');
  }
  const cdIntoWorktree = cdTargets.length > 0 &&
                         cdTargets.every((p) => /\.claude\/worktrees\//.test(p));
  const inWorktree = /\/\.claude\/worktrees\//.test(cwd) || cdIntoWorktree;

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

  const subs = [];
  for (const seg of segments) {
    const sub = gitSubcommand(seg);
    if (sub && WRITE_SUBS.has(sub)) subs.push(sub);
  }

  // Wrapper fallback (defends against bypasses where git isn't the segment's leaf):
  //   sh -c 'git push' · bash -c "git push" · eval 'git push' · xargs git push
  // The wrapper must be in COMMAND POSITION (a segment's executable, or behind a
  // transparent exec-prefix) — matching the bare word anywhere would fire on a `.sh`
  // filename or commit-message prose. Precisely parsing the nested payload is fragile
  // across quoting, so once a real wrapper is present we bias toward a (safe) ask: if a
  // `git <write-subcommand>` sequence appears anywhere, gate it. False positives only
  // cost a spurious prompt.
  const writeAlt = [...WRITE_SUBS].join('|');
  const GIT_WRITE = new RegExp(`\\bgit\\b[\\s\\S]{0,40}?\\b(${writeAlt})\\b`);
  let wrapperSub = null;
  if (segments.some(segmentHasWrapper)) {
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
  const pushesToMain = subs.includes('push') && PUSH_TO_MAIN.test(cmd);
  if (inWorktree && onlyWorktreeOps && !pushesToMain) allow(subs.join('+'));
  else ask(gated[0]);
}

main();
