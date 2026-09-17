# State Files & Worktrees (index · worktrees · memory)

> View, not authority: skills/orch-lite/SKILL.md is canonical; on any conflict SKILL.md wins — fix this file, not the rule.

> Runtime data layout, each file's schema, and the FULL CLI parameter reference. Worktrees give isolation by construction; shared-memory writes are serialized by a CLI-internal flock.

---

## 1. Project Root Structure

```
project root/                        ← primary working tree: main agent only (integration merges)
├── .orch-lite/                     # runtime data (created by init)
│   ├── index.json                  # index doc (Main Agent exclusive write)
│   └── memory/
│       ├── .lock                   # flock target — held internally by the CLI during set/append
│       └── shared.json             # shared memory (knowledge/patterns/experiences/contracts)
├── .worktrees/
│   └── <task_id>/                  # e.g. .worktrees/impl-20260910-01/ on feature/<feature_id>
└── (project business code...)
```

`init` auto-creates `index.json`=`{"tasks":{}}` (legacy `{"agents":...}` auto-migrates on load), `memory.json` (four sections); if the project has no git repo it also bootstraps one (`git init -b main` + baseline commit + `.gitignore` containing `multi-agent/`, `.orch-lite/` and `.worktrees/`).

---

## 2. index.json — Index (Main Agent exclusive write)

| Property | Value |
|---|---|
| Writer | main agent, exclusive |
| Role | minimal current state: task status + usable products (`task_id` is the sole primary key) |
| Not responsible for | real-time messaging, history, full experience store |

**Schema (task-centric flat map)**:
```json
{
  "tasks": {
    "impl-20260911-01": {
      "role": "impl", "feature_id": "login-api-fix", "status": "assigned",
      "objective": "Fix the 500 error of the login API",
      "acceptance_criteria": ["login API returns 200"],
      "output": null, "products": [],
      "created_at": "2026-09-11T10:00:00+08:00", "completed_at": null
    }
  }
}
```

**Two write time points (both main-agent exclusive)**:
| Time | Command | Written |
|---|---|---|
| T1 assign | `index create --task-id --role [--feature-id] [--objective] [--criteria ...] [--agent-id <agent>]` | flat entry, status=assigned; `agent_id` = plain metadata (the platform agent/session that runs the task; enables the continuation/reuse check) |
| T2 status update | `index update --task-id [--status --output --products] [--agent-id <agent>]` | status/output/products (+ optional agent_id metadata); completed/failed auto-records completed_at |

A child's `STUCK` report (executor handbook report state, alongside `TASK_COMPLETED`/structured failure) does NOT close the task: the index entry stays `assigned` until the main session re-dispatches with the recorded conclusions folded into a new objective (main skill, Memory section); a structured failure is recorded as `failed`.

---

## 3. Worktree Model

### 3.1 Layout & rules
| Property | Description |
|---|---|
| Layout | `.worktrees/<task_id>/` — one git worktree per task; the child agent's only workplace |
| Branch | `feature/<feature_id>` — one long-lived branch per feature; merge = periodic integration, not closure; never auto-deleted (only the user removes it manually if truly abandoned) |
| feature_id | main-inferred, user-confirmed, reused across the feature's tasks; optional plain metadata in dispatches. Binding is a CONVENTION (one feature = one branch), not enforcement — the dispatch-validate gate checks only package shape and never branch existence |
| Commit authorship | child sets `GIT_AUTHOR_NAME=<task_id>` (+ local email) so history distinguishes tasks (the old `instance_id` author is retired) |
| Main-tree protection | primary tree = main only (integration merges); children never commit to main. The integration merges themselves are the main agent's direct bookkeeping carve-out — `git checkout -b feature/<id>`, `git merge --ff-only`/`--no-edit`, `tests/run.sh`, and `.orch-lite` CLI index/memory updates are the main session's own steps, not dispatched work (nothing new is authored); content edits and content commits stay dispatched |
| Invariant | at most ONE writable worktree per feature branch (git-enforced; a second create fails with `feature busy`) |

**Two create openings**: ① first task of a feature — `feature/<fid>` does not exist yet, created from `--base` (default `main`); ② later task of the same feature — branch exists, new worktree attaches, continuing the feature. Same-feature concurrency beyond that follows the lazy concurrency gate (01-judgment §1.11).

### 3.2 Merge & conflict flow (N3, rewritten)
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

## 4. memory.json — Shared Memory

| Property | Value |
|---|---|
| Status | decided (`init` auto-creates) |
| Writer | main + all child agents |
| Sections | `common_knowledge{}` / `task_patterns{}` / `experiences[]` / `contracts[]` |

**Write convention (N17)**: the CLI takes an internal flock on `.orch-lite/memory.lock` during `memory set`/`append` — just call the CLI; no manual lock claim/release.

---

## 5. CLI Full Parameter Reference (`scripts/multi-agent`)

| Command | User | Purpose |
|---|---|---|
| `init` | anyone | create `.orch-lite/` structure (+ git bootstrap when absent) |
| `index create --task-id --role [--feature-id] [--objective] [--criteria ...]` | Main, T1 | flat task entry, status=assigned |
| `index update --task-id [--status --output --products]` | Main, T2 | update status/output/products (completed/failed → completed_at) |
| `index list` | anyone | flat task list (`task_id \| role \| feature_id \| status`) |
| `index show --task-id <id>` / `--feature-id <fid>` | anyone | task detail / all tasks of a feature (reuse check) |
| `worktree create --task-id --feature-id [--base main]` | Main, T1 | create `.worktrees/<task_id>/` on `feature/<feature_id>` |
| `worktree list` | anyone | worktrees + task/feature mapping; `[stale]` when the index says terminal but the dir still exists |
| `worktree remove --task-id [--force]` | Main, T2 | remove the worktree (refuses if uncommitted unless `--force`); branch untouched |
| `worktree merge --feature-id [--into main]` | Main | integrate feature branch into main (git merge-tree pre-check) |
| `memory list` / `memory get --key <path>` / `memory set --key <path> --value <JSON>` / `memory append --array experiences\|contracts --entry <JSON>` | anyone | read/write shared memory (CLI takes internal flock) |
| `doctor [--compare-dir DIR]` | anyone (main, hooks) | hygiene scan: (1) dirty worktrees / (2) stale worktrees / (3) task_id-authored commits made directly on main (first-parent view — merge-integrated feature commits are not flagged) / (4) install drift: HEAD's tracked sources by blob hash vs `--compare-dir` (default `~/.agents/skills/orch-lite`, silent when that copy is absent); always exits 0 (feeds session-init Health) |

### 5.1 Example session
```
multi-agent init
multi-agent index create --task-id impl-20260911-01 --role impl --feature-id login-api-fix \
  --objective "Fix the 500 error of the login API" --criteria "login API returns 200"
multi-agent worktree create --task-id impl-20260911-01 --feature-id login-api-fix
# ... child works in .worktrees/impl-20260911-01/, commits as impl-20260911-01 ...
multi-agent index update --task-id impl-20260911-01 --status completed --output "fixed" --products "src/auth/login.py"
multi-agent worktree merge --feature-id login-api-fix
multi-agent worktree remove --task-id impl-20260911-01
```

---

## 6. Git Ignore (what `init` creates/appends)
```gitignore
.orch-lite/
.worktrees/
```
`.orch-lite/` and `.worktrees/` are not committed; `init` appends missing lines only.