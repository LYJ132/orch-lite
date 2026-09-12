# Protocol (collaboration · dispatch · parallel/reuse · memory rules)

> How agents talk, how tasks are dispatched (fenced-JSON mandate, standard flow), the parallel-decomposition/reuse contract, and the experience/contract record-time rules. Isolation is by construction (worktrees); there are no boundary claim/release steps.

---

## 1. Communication Topology

**Star by default** — a child communicates with the main agent only. On-demand point-to-point for read-only queries and product handoffs (product handoffs go through the index doc: A writes, B polls and reads — no messages).

---

## 2. Message Types

### 2.1 Integration conflict (main → user)
Concurrent same-file edits are prevented by construction, so there is no child-to-child SCOPE_VIOLATION anymore. The only conflict surface is integration: `worktree merge --feature-id` pre-check reports conflicting files and asks the user (abort by default, or `--no-commit` for manual resolution).

```
CONFLICT from=main feature_id=login-api-fix files=["src/auth/login.py"] stage=pre-merge decision_needed=user
```

### 2.2 Resource occupancy
Enforced **without messages**: worktree isolation (one writable worktree per feature branch). Shared-memory writes are serialized by a CLI-internal flock on `multi-agent/memory/.lock`. There is no boundary claim/release CLI.

### 2.3 HANDOFF_PLAN (main → child A + child B, notified synchronously at dispatch)
```
HANDOFF_PLAN from=main to=impl-20260911-01,test-20260911-02 artifact="After the login API fix, the test task runs regression tests"
```

---

## 3. Communication Path Selection

| Scenario | Path | Method |
|---|---|---|
| User→main | direct | natural language |
| Main→child | direct | dispatch package |
| Child→main (report/help) | direct | structured text |
| Child→child (product handoff) | index doc | A writes, B polls & reads |
| Child→child (info query) | point-to-point | read-only only |
| Child→its write area | git | work only in the workspace named for you (no other task running → the working tree on your `feature/<feature_id>` branch, created before the first write; a task running → `.worktrees/<task_id>/`); commit as `<task_id>`, never on main |
| Main→worktrees | CLI | `worktree create` (T1) / `worktree remove` (T2) / `worktree merge --feature-id` (integration) |
| Child→main (comm failure) | temp doc | fallback path |

**Forbidden**: child→child task dispatch (must go through main); child committing to main; worker talking directly to main (must go through parent).

---

## 4. Temp Communication Doc (fallback)

**Trigger**: direct delivery not guaranteed. **File**: `multi-agent/comm/temp-<timestamp>.json` with `from`/`to`/`type`/`payload`/`delivered`. Cleanup: after the main agent confirms receipt → delete.

---

## 5. Dispatch Package Format (main → child)

**4 required fields + 1 optional**. No `instance_id`: `task_id` is the sole identity.

### 5.1 FORMAT MANDATE — fenced JSON block
The dispatch prompt MUST embed the package as a fenced JSON block:

```json
{"task_id": "impl-20260911-01", "role": "impl", "objective": "Fix the 500 error of the login API", "acceptance_criteria": ["login API returns 200"], "feature_id": "login-api-fix"}
```

**Rationale**: machine-parseable, so a PreToolUse hook validates it reliably (field presence, well-formed JSON) instead of sniffing prose; it is also the anchor for reuse references (same-feature tasks point back to the exact package that produced the branch history).

**What the dispatch prompt carries**: the JSON block + **at most 3 lines of pointers** (paths/constraints). Never re-paste process text, contracts, feature background or memory — the child pulls those from files (index / memory / git log / SKILL.md); the standard flow (§6) is OWNED by this file, and repeating it per dispatch is drift. The main session never sends mid-flight messages to a running child.

**Child death**: a child that stops or fails is re-dispatched under a new task_id or reported to the user — the main session never absorbs the work itself.

**Beyond-workspace needs are tasks**: when work requires knowledge/data beyond the current workspace (web search, external APIs, external docs), the learning itself is dispatched to a `research-<id>` child which registers its product; the main session only reads what is already in the workspace.

### 5.2 Field table
| Field | Type | Req | Description |
|---|---|---|---|
| `task_id` | string | yes | `{role}-{YYYYMMDD}-{seq}`; sole primary key (index key, worktree dir, commit author) |
| `role` | string | yes | functional role (test/research/impl/review/debug/docs/deploy/custom) |
| `objective` | string | yes | specific, executable, verifiable |
| `acceptance_criteria` | string[] | yes | confirmed before dispatch; the executor self-checks each |
| `feature_id` | string | no | branch `feature/<feature_id>` & worktree; main-inferred, user-confirmed, reused |

---

## 6. Standard Flow After an Executor Receives a Dispatch

This section OWNS the process boilerplate — the main agent never re-pastes it. **Fresh executors**: if you were not given these steps, follow this flow:

> **Dispatch prompt shape (MUST template — mirrored from SKILL.md "Dispatch Package")**: 1 identity line (`<task_id> (role: <role>). You are a dispatched child executor.`) + a six-rule MUST block — (1) do all work with your own tools, never dispatch/derive further agents; (2) work only in the named workspace per concurrency state (no other task running → the working tree on a `feature/<feature_id>` branch you create first; a task running → `.worktrees/<task_id>/`), never commit on main (`main` only receives integration merges by the main agent), never work outside it; (3) commit incrementally, authored as `<task_id>`, always before reporting; (4) check `multi-agent/memory/shared.json` + the index before re-deriving anything non-obvious; (5) follow every entry in memory `contracts[]`; (6) report `TASK_COMPLETED` + summary + commit hash, or a structured failure report — never go silent — + the fenced-JSON package (§5.1) + at most 3 context-pointer lines (file-unreachable facts only; secrets read-never-print).

> **Worktree is optional (lazy isolation, §1.11)**: the dispatch JSON carries a `worktree` context line ONLY when the main agent found concurrency at dispatch; without it, write in the working tree — on your `feature/<feature_id>` branch, created and checked out before the first write, never on `main`.

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
report to the main session directly (fallback: temp communication doc on failure);
the report lists product paths + the commit so the main agent records them under `index update` products
```

**Never commit to main / the primary working tree's main branch** — reserved for the main agent's integration merges. There are no boundary check/release steps (retired). **Commit-before-report is mandatory**: when a worktree exists, it is removed at T2, so anything uncommitted is destroyed.

---

## 7. Worker Dispatch (parent → worker)

Adds optional fields on top of the 4 required: `parent_task_id` / `worker_index` / `shard_spec`. Same fenced-JSON mandate (§5.1).

```json
{"task_id": "test-worker-01", "role": "test", "objective": "Run test suite tests/unit/test_auth.py", "acceptance_criteria": ["all tests pass", "coverage ≥ 80%"], "parent_task_id": "test-20260911-01", "worker_index": 0, "shard_spec": ["tests/unit/test_auth.py"]}
```

> Workers share the parent's worktree (N19): no separate worktrees, disjoint shards, never commit — the parent is sole committer (collects into `artifacts/{task_id}/worker-{i}/`). Read-only tasks (review, test runs) may use a detached checkout. No boundary ops; no leftovers after the session is auto-ended.
>
> **Platform constraint**: worker spawning is conditional on platform support for nested agent spawning. On platforms where the Agent tool is unavailable inside subagents (current platform: `Tool not found: Agent`), the **main agent dispatches homogeneous shards directly (flat parallelism)**; command-level concurrency (`pytest -n auto`, `xargs -P`) is preferred over extra agents.

---

## 8. Parallel Decomposition & Feature Reuse (main agent's perspective)

### 8.1 Parallel-decomposition contract (T1)
Before dispatching, output a **decomposition list** — each work package with its file scope (the audit trail for parallel/serial):

| Condition | Decision |
|---|---|
| ≥2 packages, disjoint file scopes, no data dependency | **dispatch IN PARALLEL** (same-turn Agent calls, `run_in_background: true`) |
| Real dependency (data or file-scope overlap) | serial; the dependent package waits |
| >3 heterogeneous parallel packages | user approval (N11); homogeneous needs none |

Parallelism is the default for independent work; serial is justified only by a real dependency.

### 8.2 Feature-reuse protocol
1. **Reuse check**: `index show --feature-id <fid>` — feature exists → propose reusing `feature/<fid>`; new branch only for a genuinely new feature.
2. **Context from the branch**: task #2+ reads background from the feature branch history (`git log`/`git diff`) + `index show --feature-id` products; the dispatch does NOT re-explain background.
3. **Products survive T2**: committed to the feature branch BEFORE reporting (§6); the index `products` entry records paths/commit.

---

## 9. Experiences & Contracts (memory rules)

### 9.1 Positioning
| | Experience | Contract |
|---|---|---|
| Stability | mutable, temporary, correctable | stable, long-term, fixed constraint |
| Nature | **high-cost problems only** (problems that took a long time / a lot of effort to solve): why it was hard / attempted paths / the solution / when it applies | "what must be followed from now on" |
| Trigger threshold | **only** when a problem cost unusual time/energy to crack | any condensed recurring law / flow that avoids a high-frequency problem |
| Storage | `shared.json` `experiences[]` | `shared.json` `contracts[]` |

Write via `memory append --array experiences|contracts --entry <JSON>`; the CLI takes an internal flock on `multi-agent/memory/.lock` (N17).

**Reading rule (the other half of the loop — hidden cost if skipped)**: memory written but never read is sunk cost. Any agent — child or main — **when hitting a hard / non-obvious problem, read `experiences` first** before re-deriving from scratch. Dispatch context tells the child where to look (§6); the main agent is reminded in SKILL.md.

### 9.2 Record-time decision (if it can be a contract, don't write an experience)
```
Problem / failure / lesson occurs
    ↓
Can it be condensed into a "must follow from now on" rule or flow?
(high-frequency/recurring law, or a flow that avoids a high-frequency problem)
    ├── clear·yes → CONTRACT (memory append --array contracts)
    ├── clear·no  → EXPERIENCE (memory append --array experiences)
    └── unsure    → ASK THE USER (do not guess)
```

### 9.3 Refinement flow (experience → contract)
Experiences accumulate → a repeat pattern emerges (same-type problem ≥ 2×, or same-type severe risk ≥ 1×) → main/user proposes a contract → user confirms → write to `contracts` → children follow automatically.

### 9.4 How contracts take effect
1. Write to the shared-memory `contracts` field → 2. child reads it upon receiving a task → 3. follows while executing → 4. main references it when setting task scope at dispatch.
