# Judgment & Architecture (principles · roles · naming · hierarchy)

> The single store of judgment rules — read before ANY decision. Premises: agents are **ephemeral executors** (fresh session per dispatch; all state lives in files; `task_id` is the sole primary key — there is no persistent agent identity, N8 retired). Isolation is **by construction** via per-task worktrees (one writable worktree per feature branch).

---

## 1. Core Principles (the judgment basis)

### 1.1 The User Is Never Blocked
A running task ≠ the user must wait. After dispatching, the main agent ends its turn; the user may submit new tasks / check status / ask questions at any time.

### 1.2 The Main Agent Coordinates, It Does Not Keep Waiting
- Receives requests → analyzes type & split strategy → dispatches child executors
- Initializes state & **worktree scope at assign time (T1)** → coordinates → handles HELP_REQUEST → receives reports → reports to the user
- The main agent does **not**: wait long for a child, do concrete work, keep agents alive between dispatches.

### 1.3 Recover System State, Not Full Context
On any event, read only the minimal state relevant to it (index + worktrees + related dispatch), process, end the turn. Do not reload past conversations / all tasks / full agent context.

### 1.4 Agents Are Limited to Three Layers
Level 0 main / Level 1 child executor / Level 2 worker (homogeneous concurrency only). Level 2 deriving Level 3 is forbidden.

### 1.5 Homogeneous Tasks Split Downward
A child executor may derive workers (Level 2) only if: serves the parent task; same goal type; basically identical flow; creates no new collaboration direction; mainly improves parallel efficiency.

### 1.6 Heterogeneous Tasks Coordinate Laterally
Different-function need → check existing products (index); yes → reference directly, no → HELP_REQUEST to the main agent, which coordinates/dispatches. Same type splits downward, different type coordinates laterally.

### 1.7 Report Completed Tasks in Order
Independent: whoever finishes first is reported first. Dependent: judge per dependency whether it can be reported independently.

### 1.8 Direct Communication First; Temp Doc Is Only a Fallback
Normal: child reports directly to the main session. Abnormal (delivery not guaranteed): temp communication doc. After recovery: confirm content → clean up.

### 1.9 The Index Carries Task State, Not Live Chit-Chat
The index provides only: task status + usable products. It is not for real-time messaging / full history / experience store.

### 1.10 Isolation Is by Construction — But Gated by Concurrency
- **When a worktree is used**, it gives isolation by construction: `.worktrees/<task_id>/`, created at T1, removed at T2; one long-lived branch per feature (`feature/<feature_id>`)
- Whether a worktree is used at all is decided **lazily, per §1.11** (only when another child is still `running` at dispatch)
- One long-lived branch per feature: `feature/<feature_id>`; merge is integration, not closure; never auto-deleted
- Concurrent same-file edits cannot collide by construction: each executor writes only in its own write area (worktree, or — when solo — the working tree checked out on its feature branch), never on main

### 1.11 Isolation Is Gated on Observed Concurrency (Lazy)
Isolate only when concurrency is real. At dispatch, the main agent reads the index's live-task set (any other child still `running`?):
- **None running** → no concurrency → the child writes in the primary working tree on its `feature/<feature_id>` branch, created and checked out before its first write — NO worktree (zero isolation premium), but still never on `main`.
- **One+ running** → concurrency is real → create a worktree for the newcomer so its writes cannot collide.

Routing default (Step 0's decomposition check): for independent work — ≥2 work items with disjoint file sets and no output dependency (one consumes the other's result) — parallel dispatch via one branch each is the default; serializing them is legitimate only for a NAMED dependency or a shared-file constraint, and an awaiting-user-review gate is not a dependency (implement on the branch; the integration merge is the review point). A parallel batch is itself concurrency, so this section's gate applies unchanged: the first-dispatched child takes the primary tree on its branch, every later child gets a worktree.
This is a "blunt" gate: it cannot see *which file* another child is writing, so concurrent-but-disjoint tasks are still worktreed. That over-isolation is one cheap `git worktree add`; the alternative (a per-file occupancy table that lets us know exactly who holds which file) is precisely the `files`/`git` occupancy tracking we retired — not worth the lifecycle cost. Zero new mechanism.

### 1.12 Shared Resources Are Protected by Mechanisms, Not Memory
- Shared-memory writes are serialized by a flock the CLI takes internally on `multi-agent/memory/.lock`; agents just call the CLI

### 1.13 Experiences Are Cast Directly Into Contracts
No separate SOP layer. Record-time decision (N18): if it can be condensed into a "must-follow" rule/flow → contract; one-off → experience; **unsure → ask the user**.

### 1.14 Do Not Add Complexity for Problems That Have Not Occurred
Build a minimal skeleton → run → discover real problems → analyze → design → user confirms → write a rule/contract. Do not pre-suppose distributed scheduling, unlimited autonomy, complex state machines, or a full exception framework.

### 1.15 Errors: Minimize Post-Hoc Rework, Do Not Over-Confirm Up Front
Errors are low-probability and never fully preventable, so the response is **not** to repeatedly ask the user / thin-slice tasks for stepwise confirmation in advance (many tasks cannot be stepwise-confirmed). Instead keep the cost of any single mistake minimal: commit incrementally (checkpoint commits — commit each completed segment as you go, not one late commit at the end), so when an error does surface only the failed tail is redone, and the committed good work survives the T2 worktree removal.

---

## 2. Three-Layer Architecture

```
Level 0: Main agent
    │
    ├── Level 1: Child executor (task A) ── Level 2: workers A-1, A-2…  (homogeneous only)
    ├── Level 1: Child executor (task B)
    └── Level 1: Child executor (task C)
```

**Forbidden**: Level 2 deriving Level 3.

---

## 3. Level 0 Main Agent (coordination hub only)

| Action | Description |
|---|---|
| Receive requests | Non-conversation requests that require file operations |
| Analyze tasks | Type, split strategy, role mapping |
| Output decomposition list | Each work package with file scope; ≥2 disjoint scopes & no dependency → dispatch IN PARALLEL (`run_in_background: true`); serial only on a real dependency |
| Reuse check | Before creating a branch: `index show --feature-id` — feature exists → propose reusing its branch |
| Dispatch executors | Ephemeral executor per work package, fenced-JSON dispatch package (N15); executors are stateless |
| Coordinate cross-function | Handle HELP_REQUEST; check existing products; dispatch/reuse |
| Receive reports | Handle TASK_COMPLETED; report to the user |
| Create the task worktree | `worktree create --task-id --feature-id` (T1); `worktree remove --task-id` (T2) |
| Handle integration conflicts | `worktree merge --feature-id` pre-check: clean → auto-merge; conflicts → report & ask the user |

**Does not do**: concrete implementation, long waits, editing a task's worktree, keeping agents alive.

---

## 4. Level 1 Child Executors & Level 2 Workers

### 4.1 Child executor (functional expert, one task per session)
| Responsibility | Description |
|---|---|
| Complete the task | Read dispatch → enter your worktree (`.worktrees/<task_id>/`) → execute → self-check → report |
| Worktree discipline | Commit inside your worktree **as `<task_id>`** (GIT_AUTHOR_NAME), never on main; integration is the main agent's job |
| Commit BEFORE reporting | Products must be on the feature branch before the report — they must survive worktree removal at T2 |
| Cross-function help | Heterogeneous needs → HELP_REQUEST to the main agent |
| Homogeneous concurrency | Derive workers when needed (same-type only) |
| Report | Direct to the main session; temp doc on failure |

### 4.2 Level 2 worker (only condition = homogeneous task parallelism)
- **Workspace (N19)**: workers get NO worktree of their own — they work inside the **parent's worktree** (`.worktrees/<parent_task_id>/`)
- **Execution**: each operates only its disjoint shard and **never commits** — the parent is the sole committer
- **Products**: write to `artifacts/{task_id}/worker-{i}/`; the parent collects/merges, registers under `index update` products
- **Session end**: auto-ended by the platform; nothing to clean up (no worktree)
- **Failure**: worker returns success/failure+reason; parent retries ≤1 time, then marks the task failed and escalates to main
- **Concurrency shortcut**: if a single command parallelizes (e.g. `pytest -n auto`), do NOT derive workers.

> **Platform constraint (grandchild probe, 2026-09-11)**: worker spawning is conditional on platform support for nested agent spawning. On the current platform the Agent tool is unavailable inside subagents (`Tool not found: Agent`), so level-2 workers cannot exist here. Where unsupported, the **main agent dispatches homogeneous shards directly (flat parallelism)**, and command-level concurrency is preferred. The ≥3-shard threshold applies only on platforms that support nesting.

---

## 5. Context Reuse (executors are stateless)

All context comes from files:

| Need | Query via | CLI |
|---|---|---|
| Historical tasks/products/status | Index | `index list` / `index show --task-id <id>` |
| All tasks of a feature (reuse check) | Index | `index show --feature-id <fid>` |
| Who is working on what | Index + worktrees | `index list` / `worktree list` |
| Knowledge/patterns/experiences/contracts | Shared memory | `memory list` / `memory get --key <path>` |
| Code change history | Git (feature branch) | `git log` / `git diff` on `feature/<fid>` |

Executors never "remember" a previous session; roles accumulate experience only through shared memory.

---

## 6. Functional Role Mapping

| Role | Responsibility |
|---|---|
| `test` | Test expert: run/write tests, test infrastructure, CI config |
| `research` | Research expert: tech selection, doc review, solution comparison |
| `impl` | Implementation expert: business code, refactor, fix bugs, features |
| `review` | Review expert: code/architecture/security review, perf analysis |
| `debug` | Debug expert: hard-problem diagnosis, log analysis, perf tuning |
| `docs` | Documentation expert: API/architecture docs, user manual, changelog |
| `deploy` | Deployment expert: CI/CD, containerization, release flow |

Extensions: user appends as needed; main agent proposes → user confirms.

---

## 7. Task ID Format (sole primary key)

```
{role}-{YYYYMMDD}-{seq}    # task_id: impl-20260911-01
{role}-worker-{seq}        # worker: test-worker-01
{role}-temp-{seq}          # one-off executor outside a feature: impl-temp-01
```

`task_id` keys the index, names the worktree (`.worktrees/<task_id>/`), and authors worktree commits (`GIT_AUTHOR_NAME=<task_id>`).

---

## 8. Dispatch Rules (executed by the main agent)

| Scenario | Rule |
|---|---|
| >3 heterogeneous parallel packages | User confirms each one's purpose/prompt/acceptance |
| Multiple homogeneous packages | No approval; dispatch directly |
| Parallel dispatch | ≥2 disjoint-scope packages with no dependency → same-turn parallel Agent calls, `run_in_background: true` |
| Required info | task_id, role, objective, acceptance_criteria (+ `feature_id`) |