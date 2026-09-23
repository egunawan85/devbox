#!/usr/bin/env node
// ssh-host-guard.js — PreToolUse hook for Bash / PowerShell tool calls.
//
// Denies every ad-hoc SSH-transport connection the agent composes: ssh, scp, sftp,
// rsync-to-a-remote, ssh-copy-id. There is no allow list and no prompt — SSH is simply
// not a thing the agent does on its own.
//
// Why deny rather than ask: an SSH connection from a devbox authenticates with either
// the operator's forwarded agent or the box's own passphrase-less machine key
// (spec A4/A6). Both are credentials the agent should never be spending on a
// destination it picked itself, and a prompt is a poor guard against that — it fires
// identically for the routine case and the dangerous one, and it is the agent that
// chose the destination. Reaching INTO a deployed VM goes through the cloud control
// plane instead (`az vm run-command invoke`), which spends a scoped, revocable,
// audit-logged API token rather than an SSH key.
//
// What this does NOT cover, deliberately: SSH performed INSIDE a script — `devbox ssh`,
// `/win-test`, the vault subcommands. A hook sees the command line, not what a script
// does once it runs. Those paths resolve their host from trusted state and are
// unaffected; they remain the sanctioned way to reach a box.
//
// It also denies shell WRITES to the files that define these rules (settings.json,
// hooks/) — an agent that can edit its own guardrails has none. Reading them is fine.
//
// permissions.deny in settings.json carries `Bash(ssh:*)`, which covers a command that
// literally begins with `ssh`. This hook covers what that prefix cannot see: scp, sftp,
// rsync to a remote, an ssh behind `sudo`/`timeout`/`nohup`, and an ssh wrapped in
// `sh -c`. The two together are the boundary.
//
// Fails SAFE if the hook itself breaks: a crash is a non-blocking error in Claude Code,
// so the call falls through to the normal permission flow rather than running unguarded
// — and for a bare `ssh …` the settings deny still stands on its own.
//
// One cross-OS implementation: run via `node` on Linux, Windows, and macOS. The shell
// parsing helpers are duplicated from git-write-guard.js rather than shared — each hook
// is symlinked into ~/.claude/hooks as a standalone file, with no module resolution
// between them.

'use strict';
const fs = require('fs');

// Commands that open an SSH-transport connection. All of them reach the same hosts with
// the same credentials, so guarding `ssh` alone would leave the side door open.
const SSH_CMDS = new Set(['ssh', 'scp', 'sftp', 'rsync', 'ssh-copy-id']);

// ssh-family options that consume a following separate argument. Needed only to tell an
// option's VALUE from a positional destination (`ssh -p 2222 host` — 2222 is not a host).
const OPT_WITH_ARG = new Set([
  '-b', '-c', '-D', '-E', '-e', '-F', '-I', '-i', '-J', '-L', '-l', '-m', '-O',
  '-o', '-P', '-p', '-Q', '-R', '-S', '-W', '-w', '-B', '--rsh', '--port',
]);

// Shell wrappers whose argument payload is another command — a bypass vector when the
// payload is an ssh (sh -c 'ssh host'). A wrapper only counts in COMMAND POSITION (the
// executable of a command segment), never as a file argument.
const WRAPPER_CMDS = new Set([
  'sh', 'bash', 'zsh', 'dash', 'ksh', 'pwsh', 'powershell', 'eval', 'xargs',
]);

// Commands that run another command supplied as their trailing arguments. The real
// executable follows them, so an ssh behind one must still be found.
const EXEC_PREFIX = new Set([
  'env', 'exec', 'command', 'sudo', 'doas', 'su', 'nohup', 'nice', 'setsid',
  'stdbuf', 'time', 'timeout', 'watch', 'flock',
]);

// Files whose contents decide what this guard permits. A shell write to any of them is
// the agent editing its own leash, so writes are denied. Reads are fine. The Edit tool
// is covered separately by permissions.deny.
const PROTECTED = [
  /\.claude\/settings\.json\b/,
  /\.claude\/hooks\//,
  /claude-config\/settings\.json\b/,
  /claude-config\/hooks\//,
];

// Executables that can only read. Anything else touching a protected path is a write
// until proven otherwise. sed and awk are absent on purpose (`sed -i`, awk's `print >`).
const READ_ONLY = new Set([
  'cat', 'head', 'tail', 'wc', 'grep', 'egrep', 'fgrep', 'less', 'more', 'ls',
  'stat', 'file', 'cksum', 'md5sum', 'sha256sum', 'readlink', 'realpath', 'find',
  'basename', 'dirname', 'cmp', 'diff', 'test',
]);

// ---- shell parsing ---------------------------------------------------------

// Reduce a command segment to [leaf, rest]: the lowercased basename of its executable
// and the remaining argument string, after stripping leading noise (env-var
// assignments, redirections, the PowerShell call / dot-source operators). This is the
// segment's COMMAND POSITION — the only place a real executable appears.
function execHead(segment) {
  let s = segment.trim();
  if (s === '') return [null, ''];
  let m;
  let prev;
  do {
    prev = s;
    while ((m = /^[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*)\s+(.*)$/.exec(s))) s = m[1].trim();
    while ((m = /^\d*(?:>>|<<<|<<|>&|<&|>|<)\s*(?:"[^"]*"|'[^']*'|&?[^\s;&|<>]+)?\s+(.*)$/.exec(s))) s = m[1].trim();
    while ((m = /^&\s*(.*)$/.exec(s)) || (m = /^\.\s+(.*)$/.exec(s))) s = m[1].trim();
  } while (s !== prev);
  let exe = null, rest = '';
  if ((m = /^"([^"]+)"\s*(.*)$/.exec(s)) || (m = /^'([^']+)'\s*(.*)$/.exec(s))) {
    exe = m[1]; rest = m[2];
  } else if ((m = /^(\S+)\s*(.*)$/.exec(s))) {
    exe = m[1]; rest = m[2];
  }
  if (!exe) return [null, ''];
  return [leafOf(exe), rest];
}

// Strip quotes and any directory prefix, lowercase, drop a Windows .exe suffix — the
// canonical form in which an executable name is compared.
function leafOf(token) {
  return token
    .replace(/^['"]+|['"]+$/g, '')
    .split(/[\\/]/).pop()
    .toLowerCase()
    .replace(/\.exe$/, '');
}

// Split an argument string into tokens, treating a quoted run as one token so an
// option value like -e "ssh -p 2222" survives intact.
function tokenize(s) {
  const toks = [];
  let cur = '', quote = null, started = false;
  for (const c of s) {
    if (quote) {
      if (c === quote) quote = null;
      else cur += c;
      continue;
    }
    if (c === '"' || c === "'") { quote = c; started = true; continue; }
    if (/\s/.test(c)) {
      if (started || cur) { toks.push(cur); cur = ''; started = false; }
      continue;
    }
    cur += c; started = true;
  }
  if (started || cur) toks.push(cur);
  return toks;
}

// True when a segment runs a shell/eval/xargs wrapper in command position — either as
// its own executable, or behind a transparent exec-prefix whose options we cannot
// reliably skip, so we scan that segment's tokens for a wrapper.
function segmentHasWrapper(segment) {
  const [leaf] = execHead(segment);
  if (leaf === null) return false;
  if (WRAPPER_CMDS.has(leaf)) return true;
  if (EXEC_PREFIX.has(leaf)) {
    return segment.split(/\s+/).filter(Boolean).some((t) => WRAPPER_CMDS.has(leafOf(t)));
  }
  return false;
}

// Resolve the SSH-transport invocation a segment runs, or null. Looks through a
// transparent exec-prefix (sudo/timeout/nohup/…) to the real executable behind it.
function sshInvocation(segment) {
  const [leaf, rest] = execHead(segment);
  if (leaf === null) return null;
  if (SSH_CMDS.has(leaf)) return { tool: leaf, args: tokenize(rest) };
  if (EXEC_PREFIX.has(leaf)) {
    const toks = tokenize(rest);
    const i = toks.findIndex((t) => SSH_CMDS.has(leafOf(t)));
    if (i >= 0) return { tool: leafOf(toks[i]), args: toks.slice(i + 1) };
  }
  return null;
}

// The destination an invocation would connect to, or null when it connects to nothing
// (`ssh -V`, `rsync -a ./a ./b`). This is the ONLY reason the guard parses arguments:
// a local rsync/scp must keep working, so "opens a connection" has to be distinguished
// from "does not". Everything that does open one is denied, so no option beyond this
// needs interpreting.
function destinationOf(inv) {
  const { tool, args } = inv;
  for (let i = 0; i < args.length; i++) {
    const t = args[i];
    if (OPT_WITH_ARG.has(t)) { i++; continue; }
    if (t.startsWith('-')) continue;
    if (tool === 'ssh' || tool === 'sftp' || tool === 'ssh-copy-id') return t;
    // scp/rsync: a `host:path` is remote, a bare path is local. A Windows drive letter
    // (C:\…) and a URL scheme are not remote specs.
    const colon = t.indexOf(':');
    if (colon > 1 && !/^[a-z]+:\/\//i.test(t)) return t.slice(0, colon);
  }
  return null;
}

// A shell write to any file that defines this guard's policy.
function protectedWrite(segment) {
  if (!PROTECTED.some((re) => re.test(segment))) return null;
  const [leaf] = execHead(segment);
  if (/(^|\s)\d*>>?[^&]/.test(segment) || /(^|\s)tee\b/.test(segment)) {
    return 'redirects output into';
  }
  if (leaf && READ_ONLY.has(leaf)) return null;
  return `runs '${leaf ?? '?'}' against`;
}

// ---- main ------------------------------------------------------------------

function emit(decision, reason) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: decision,
      permissionDecisionReason: reason,
    },
  }));
  process.exit(0);
}

const ADVICE =
  'To run something on a deployed VM, use the cloud control plane instead — ' +
  '`az vm run-command invoke -g <group> -n <vm> --command-id RunPowerShellScript ' +
  '--scripts "..."` — which spends a scoped, revocable API token rather than an SSH ' +
  'key. To reach a box interactively, the operator runs `devbox ssh`; to run a test ' +
  'suite on the appliance, use /win-test. Both ssh from inside a script and are unaffected.';

function main() {
  let raw;
  try { raw = fs.readFileSync(0, 'utf8'); } catch { process.exit(0); }
  if (!raw || !raw.trim()) process.exit(0);

  let cmd;
  try {
    cmd = String(JSON.parse(raw)?.tool_input?.command ?? '');
  } catch {
    process.exit(0);
  }
  if (!cmd.trim()) process.exit(0);

  // Normalize separators so the protected-path patterns match on Windows too.
  cmd = cmd.replace(/\\/g, '/');

  // Split on shell operators and PowerShell block / subexpression delimiters, so a
  // wrapped command still surfaces its inner segment. Over-splitting inside quotes is
  // acceptable: the worst case is a deny, never a missed connection.
  const segments = cmd.split(/&&|\|\||[;|\n{}()`]/);

  // 1. The policy files come first: a command that rewrites them decides everything
  //    downstream, so it is refused before any other question is asked.
  for (const seg of segments) {
    const why = protectedWrite(seg);
    if (why) {
      emit('deny',
        `This command ${why} a file that defines the agent's guardrails ` +
        `(settings.json / hooks). Claude is not permitted to edit its own guardrails; ` +
        `ask the operator to make this change. Reading these files is fine.`);
    }
  }

  // 2. A wrapper in command position can hide an ssh from the parser, so a command that
  //    mentions one at all is refused rather than approved unread.
  if (segments.some(segmentHasWrapper) && /(^|[\s'"/])(ssh|scp|sftp|rsync|ssh-copy-id)\b/.test(cmd)) {
    emit('deny',
      `This command wraps an SSH connection in a shell (sh -c / eval / xargs). ` +
      `Ad-hoc SSH from this box is not permitted. ${ADVICE}`);
  }

  for (const seg of segments) {
    const inv = sshInvocation(seg);
    if (!inv) continue;
    const dest = destinationOf(inv);
    if (dest === null) continue;          // connects to nothing — local rsync, ssh -V
    emit('deny',
      `'${inv.tool}' to ${dest} is not permitted: this box does not make ad-hoc SSH ` +
      `connections. Such a connection would spend either the operator's forwarded agent ` +
      `or the box's own machine key on a destination Claude chose. ${ADVICE}`);
  }

  process.exit(0);                        // no SSH, no policy edit — defer
}

main();
