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

- `.worktrees/<feature_id>/` — one git worktree per feature; the child agent's ONLY workplace for a **write** task (isolation rule, SKILL.md invariant 2). A **read-only** task needs no worktree — it writes nothing.
- branch `feature/<feature_id>` — one long-lived branch per feature; merge = integration, not closure; never auto-deleted
- commit authorship: the child sets `GIT_AUTHOR_NAME=<feature_id>` (+ local email)
- invariant: at most ONE writable worktree per feature branch (git-enforced; a second create fails with `feature busy`)

### 2.0 Project root resolution & the `repo` command

Every CLI command operates on the **git repository's main working tree**,
not on the current directory. Invoked from a repository subdirectory or from
inside a linked worktree, the CLI resolves the main tree and creates /
queries / removes / merges worktrees there.

`repo` is the code-level guarantee behind the Git-init rules (it runs
before `worktree create`, because a worktree needs a repository that
already has a commit):

| Situation | `repo` does |
|---|---|
| an existing repository | reuses it (main working tree as the root); never creates a nested repo |
| a new project directory (has files, no repo above, no child repos) | initializes it, appends the missing `.worktrees/` rule, creates an EMPTY baseline commit (the user's files stay untracked) |
| a directory holding existing child repositories | **refuses** — a workspace is not a project |
| an empty directory | **refuses** — not unambiguously a project root |
| a repository without any commit | **reports** — a worktree needs a valid commit on the base branch |

A directory outside any repository makes the worktree commands fail with an
explicit error — the CLI never guesses a project root and never initializes
a repository on its own.

**Worktree preparation failure is a stop condition.** When `worktree create`
fails, the main agent must stop that write dispatch and report the problem —
it must never fall back to writing in the primary tree.

**A worktree holds the committed tree only.** Files that are not committed
yet do not exist inside it, so `worktree create` reports the uncommitted
paths in the primary tree.

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

## 3. Git Ignore (what `repo` appends)
```gitignore
.worktrees/
```
The `repo` command appends the missing line only: it preserves the existing
`.gitignore` content and adds `.worktrees/` only when that rule is not
already there. It never overwrites the file, and it never stages or commits
the user's existing project files to manufacture a baseline. The baseline
commit it creates is EMPTY (it touches only `.gitignore`), because
`git worktree add <dir> <base>` needs a valid commit on the base branch.
