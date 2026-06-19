# Global instructions

These apply to every project unless a project's own CLAUDE.md or my explicit instructions override them.

## Development workflow (worktree-driven)

When I ask you to add a feature, implement a fix, or
otherwise do work on a repo, follow this workflow:

1. **Worktree-first.** Do the work in a dedicated git
   worktree (via EnterWorktree / `--worktree` / agent
   isolation),
   not the main checkout. One worktree per task.

2. **Maximize automation.** Drive the task to completion as
   autonomously as possible — plan, edit, build, run tests.
   Only stop to ask me when there is an _important_ question: ambiguous requirements, irreversible or destructive
   actions, security/architecture trade-offs, or anything
   that materially changes scope. Don't interrupt for routine
   choices — pick a sensible default, note it, and keep
   going.

3. **Verify before presenting (build + tests).** Before any
   approval gate, **build the solution and build the test
   projects**, and **run the relevant test suites**. State
   explicitly what you ran and the outcome —
   passed/failed/skipped counts, or the exact reason a step
   was genuinely not runnable in the environment. Never silently skip build or tests. This applies even to config-only or
   non-code changes: build the affected project, build/run the
   test projects that could be impacted, and say what you
   checked. "Verified" means you ran it and saw it pass — not
   that
   it looks correct.

4. **Decide on red-team review.** When the implementation is
   complete, explicitly decide whether the change warrants:

   - an **internal red-team** — you adversarially
     review/attack your own change, and/or
   - an **external red-team** — I run a separate review.
     State your reasoning for each (necessary or not, and
     why). Scale this to risk: for low-risk or trivial changes
     (docs, comments, small refactors, config tweaks,
     anything with no security/money/data/auth impact),
     **recommend "not
     necessary"** and skip — don't force a review. Reserve
     red-teaming for changes that touch security, money flow,
     auth,
     crypto, data integrity, or other high-risk surfaces.

5. **Internal red-team (if needed).** Perform it yourself
   inside the worktree: attack the change, find weaknesses,
   verify, and fix what you find before moving on.

6. **External red-team (if needed).**

   - Open a **second worktree branched from the current
     working worktree's state** (not from fresh `main`), so I
     review exactly what you built.
   - Give me a ready-to-copy-paste prompt to run the external red-team.
   - Pause for my external red-team results.
   - Based on the findings, either finish, or re-iterate
     (back through internal RT as needed) until clean.

7. **Approval gate.** When the work is ready, present it for
   my review and ask for explicit approval **before** you
   merge and push. Commits INSIDE a worktree are pre-approved
   (isolated, reversible local branch) — you may commit there
   as you work without asking. Merge, push, and any commit
   OUTSIDE a worktree still require my explicit go-ahead.
   (Note: these rules are also enforced by the git-write-guard
   hook and the permission rules in settings.json — add/commit
   auto-allow inside `.claude/worktrees/`; everything else
   gated.)

## Shell command style

- **Never prefix commands with `cd`** — no `cd <dir> &&
<command>` (Bash) and no `cd <dir>; <command>`
  (PowerShell). Instead, use absolute paths in the command's
  own arguments, tool-native directory flags
  (`git -C <dir>`, `npm --prefix <dir>`, `dotnet build
<path-to-proj>`), or run the tool with its working
  directory already set. The compound form defeats
  prefix-based permission matching and trips a `cd` prompt
  every time.
