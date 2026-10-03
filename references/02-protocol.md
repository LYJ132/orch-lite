# Protocol (collaboration · dispatch · parallel/reuse)

> How agents talk, how tasks move between them, and where the dispatch format
lives. Dispatch rules and the parallel-decomposition/reuse contract are
canonical in skills/orch-lite/SKILL.md (Request Routing + Dispatch Package +
Continuation & Resume); the executor flow lives in the executor skill.

---

## 1. Communication Topology

**Star by default** — a child communicates with the main agent only. On-demand point-to-point for read-only queries and product handoffs (products are committed on the feature branch; the next agent reads them via `git log`/`git diff` on `feature/<fid>` — no messages, no state file).

---

## 2. Message Types

Resource occupancy is enforced without messages: worktree isolation (one writable worktree per feature branch) — no boundary claim/release mechanism exists.

### 2.1 Integration conflict (main → user)
Concurrent same-file edits are prevented by construction, so there is no child-to-child SCOPE_VIOLATION. The only conflict surface is integration: `worktree merge --feature-id` pre-check reports conflicting files and asks the user (abort by default, or `--no-commit` for manual resolution). Integration merges are the main agent's own direct action (bookkeeping carve-out) — no integrator dispatch is involved; only pushing to remotes is dispatched or user-driven.

```
CONFLICT from=main feature_id=login-api-fix files=["src/auth/login.py"] stage=pre-merge decision_needed=user
```

### 2.2 HANDOFF_PLAN (main → child A + child B, notified synchronously at dispatch)
```
HANDOFF_PLAN from=main to=login-api-fix,regression-tests artifact="After the login API fix, the test task runs regression tests"
```

---

## 3. Communication Path Selection

| Scenario | Path | Method |
|---|---|---|
| User→main | direct | natural language |
| Main→child | direct | dispatch package |
| Child→main (report/help) | direct | structured text; report states: `DONE <fid>` / **`STUCK <fid>`** (stuck 3 failed attempts or ~10 min without progress — carries problem, attempts made) / structured failure |
| Child→child (product handoff) | git | A commits products on `feature/<fid>`; B reads them from the branch history |
| Child→child (info query) | point-to-point | read-only only |
| Child→its write area | git | work only in the workspace named for you (no other task running → the working tree on your `feature/<feature_id>` branch, created before the first write; a task running → `.worktrees/<feature_id>/`); commit as `<feature_id>`, never on main |
| Main→worktrees | CLI | `worktree create --feature-id` (T1, idempotent) / `worktree remove --feature-id` (T2) / `worktree merge --feature-id` (integration) |

**Forbidden**: child→child task dispatch (must go through main); child committing to main.

**Main-session direct actions beyond reads (bookkeeping carve-out)**: the main session directly runs `git checkout -b feature/<id>`, local integration merges (`git merge --ff-only` / `--no-edit`), `scripts/multi-agent worktree create/list/remove` + `doctor`, and `tests/run.sh` — bookkeeping that creates no new content. Integrator dispatches are retired for local integration: `worktree merge --feature-id` (or the plain git merge it drives) is the main agent's own step, not a dispatched child; pushing remains a dispatched/user action. Every file/content edit and every content commit stays dispatched.

---

## 4. Dispatch Package Format (main → child)

Moved to SKILL.md "Dispatch Package (MUST template)" — the single authority
for the package (required `feature_id` / `objective` / `acceptance_criteria`;
no `role`, no `reuses`; `description == feature_id`; optional `worktree`).
The gate constants live in `hooks/dispatch-validate.py`; `session-init.py`
renders the SessionStart notice from them.

## 5. Standard Flow After an Executor Receives a Dispatch

Owned by the executor skill: **[skills/orch-lite-executor/SKILL.md](../skills/orch-lite-executor/SKILL.md)** — write-area selection, git bootstrap, incremental commit discipline, commit-before-report, reporting format.
