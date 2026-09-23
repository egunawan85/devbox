#!/usr/bin/env node
// ssh-host-guard.js — PreToolUse hook for Bash / PowerShell tool calls.
//
// Enforces an explicit allow list of SSH destinations. A shell command that opens an
// SSH connection (ssh, scp, sftp, rsync, ssh-copy-id) is ALLOWED only when every host
// it touches — destination and every jump hop — appears in ~/.config/devbox/ssh-allow
// as an exact `user@ipv4`. Anything else is DENIED, with the `ssh-allow add …` line the
// operator would run to permit it. Commands that open no connection are ignored
// (prints nothing, exits 0 — deferring to the normal permission flow).
//
// Why an allow list and not a prompt: `Bash(ssh:*)` in permissions.ask already prompts,
// but a prompt is a speed bump, not a boundary — it fires on the routine connection to
// your own box as loudly as on an exfiltration attempt, and it is the agent that chose
// the destination. The list inverts that: routine destinations are silent, and
// everything else is refused rather than negotiated.
//
// The list is operator-only. `ssh-allow` itself is denied to the agent in
// permissions.deny; this hook additionally denies shell WRITES to the list file and to
// the config payload that defines these rules (settings.json, hooks/) — otherwise the
// agent could append its own entry, or edit the guard out, and the list would authorize
// nothing. Reading those files stays allowed.
//
// What this does NOT cover, deliberately: ssh that happens INSIDE a script (devbox ssh,
// /win-test, the vault commands). A hook sees the command line, not what a script does
// once it runs. Those paths resolve their host from trusted state and are unaffected.
//
// Fails closed on anything it cannot read confidently — a shell wrapper hiding the
// command, an unexpanded variable in the host, a non-literal hostname. Fails SAFE if
// the hook itself breaks: a crash is a non-blocking error in Claude Code, so the call
// falls through to the `ask` rule rather than running unguarded.
//
// One cross-OS implementation: run via `node` on Linux, Windows, and macOS. The shell
// parsing helpers are duplicated from git-write-guard.js rather than shared — each hook
// is symlinked into ~/.claude/hooks as a standalone file, with no module resolution
// between them.

'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');

const ALLOW_FILE =
  process.env.SSH_ALLOW_FILE || path.join(os.homedir(), '.config', 'devbox', 'ssh-allow');

// Spelled as a full path in every operator-facing message: ~/.claude/scripts is not on
// PATH on a devbox (the other payload scripts are invoked the same way), so a message
// saying plain `ssh-allow` would hand the operator a command that does not resolve.
const MANAGER = '~/.claude/scripts/ssh-allow.sh';

// Commands that open an SSH-transport connection. All of them reach the same hosts with
// the same credentials, so guarding `ssh` alone would leave the side door open.
const SSH_CMDS = new Set(['ssh', 'scp', 'sftp', 'rsync', 'ssh-copy-id']);

// Options that consume a following separate argument. A union across the tools: a
// value mistakenly consumed costs at most a deny (fail-closed), while a value NOT
// consumed could be mistaken for the destination (`ssh -p 2222 user@ip` reading 2222
// as the host).
const OPT_WITH_ARG = new Set([
  '-b', '-c', '-D', '-E', '-e', '-F', '-I', '-i', '-J', '-L', '-l', '-m', '-O',
  '-o', '-P', '-p', '-Q', '-R', '-S', '-W', '-w', '-B', '--rsh', '--port',
]);

// Options whose presence means the typed destination is not the whole story. Rather
// than model OpenSSH's resolution order, refuse: each one can silently re-point the
// connection somewhere the allow list never approved.
//   -F  alternate ssh_config   -o Hostname=  overrides the host outright
//   -o ProxyCommand=  runs an arbitrary program as the transport
//   -o User=  changes the identity half of the user@ip pair
const DANGER_O_KEYS = new Set([
  'hostname', 'proxycommand', 'user', 'localcommand', 'permitlocalcommand', 'include',
  'remotecommand', 'canonicalizehostname',
]);

// Shell wrappers whose argument payload is another command — a bypass vector when the
// payload is an ssh (sh -c 'ssh evil.example'). A wrapper only counts in COMMAND
// POSITION (the executable of a command segment), never as a file argument.
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
// the agent editing its own leash, so writes are denied regardless of the allow list.
// Reads are fine. The Edit tool is covered separately by permissions.deny.
const PROTECTED = [
  /\.config\/devbox\/ssh-allow\b/,
  /\.claude\/settings\.json\b/,
  /\.claude\/hooks\//,
  /claude-config\/settings\.json\b/,
  /claude-config\/hooks\//,
  /claude-config\/scripts\/ssh-allow\.sh\b/,
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

// ---- allow list ------------------------------------------------------------

// One `user@ip` per line; a tab/space-separated `# note` and whole-line comments are
// ignored. A missing file is an empty list — every destination then denies, which is
// the correct posture for a guard whose policy has not been written yet.
function loadAllowList() {
  let raw;
  try {
    raw = fs.readFileSync(ALLOW_FILE, 'utf8');
  } catch {
    return new Set();
  }
  const out = new Set();
  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const entry = trimmed.split(/[\s#]/)[0];
    if (entry) out.add(entry);
  }
  return out;
}

// Literal dotted-quad only. Leading zeros are rejected to match ssh-allow.sh: inet_aton
// reads 0177.0.0.1 as octal, so allowing both spellings would mean one address has two
// names and only one of them is on the list.
function isIPv4(h) {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h);
  if (!m) return false;
  return m.slice(1).every((o) => !(o.length > 1 && o[0] === '0') && Number(o) <= 255);
}

function currentUser() {
  if (process.env.USER) return process.env.USER;
  if (process.env.LOGNAME) return process.env.LOGNAME;
  if (process.env.USERNAME) return process.env.USERNAME;
  try { return os.userInfo().username; } catch { return ''; }
}

// A destination reaches this as it was typed. Anything the shell would still expand
// (a variable, a substitution, a glob) is unresolvable at hook time — refuse rather
// than guess at what it becomes.
function unresolved(tok) {
  return /[$`*?]/.test(tok) || tok.includes('$(');
}

// Normalize `[user@]host` into `user@host`, defaulting the user the way ssh does.
// `-l user` supplies the user when the destination omits it; supplying both is
// ambiguous enough to refuse.
function normalizeDest(spec, loginUser) {
  const at = spec.lastIndexOf('@');
  let user = at >= 0 ? spec.slice(0, at) : '';
  const host = at >= 0 ? spec.slice(at + 1) : spec;
  if (user && loginUser) return { error: `both -l ${loginUser} and ${spec} name a user` };
  if (!user) user = loginUser || currentUser();
  if (!user) return { error: `cannot determine the login user for '${spec}'` };
  return { user, host, entry: `${user}@${host}` };
}

// ---- inspection ------------------------------------------------------------

// Walk one invocation's arguments and return every host it would contact, or an error
// describing why the command cannot be judged safely.
function hostsOf(inv) {
  const { tool, args } = inv;
  const specs = [];      // [user@]host strings, destination and jump hops alike
  let loginUser = '';
  let dest = null;       // ssh/sftp/ssh-copy-id: the single positional destination
  let destIndex = -1;

  for (let i = 0; i < args.length; i++) {
    const t = args[i];

    // -o Key=Value, joined (-oKey=Value) or separate (-o Key=Value). OpenSSH also
    // accepts the whitespace form (-o "ProxyCommand nc %h %p"), which splitting on '='
    // alone would read as one long key and wave straight through.
    if (t === '-o' || (t.startsWith('-o') && t.length > 2)) {
      const kv = (t === '-o' ? (args[++i] ?? '') : t.slice(2)).trim();
      const m = /^([A-Za-z]+)\s*[=\s]\s*(.*)$/.exec(kv);
      const key = (m ? m[1] : kv).toLowerCase();
      const val = m ? m[2] : '';
      if (key === 'proxyjump') { specs.push(...val.split(',').filter(Boolean)); continue; }
      if (DANGER_O_KEYS.has(key)) {
        return { error: `-o ${kv} can re-point the connection away from the named host` };
      }
      continue;
    }

    // Forwards turn an allowed box into a relay: -W hands the session to another
    // host through it, and -L/-R/-D open a tunnel to one. The allow list approved the
    // box, not everything reachable from it.
    if (/^-[WLRD]$/.test(t)) {
      return { error: `${t} forwards the connection on to another host through the named one` };
    }

    if (t === '-J') { specs.push(...(args[++i] ?? '').split(',').filter(Boolean)); continue; }
    if (t === '-l') { loginUser = args[++i] ?? ''; continue; }
    if (t === '-F') return { error: '-F names an alternate ssh_config that could re-point the host' };

    // rsync's transport command. The host still comes from the remote spec, but the
    // transport string can smuggle the same re-pointing options, so vet it.
    if (t === '-e' || t === '--rsh' || t.startsWith('--rsh=')) {
      const val = t.startsWith('--rsh=') ? t.slice(6) : (args[++i] ?? '');
      if (/(^|\s)-(?:J|F)\b/.test(val) || /proxycommand|proxyjump|hostname=/i.test(val)) {
        return { error: `the -e transport '${val}' carries its own host options` };
      }
      continue;
    }

    if (OPT_WITH_ARG.has(t)) { i++; continue; }
    if (t.startsWith('-')) continue;           // any other flag, joined or long-form

    // Positional. ssh-family: the first one is the destination, the rest are the
    // remote command. scp/rsync: a `host:path` is remote, a bare path is local.
    if (tool === 'ssh' || tool === 'sftp' || tool === 'ssh-copy-id') {
      if (dest === null) { dest = t; destIndex = i; }
    } else {
      const colon = t.indexOf(':');
      // A Windows drive letter (C:\…) and a URL scheme are not remote specs.
      if (colon > 1 && !/^[a-z]+:\/\//i.test(t)) specs.push(t.slice(0, colon));
    }
  }

  if (dest !== null) {
    specs.push(dest);
    // An allowed host used as a springboard: `ssh box 'ssh elsewhere'`. With the
    // agent forwarded, the second hop runs with the operator's credentials and the
    // allow list never saw it. Refuse the chain rather than approve half of it.
    const remote = args.slice(destIndex + 1);
    const hop = remote.find((t) => SSH_CMDS.has(leafOf(t)) || /(^|[\s;&|])ssh\s/.test(t));
    if (hop) return { error: `the remote command chains another SSH connection ('${hop}')` };
  }

  if (specs.length === 0) return { hosts: [] };   // nothing connects (ssh -V, local rsync)

  const hosts = [];
  for (const spec of specs) {
    if (unresolved(spec)) {
      return { error: `the destination '${spec}' is not literal — the shell would still expand it` };
    }
    // A jump hop may carry its own :port; strip it before parsing user@host.
    const bare = spec.replace(/:\d+$/, '');
    const norm = normalizeDest(bare, loginUser);
    if (norm.error) return { error: norm.error };
    hosts.push(norm);
  }
  return { hosts };
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

function denyHost(entry, why) {
  const detail = why ? `${why}. ` : '';
  emit('deny',
    `SSH to ${entry} is blocked: ${detail}it is not on the allow list (${ALLOW_FILE}).\n` +
    `If this destination is yours, authorize it yourself — in the session, run:\n` +
    `    ! ${MANAGER} add ${entry}\n` +
    `Claude cannot add it (that is what makes the list mean anything).`);
}

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
  //    downstream, so it is refused before any allow-list question is asked.
  for (const seg of segments) {
    const why = protectedWrite(seg);
    if (why) {
      emit('deny',
        `This command ${why} a file that defines the SSH allow list or the guard ` +
        `enforcing it. Claude is not permitted to edit its own guardrails; ask the ` +
        `operator to make this change. Reading these files is fine.`);
    }
  }

  // 1b. The allow-list manager itself. permissions.deny blocks the bare `ssh-allow …`
  //     spelling; this catches the others — an absolute path, a `sh …/ssh-allow.sh`,
  //     an exec-prefix in front. `list` stays permitted: reading the policy is fine,
  //     and the file is readable anyway.
  for (const seg of segments) {
    const [leaf, rest] = execHead(seg);
    if (leaf === null) continue;
    let args = tokenize(rest);
    let isManager = leaf === 'ssh-allow' || leaf === 'ssh-allow.sh';
    if (!isManager && (EXEC_PREFIX.has(leaf) || WRAPPER_CMDS.has(leaf))) {
      const i = args.findIndex((t) => ['ssh-allow', 'ssh-allow.sh'].includes(leafOf(t)));
      if (i >= 0) { isManager = true; args = args.slice(i + 1); }
    }
    if (!isManager) continue;
    const sub = (args.find((t) => !t.startsWith('-')) ?? '').toLowerCase();
    if (['add', 'rm', 'remove', 'del'].includes(sub)) {
      emit('deny',
        `'ssh-allow ${sub}' edits the SSH allow list, which is operator-only — if Claude ` +
        `could add its own entries the list would authorize nothing. Run it yourself:\n` +
        `    ! ${MANAGER} ${sub} ${args.filter((t) => t.includes('@'))[0] ?? '<user@ip>'}`);
    }
  }

  const invocations = segments.map(sshInvocation).filter(Boolean);

  // 2. A wrapper in command position can hide an ssh from the parser. If the command
  //    mentions one at all, refuse rather than approve what was not read.
  if (segments.some(segmentHasWrapper) && /(^|[\s'"/])(ssh|scp|sftp|rsync|ssh-copy-id)\b/.test(cmd)) {
    emit('deny',
      `This command wraps an SSH connection in a shell (sh -c / eval / xargs), so the ` +
      `destination cannot be checked against the allow list. Run the ssh directly.`);
  }

  if (invocations.length === 0) process.exit(0);   // no SSH here — defer

  const allowed = loadAllowList();
  const approved = [];

  for (const inv of invocations) {
    const result = hostsOf(inv);
    if (result.error) {
      emit('deny',
        `SSH blocked: ${result.error}. The allow list holds exact user@ip destinations, ` +
        `so a command whose real destination cannot be read is refused rather than guessed at.`);
    }
    for (const h of result.hosts) {
      if (!isIPv4(h.host)) {
        emit('deny',
          `SSH to '${h.host}' is blocked: the allow list holds literal IPv4 addresses, and ` +
          `'${h.host}' is a name — which a DNS record or an ~/.ssh/config entry could point ` +
          `anywhere. Resolve it and authorize the address:\n` +
          `    ! ${MANAGER} add ${h.user}@<ip>`);
      }
      if (!allowed.has(h.entry)) denyHost(h.entry, '');
      approved.push(h.entry);
    }
  }

  if (approved.length === 0) process.exit(0);      // options only, nothing connects

  emit('allow', `SSH destination ${[...new Set(approved)].join(', ')} is on the allow list (${ALLOW_FILE}).`);
}

main();
