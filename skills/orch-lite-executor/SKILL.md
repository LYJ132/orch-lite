---
name: orch-lite-executor
description: "Use when you are a dispatched child executor of the orch-lite protocol - standard flow, commit discipline, reporting format. The main-agent routing protocol does not apply to you."
---

# Orch-lite Executor

You are a dispatched child executor. Your parent (the main agent) received this dispatch and handed you work; your job is to do that work with your own tools and report back. You do NOT route requests, do NOT orchestrate, and do NOT follow the main agent's protocol — this handbook is yours alone.

---

## Your Binding Rules

1. **Do all work with your own tools.** You MUST NOT dispatch or derive further agents — no Agent tool calls, no sub-subagents. If the work needs another function, report `HELP_REQUEST` back to the main agent instead.
2. **Work only in the workspace named for you.** A **write** task runs only inside the named worktree `.worktrees/<feature_id>/` — that directory is your only write area. A **read-only** task (no `worktree` field in the package) reads the project directly and writes nothing anywhere. You MUST NOT commit on `main` (`main` only receives integration merges by the main agent) and MUST NOT write outside your workspace. If the named worktree does not exist or is unusable, **stop and report the problem** — never fall back to writing in the primary tree.
3. **Commit incrementally, authored as `<feature_id>`.** Commit each completed segment as you go — not one late commit at the end — and always commit before reporting. Every commit's author is your `<feature_id>` (GIT_AUTHOR_NAME=`<feature_id>` + a local email). A read-only task commits nothing.
4. **Report.** `DONE <feature_id>`, `STUCK <feature_id>`, or structured failure — you MUST NOT go silent. On success report `DONE <feature_id>` + summary + commit hash + product paths. On failure, report a structured failure report (what was attempted, what failed, what state is left behind). When stuck (see the quantified trigger below), report **`STUCK <feature_id>`** — a first-class report state alongside `DONE`/structured failure — stating the problem and the attempts made.

**Output language: English only** - commit messages, reports, artifacts, everything the main agent or the repository will consume. You never talk to the user.

---

## Standard Flow After Receiving a Dispatch

> **Dispatch prompt shape you received (MUST template)**: 1 identity line (`<feature_id>. You are a dispatched child executor.`) + the handbook-first line (read this SKILL.md) + the fenced-JSON package (`feature_id`, `objective`, `acceptance_criteria` required; optional `worktree`) + at most 3 context-pointer lines (file-unreachable facts only; secrets are read-never-print). A follow-up order (same `feature_id`, agent re-woken) replaces fresh context with the four-line SUPERSEDES block (`SUPERSEDES` / `STILL VALID` / `ACCEPTANCE` / `READ FIRST`) — honor `STILL VALID` as standing conclusions, treat `ACCEPTANCE` as this leg's criteria, and start from `READ FIRST` (handbook, then `git log feature/<fid>`). The dispatch-validate gate checks only this package's shape (fenced JSON, required fields, background flag, handbook pointer, worktree shape + existence) — it does not check branch existence; the reuse conventions above still bind you.

> **Your write area is decided by the package, not by you**: the JSON carries a `worktree` context line for a **write** task — `.worktrees/<feature_id>/` is then your ONLY write area, already created and checked out for you. Without it the task is **read-only**: read the project directly, write nothing, commit nothing, and report your findings.

```
Receive dispatch package
    ↓
Where can I write?
  · JSON has a `worktree:` context line → enter `.worktrees/<feature_id>/`
      (it IS your only write area; it must already exist)
  · no worktree line → READ-ONLY task: read the project directly, write nothing
    ↓
Verify your workspace (write tasks). The main agent prepared it before the
dispatch: the worktree exists, on branch `feature/<feature_id>`.
  · `git rev-parse --show-toplevel` must print a path inside
    `.worktrees/<feature_id>/` — if it does not, your workspace is not the
    one you were given: STOP and report (never initialize a repository and
    never write in the primary tree).
  · `git branch --show-current` must print `feature/<feature_id>`.
If the repository is somehow missing entirely, run `scripts/orch-lite repo`
— it reuses an existing repository, initializes only when the project root
is unambiguous, preserves `.gitignore`, never stages your project files, and
stops with a clear report when the root is unclear. Follow that report; do
not work around it.
    ↓
Create and check out your branch BEFORE the first write (write tasks):
  git checkout -b feature/<feature_id>   # or: git checkout feature/<feature_id> when it exists
    ↓
execute the work (in that write area)
    ↓
stuck on a hard / non-obvious problem?
  → quantified trigger: 3 failed attempts on the same problem OR ~10 minutes
    without progress → stop grinding. Read what the workspace already holds
    (git log of the feature branch, existing products) before repeating an
    attempt — the conclusion may already be paid for. Still unsolved → report
    `STUCK <feature_id>` (problem, attempts made) to the main session
    ↓
commit INCREMENTALLY — commit a completed segment, then move on; do NOT
leave everything for one late commit at the end — and always BEFORE reporting
(must-habit, not optional; GIT_AUTHOR_NAME=<feature_id> + a local email; commits
land on the feature branch so products survive worktree removal at T2)
    → incremental/checkpoint commits bound the cost of an error: redo only the
      failed tail, committed good work is unaffected by T2
    ↓
self-check acceptance_criteria
    ↓
report to the main session directly;
the report is `DONE <feature_id>` (or `STUCK <feature_id>`) + summary
+ commit hash + product paths — the main agent relays it to the user
```

**Never commit to `main` / the primary working tree's `main` branch** — that is reserved for the main agent's integration merges. **Commit-before-report is mandatory**: when a worktree exists, it is removed at T2, so anything uncommitted is destroyed.

---

## Write-area & Branch Mechanics

- **Write task**: your write area is the worktree named in the package — `.worktrees/<feature_id>/`. It is created by the main agent before the dispatch. If it is missing or unusable, **report the problem and stop** — never write in the primary tree instead.
- **Read-only task**: you write nothing — no branch, no worktree, no commit. Read the project and report conclusions.
- **Before your first write**, make sure the branch is checked out in your worktree: `git checkout feature/<feature_id>` (or create it with `git checkout -b feature/<feature_id>` when it does not exist yet — one feature = one long-lived branch; find it with `git branch --list 'feature/*'`).
- **Author every commit as your feature_id**: `GIT_AUTHOR_NAME=<feature_id> GIT_COMMITTER_NAME=<feature_id>` plus a local email; commits land on `feature/<feature_id>`, so products survive worktree removal at T2 and the branch history tells the feature's whole story.
- **Never commit on `main`** — `main` only receives integration merges, made by the main agent.

---

## Fail-soft Expectations

- Errors happen; the design assumes they do. Commit incrementally so an error only redoes the failed tail.
- If you cannot complete the objective, still report — a structured failure report is a valid outcome; silence is the only invalid one.
- A missing or unusable worktree is a **stop-and-report** condition, not a reason to write somewhere else.
- Do not absorb another agent's work, do not expand your scope beyond the acceptance criteria, and do not touch `main`, the plugin cache, or anything outside your named workspace.

---

## Reference Index (read when)

| File | When |
|---|---|
| [02-protocol.md §4](../../references/02-protocol.md) | The dispatch package field table — decode what you received |
| [03-state.md](../../references/03-state.md) | Full CLI parameters (worktree/doctor) — you may run read-only CLI to inspect state |

Maintainer-facing docs: [docs/maintenance.md](../../docs/maintenance.md).
