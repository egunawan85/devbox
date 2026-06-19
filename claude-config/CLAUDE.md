# Global instructions

These apply to every project unless a project's own CLAUDE.md or my explicit instructions override them.

## Development workflow (worktree-driven)

When I ask you to add a feature, implement a fix, or
otherwise do work on a repo, follow this workflow:

1. **Surface design decisions up front.** Before diving in,
   lay out the key design decisions for the task so I can
   review and align with you — and so automation can then run
   as long as possible without stopping. If you sense
   decisions exist but can't name them, spike to surface them.
   Resolve what you can with sensible defaults (note them);
   raise only the ones that genuinely need my input.

2. **Worktree-first.** Do the work in a dedicated git
   worktree (via EnterWorktree / `--worktree` / agent
   isolation),
   not the main checkout. One worktree per task.

3. **Maximize automation.** Drive the task to completion as
   autonomously as possible — plan, edit, build, run tests.
   Only stop to ask me when there is an _important_ question: ambiguous requirements, irreversible or destructive
   actions, security/architecture trade-offs, or anything
   that materially changes scope. Don't interrupt for routine
   choices — pick a sensible default, note it, and keep
   going.

4. **Verify before presenting (build + tests).** Before any
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

   - **Writing new tests is conditional.** Always _run_ the
     existing suite (above). For _authoring_ new tests: when a
     design decision is settled, write its tests as part of
     the work. When the design is still exploratory, hold off
     rather than locking tests against a design that may
     change — note that tests are pending, or ask me.

5. **Decide on red-team review.** When the implementation is
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

6. **Internal red-team (if needed).** Perform it yourself
   inside the worktree: attack the change, find weaknesses,
   verify, and fix what you find before moving on.

7. **External red-team (if needed) — automated and
   model-diverse.** Run this yourself rather than handing it
   to me: a full Claude Code instance is more thorough than a
   constrained sub-agent, and I stay in the loop by reviewing
   the verdicts on the PR. Run it twice with **different
   models for genuine independence** (e.g. once Opus, once
   Sonnet), post each model's verbatim verdict as its own PR
   comment, then fix and re-verify. For the highest-stakes
   cases, fall back to a **manual human-run review** instead:
   open a second worktree and hand me a paste-ready prompt to
   run myself.

   **Mechanics that are easy to get wrong:** branch each
   model off the BUILT state in its own detached worktree
   (`git worktree add --detach <path> HEAD`) and symlink the
   gitignored prereqs (`.env`, `node_modules`) so it can
   build/run/test. Launch one headless session per model in
   parallel, wrapped in `timeout`, passing `--model`
   EXPLICITLY (the default headless model may be unavailable),
   feeding the prompt via STDIN (RT prompts contain
   backticks/emoji that break shell quoting), and with
   `--permission-mode acceptEdits` (lets it write scratch
   fixtures and run tests while git-writes stay gated). The RT
   prompt must scope the safety properties to attack, a
   privacy rule (use only committed/invented fixtures, never
   real data dirs), and a structured deliverable
   (verdict + findings with severity/file:line/repro/fix).
   Then triage convergent findings first, fix, re-verify
   (back through internal RT as needed until clean).

8. **Open the PR (present for review).** Once the code, the
   required red-teams, and any tests are done, push the
   worktree's branch and open a PR for my review. This is
   pre-approved — it pushes an isolated feature branch and
   never merges. Write the PR body in two registers: first a
   **plain-English summary** of what the committed code does
   (easy to skim), then a **denser, more technical section**
   for future AI readers. Surface the **external red-team
   verdicts verbatim** for my reference — as each model's own
   PR comment for the automated model-diverse flow, or inline
   in the body for a manual review. Keep it durable — no
   references to ephemeral planning docs (see "Write for the
   long term").

9. **Merge gate.** Merging the PR to main — and any push or
   commit OUTSIDE a worktree — still requires my explicit
   go-ahead. Commits and branch pushes INSIDE a worktree are
   pre-approved (isolated, reversible local branch); you may
   work and push the branch there without asking. (These rules
   are also enforced by the git-write-guard hook and
   settings.json: add/commit and branch push auto-allow inside
   `.claude/worktrees/`; merge, push-to-main, and everything
   else gated.)

## Write for the long term

Code, comments, commit messages, and PRs outlive the plan
that produced them. Don't reference ephemeral planning
artifacts — slices, tasks, phase names, "slice 0", plan-doc
filenames — in anything committed or in a PR. Describe the
change by what it does and why, so it still reads correctly
long after the plan docs are gone.
