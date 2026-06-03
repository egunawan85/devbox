# Global instructions

These apply to every project unless a project's own CLAUDE.md or my explicit instructions override them.

## Development workflow (worktree-driven)

When I ask you to add a feature, implement a fix, or otherwise do work on a repo, follow this workflow:

1. **Worktree-first.** Do the work in a dedicated git worktree (via EnterWorktree / `--worktree` / agent isolation), not the main checkout. One worktree per task.

2. **Maximize automation.** Drive the task to completion as autonomously as possible — plan, edit, build, run tests. Only stop to ask me when there is an *important* question: ambiguous requirements, irreversible or destructive actions, security/architecture trade-offs, or anything that materially changes scope. Don't interrupt for routine choices — pick a sensible default, note it, and keep going.

3. **Decide on red-team review.** When the implementation is complete, explicitly decide whether the change warrants:
   - an **internal red-team** — you adversarially review/attack your own change, and/or
   - an **external red-team** — I run a separate review.
   State your reasoning for each (necessary or not, and why). Scale this to risk: for low-risk or trivial changes (docs, comments, small refactors, config tweaks, anything with no security/money/data/auth impact), **recommend "not necessary"** and skip — don't force a review. Reserve red-teaming for changes that touch security, money flow, auth, crypto, data integrity, or other high-risk surfaces.

4. **Internal red-team (if needed).** Perform it yourself inside the worktree: attack the change, find weaknesses, verify, and fix what you find before moving on.

5. **External red-team (if needed).**
   - Open a **second worktree branched from the current working worktree's state** (not from fresh `main`), so I review exactly what you built.
   - Give me a ready-to-copy-paste prompt to run the external red-team.
   - Pause for my external red-team results.
   - Based on the findings, either finish, or re-iterate (back through internal RT as needed) until clean.

6. **Approval gate.** When the work is ready, present it for my review and ask for explicit approval **before** you commit, merge, and push. Never commit / merge / push without my go-ahead. (Note: git push/pull/merge/commit and other write ops are also gated by the permission rules in settings.json.)

7. **Cleanup.** After the merge/push is approved and done, clean up the worktree folder(s) — both the working worktree and any external-RT worktree.

8. **Commit messages.** Never add a "Co-Authored-By: Claude" trailer (also enforced via `attribution.commit: ""` in settings.json).
