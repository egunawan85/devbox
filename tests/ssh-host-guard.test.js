#!/usr/bin/env node
// Regression suite for claude-config/hooks/ssh-host-guard.js.
//
// Each case is a shell command as the agent would compose it, paired with the decision
// the guard must reach: `deny` (it opens an SSH-transport connection, or rewrites the
// guardrails) or `defer` (it does neither — print nothing and let the normal permission
// flow decide).
//
// The deny cases are the point. Several are forms that walk straight past a naive
// `Bash(ssh:*)` prefix rule — scp, rsync to a remote, an ssh behind sudo/timeout, an ssh
// wrapped in sh -c. Deleting one because it looks redundant re-opens it.
//
// The defer cases matter just as much: a local rsync and the sanctioned scripts must
// keep working, or the guard is a productivity bug rather than a boundary.
//
// Run: node tests/ssh-host-guard.test.js   (no dependencies, no network)
'use strict';
const { spawnSync } = require('child_process');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const HOOK = path.join(ROOT, 'claude-config', 'hooks', 'ssh-host-guard.js');

function run(command) {
  const r = spawnSync(process.execPath, [HOOK], {
    input: JSON.stringify({ cwd: ROOT, tool_input: { command } }),
    env: { ...process.env, USER: 'eddyg' },
    encoding: 'utf8',
  });
  if (r.status !== 0) return { decision: 'crash', reason: (r.stderr || '').trim() };
  const out = (r.stdout || '').trim();
  if (!out) return { decision: 'defer', reason: '' };
  const j = JSON.parse(out).hookSpecificOutput;
  return { decision: j.permissionDecision, reason: j.permissionDecisionReason };
}

const CASES = [
  // --- denied: a plain SSH connection ---------------------------------------
  ['deny', 'ssh eddyg@20.6.44.181'],
  ['deny', 'ssh 20.6.44.181'],
  ['deny', "ssh -p 2222 eddyg@20.6.44.181 'uptime'"],
  ['deny', 'ssh -o StrictHostKeyChecking=accept-new eddyg@20.6.44.181 exit'],
  ['deny', 'ssh -l root 20.6.44.181'],
  ['deny', 'ssh github.com'],
  ['deny', 'ssh eddyg@$TARGET'],

  // --- denied: the forms a Bash(ssh:*) prefix rule cannot see ---------------
  ['deny', 'scp results.trx eddyg@20.6.44.181:/tmp/'],
  ['deny', 'scp -P 2222 eddyg@20.6.44.181:/tmp/out.log ./'],
  ['deny', 'rsync -az ./src eddyg@20.6.44.181:/tmp/ci/'],
  ['deny', 'rsync -az -e "ssh -p 2222" ./out eddyg@20.6.44.181:/tmp/'],
  ['deny', 'sftp eddyg@20.6.44.181'],
  ['deny', 'ssh-copy-id eddyg@20.6.44.181'],
  ['deny', 'timeout 10 ssh eddyg@20.6.44.181 exit'],            // behind an exec-prefix
  ['deny', 'sudo ssh eddyg@20.6.44.181'],
  ['deny', 'nohup ssh eddyg@20.6.44.181 &'],
  ['deny', "sh -c 'ssh eddyg@20.6.44.181'"],                    // wrapper hides it
  ['deny', "eval 'ssh eddyg@20.6.44.181'"],
  ['deny', 'echo ok && ssh eddyg@20.6.44.181'],                 // second segment
  ['deny', 'ls | xargs ssh eddyg@20.6.44.181'],

  // --- denied: editing the guardrails --------------------------------------
  ['deny', "sed -i 's/deny/allow/' claude-config/hooks/ssh-host-guard.js"],
  ['deny', 'rm ~/.claude/hooks/ssh-host-guard.js'],
  ['deny', 'cat evil.json > claude-config/settings.json'],
  ['deny', 'echo x >> ~/.claude/settings.json'],

  // --- deferred: opens no connection ---------------------------------------
  ['defer', 'ssh -V'],
  ['defer', 'rsync -a ./a ./b'],                                // local copy
  ['defer', 'scp ./a ./b'],                                     // local copy
  ['defer', 'ls -la'],
  ['defer', 'git status'],
  ['defer', 'git pull'],                                        // git's own ssh is untouched
  ['defer', "GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=yes' git pull"],
  ['defer', 'echo "use ssh to connect"'],                       // the word, not the command
  ['defer', 'grep -n proxy claude-config/hooks/ssh-host-guard.js'],
  ['defer', 'cat ~/.claude/settings.json'],                     // reading policy is fine

  // --- deferred: the sanctioned paths must keep working --------------------
  ['defer', '~/.claude/scripts/win-test.sh --suite unit'],
  ['defer', '~/.claude/scripts/win-test-launch.sh --suite full'],
  ['defer', 'devbox -p win-test up'],
  ['defer', 'az vm run-command invoke -g win-test-rg -n win-test --command-id RunPowerShellScript --scripts "dir C:/ci"'],
];

let pass = 0;
const failures = [];
for (const [want, command] of CASES) {
  const got = run(command);
  if (got.decision === want) pass++;
  else failures.push({ command, want, got: got.decision, reason: got.reason.split('\n')[0] });
}

console.log(`ssh-host-guard: ${pass}/${CASES.length} passed`);
for (const f of failures) {
  console.log(`\n  FAIL  ${f.command}`);
  console.log(`        want ${f.want}, got ${f.got}`);
  if (f.reason) console.log(`        ${f.reason}`);
}
process.exit(failures.length === 0 ? 0 : 1);
