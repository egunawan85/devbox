#!/usr/bin/env node
// Regression suite for claude-config/hooks/git-write-guard.js.
//
// Each case is a session cwd plus a shell command as the agent would compose it, paired
// with the decision the guard must reach: `ask` (a git write/network op that needs
// approval), `allow` (a local-branch op provably confined to a worktree under
// .claude/worktrees/), or `defer` (no git write — print nothing and let the normal
// permission flow decide).
//
// The ask cases are the point: each is a way a write could reach the main checkout or
// main branch while looking like worktree work. Deleting one because it looks redundant
// re-opens it. The allow cases matter too — a worktree push that prompts is the
// friction the auto-allow exists to remove.
//
// Run: node tests/git-write-guard.test.js   (no dependencies, no network)
'use strict';
const { spawnSync } = require('child_process');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const HOOK = path.join(ROOT, 'claude-config', 'hooks', 'git-write-guard.js');

const MAIN = '/home/eddyg/dev/proj/app';
const WT = `${MAIN}/.claude/worktrees/feature`;

function run(cwd, command) {
  const r = spawnSync(process.execPath, [HOOK], {
    input: JSON.stringify({ cwd, tool_input: { command } }),
    encoding: 'utf8',
  });
  if (r.status !== 0) return { decision: 'crash', reason: (r.stderr || '').trim() };
  const out = (r.stdout || '').trim();
  if (!out) return { decision: 'defer', reason: '' };
  const j = JSON.parse(out).hookSpecificOutput;
  return { decision: j.permissionDecision, reason: j.permissionDecisionReason };
}

const CASES = [
  // --- deferred: no git write ------------------------------------------------
  ['defer', MAIN, 'git status'],
  ['defer', MAIN, 'git add -A'],
  ['defer', MAIN, 'git fetch origin'],
  ['defer', MAIN, `git -C ${WT} log --oneline`],
  ['defer', MAIN, 'ls -la'],

  // --- asked: writes from the main checkout ----------------------------------
  ['ask', MAIN, 'git push'],
  ['ask', MAIN, 'git commit -m "x"'],
  ['ask', MAIN, 'git -c user.name=x commit -m "x"'],
  ['ask', MAIN, "sh -c 'git push'"],
  ['ask', MAIN, 'git pull; if ($?) { git push }'],

  // --- allowed: session cwd is the worktree ----------------------------------
  ['allow', WT, 'git commit -m "x"'],
  ['allow', WT, 'git push -u origin feature'],
  ['allow', WT, 'git commit -m "x" && git push origin feature'],

  // --- allowed: cd into the worktree -----------------------------------------
  ['allow', MAIN, `cd ${WT} && git push origin feature`],

  // --- allowed: every write aimed at the worktree with its own -C -------------
  ['allow', MAIN, `git -C ${WT} push -q origin feature`],
  ['allow', MAIN, `git -C ${WT} commit -m "x"`],
  ['allow', MAIN, `git -C "${WT}" commit -m "x" && git -C ${WT} push origin feature`],
  ['allow', MAIN, `git -C ${WT} add -A && git -C ${WT} commit -m "x"`],
  ['allow', MAIN, 'git -C .claude/worktrees/feature push origin feature'],
  ['allow', MAIN, `git -C ${WT} -c user.name=x commit -m "x"`],
  ['allow', 'C:\\dev\\app', 'git -C C:\\dev\\app\\.claude\\worktrees\\feature push origin feature'],

  // --- asked: a -C that does not confine the write to a worktree --------------
  ['ask', MAIN, `git -C ${MAIN} push origin feature`],
  ['ask', MAIN, `git -C ${WT} status && git push`],             // the push runs in main
  ['ask', MAIN, `git -C ${WT} commit -m "x" && git push`],
  ['ask', MAIN, `git -C ${WT} commit -m "x" && git -C ${MAIN} push`],
  ['ask', MAIN, `git -C ${WT}/../../.. commit -m "x"`],         // climbs back to main
  ['ask', MAIN, `git -C ${WT} -C ../../.. commit -m "x"`],      // second -C compounds
  ['ask', MAIN, `git -C ${WT} -C ${WT} commit -m "x"`],         // only a single -C is trusted
  ['ask', MAIN, `git -C ${MAIN}/.claude/worktrees commit -m "x"`], // no worktree named
  ['ask', MAIN, 'git -C $DIR/.claude/worktrees/feature push'],  // unseen expansion
  ['ask', MAIN, `git -C ${WT} --work-tree=${MAIN} commit -m "x"`],
  ['ask', MAIN, `git --git-dir=${WT}/.git push`],
  ['ask', MAIN, `git --work-tree=${WT} commit -a -m "x"`],      // commits main's branch
  ['ask', MAIN, `GIT_DIR=${MAIN}/.git git -C ${WT} commit -m "x"`],
  ['ask', MAIN, `GIT_WORK_TREE=${MAIN} git -C ${WT} reset --hard`],
  ['ask', WT, `git -C ${MAIN} checkout -- .`],                  // worktree cwd, aimed at main

  // --- asked: gated everywhere, worktree or not -------------------------------
  ['ask', MAIN, `git -C ${WT} push origin main`],
  ['ask', MAIN, `git -C ${WT} push origin HEAD:refs/heads/main`],
  ['ask', MAIN, `git -C ${WT} clean -fdx`],
  ['ask', MAIN, `git -C ${WT} commit -m "x" && git -C ${WT} clean -fd`],
  ['ask', MAIN, `sh -c 'git -C ${WT} push'`],
  ['ask', WT, 'git push origin main'],
  ['ask', WT, 'git clean -fdx'],
  ['ask', WT, 'git clone https://example.com/r.git'],
];

let pass = 0;
const failures = [];
for (const [want, cwd, command] of CASES) {
  const got = run(cwd, command);
  if (got.decision === want) pass++;
  else failures.push({ cwd, command, want, got: got.decision, reason: got.reason.split('\n')[0] });
}

console.log(`git-write-guard: ${pass}/${CASES.length} passed`);
for (const f of failures) {
  console.log(`\n  FAIL  ${f.command}`);
  console.log(`        cwd ${f.cwd}`);
  console.log(`        want ${f.want}, got ${f.got}`);
  if (f.reason) console.log(`        ${f.reason}`);
}
process.exit(failures.length === 0 ? 0 : 1);
