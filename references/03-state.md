# State (git · worktrees · CLI)

> 1.3.0 has **no state file**: `.orch-lite/` is never created; every fact
lives in git (branches, `git worktree list`, `git log/diff`), in the
conversation, or in the platform's own affordances. This file is the state
view; the rules are canonical in skills/orch-lite/SKILL.md.

---

## 1. Project Root Structure

```
project root/                        ← primary working tree: main agent only (integration merges)
├── .worktrees/
│   └── <feature_id>/               # e.g. .worktrees/login-api-fix/ on feature/login-api-fix
└── (project business code...)
```

Nothing else is created. A legacy `.orch-lite/` directory (pre-1.3.0) is
ignored, never migrated — the work it recorded lives in git history.

---

## 2. Worktree Model

Canonical in SKILL.md ("Worktree Model"); mechanics summary:

- `.worktrees/<feature_id>/` — one git worktree per feature; the child agent's only workplace when concurrency is real (one-sentence isolation rule, SKILL.md invariant 2)
- branch `feature/<feature_id>` — one long-lived branch per feature; merge = integration, not closure; never auto-deleted
- commit authorship: the child sets `GIT_AUTHOR_NAME=<feature_id>` (+ local email)
- invariant: at most ONE writable worktree per feature branch (git-enforced; a second create fails with `feature busy`)

### 2.1 Merge & conflict flow
```
All feature tasks complete, or user asks to sync
    ↓
worktree merge --feature-id [--into main]   (main agent, primary tree)
    ↓
built-in pre-check: git merge-tree
    ├── clean → merges into main; feature/<feature_id> kept
    └── conflicts → report files → user decides (abort by default / --no-commit for manual)
```
Worktree isolation prevents concurrent edits from colliding; integration conflicts are surfaced here and decided by the user — no agent-to-agent file-occupancy negotiation.

---

## 3. Git Ignore (what the executor bootstrap appends)
```gitignore
.worktrees/
```
The executor handbook's git bootstrap appends the missing line only (repo-less cwd pattern).
