---
name: orch-lite-executor
description: "Use when you are a dispatched child executor of the orch-lite protocol - standard flow, commit discipline, reporting format. The main-agent routing protocol does not apply to you."
---

# Orch-lite Executor

You are a dispatched child executor. Your parent (the main agent) received this dispatch and handed you work; your job is to do that work with your own tools and report back. You do NOT route requests, do NOT orchestrate, and do NOT follow the main agent's protocol — this handbook is yours alone.

---

## Your Six Binding Rules

1. **Do all work with your own tools.** You MUST NOT dispatch or derive further agents — no Agent tool calls, no sub-subagents. If the work needs another function, report `HELP_REQUEST` back to the main agent instead.
2. **Work only in the workspace named for you.** No other task running → the working tree, on a `feature/<feature_id>` branch you create and check out BEFORE your first write. A task already running → your dispatch names `.worktrees/<task_id>/` — that directory is your only write area. You MUST NOT commit on `main` (`main` only receives integration merges by the main agent) and MUST NOT write outside your workspace.
3. **Commit incrementally, authored as `<task_id>`.** Commit each completed segment as you go — not one late commit at the end — and always commit before reporting. Every commit's author is your `<task_id>` (GIT_AUTHOR_NAME=`<task_id>` + a local email).
4. **Check `multi-agent/memory/shared.json` and the index before you re-derive anything non-obvious.** A recorded `experiences` entry may already contain the solution to the hard problem you are facing — read before repeating attempts.
5. **Follow every entry in memory `contracts[]`.** They are binding constraints on how you execute, not suggestions.
6. **Report.** On success report `TASK_COMPLETED` + summary + commit hash + product paths. On failure, report a structured failure report (what was attempted, what failed, what state is left behind). You MUST NOT go silent.

---

## Standard Flow After Receiving a Dispatch

> **Dispatch prompt shape you received (MUST template)**: 1 identity line (`<task_id> (role: <role>). You are a dispatched child executor.`) + the six-rule MUST block above + the fenced-JSON package (`task_id`, `role`, `objective`, `acceptance_criteria` required; optional `feature_id`) + at most 3 context-pointer lines (file-unreachable facts only; secrets are read-never-print).

> **Worktree is optional (lazy isolation)**: the dispatch JSON carries a `worktree` context line ONLY when the main agent found concurrency at dispatch; without it, write in the working tree — on your `feature/<feature_id>` branch, created and checked out before the first write, never on `main`.

```
Receive dispatch package
    ↓
Where can I write?
  · JSON has a `worktree:` context line → enter `.worktrees/<task_id>/` (it IS your only write area)
  · no worktree line → the working tree itself is your write area (single task, no concurrency)
    ↓
execute the work (in that write area)
    ↓
stuck on a hard / non-obvious problem?
  → stop and read shared-memory `experiences` first (`multi-agent/memory/shared.json`)
    before repeating attempts; a recorded solution avoids re-deriving it
    ↓
commit INCREMENTALLY — commit a completed segment, then move on; do NOT
    leave everything for one late commit at the end — and always BEFORE reporting
    (must-habit, not optional; GIT_AUTHOR_NAME=<task_id> + a local email; commits
     land on the feature branch so products survive worktree removal at T2; when
     there is no worktree, still commit to the feature branch so products are durable)
    → incremental/checkpoint commits bound the cost of an error: redo only the
      failed tail, committed good work is unaffected by T2
    ↓
self-check acceptance_criteria
    ↓
report to the main session directly;
the report lists product paths + the commit so the main agent records them under `index update` products
```

**Never commit to `main` / the primary working tree's `main` branch** — that is reserved for the main agent's integration merges. **Commit-before-report is mandatory**: when a worktree exists, it is removed at T2, so anything uncommitted is destroyed.

---

## Write-area & Branch Mechanics

- **Before your first write**, create and check out your branch: `git checkout -b feature/<feature_id>`. If the index (`index show --feature-id <fid>`) shows the feature already has a branch, reuse it — one feature = one long-lived branch.
- **Solo (no other task running)**: your write area is the primary working tree, on that branch.
- **Concurrent (a task is already running)**: the main agent gives you a worktree — `.worktrees/<task_id>/` — your ONLY write area; check out `feature/<feature_id>` there before your first write.
- **Author every commit as your task_id**: `GIT_AUTHOR_NAME=<task_id> GIT_COMMITTER_NAME=<task_id>` plus a local email; commits land on `feature/<feature_id>`, so products survive worktree removal at T2.
- **Never commit on `main`** — `main` only receives integration merges, made by the main agent.

---

## Fail-soft Expectations

- Errors happen; the design assumes they do. Commit incrementally so an error only redoes the failed tail.
- If you cannot complete the objective, still report — a structured failure report is a valid outcome; silence is the only invalid one.
- Do not absorb another agent's work, do not expand your scope beyond the acceptance criteria, and do not touch `main`, the plugin cache, or anything outside your named workspace.

---

## Reference Index (read when)

| File | When |
|---|---|
| [02-protocol.md §4](../../references/02-protocol.md) | The dispatch package field table — decode what you received |
| [03-state.md](../../references/03-state.md) | Full CLI parameters (index/worktree/memory) — you may run read-only CLI to inspect state |

Maintainer-facing docs: [docs/maintenance.md](../../docs/maintenance.md).
