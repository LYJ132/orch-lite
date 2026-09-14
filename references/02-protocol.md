# Protocol (collaboration · dispatch · parallel/reuse · memory rules)

> How agents talk, how tasks are dispatched (fenced-JSON mandate, standard flow), the parallel-decomposition/reuse contract, and the experience/contract record-time rules. Isolation is by construction (worktrees).

---

## 1. Communication Topology

**Star by default** — a child communicates with the main agent only. On-demand point-to-point for read-only queries and product handoffs (product handoffs go through the index doc: A writes, B polls and reads — no messages).

---

## 2. Message Types

Resource occupancy is enforced without messages: worktree isolation + the CLI-internal memory flock — no boundary claim/release mechanism exists.

### 2.1 Integration conflict (main → user)
Concurrent same-file edits are prevented by construction, so there is no child-to-child SCOPE_VIOLATION anymore. The only conflict surface is integration: `worktree merge --feature-id` pre-check reports conflicting files and asks the user (abort by default, or `--no-commit` for manual resolution).

```
CONFLICT from=main feature_id=login-api-fix files=["src/auth/login.py"] stage=pre-merge decision_needed=user
```

### 2.2 HANDOFF_PLAN (main → child A + child B, notified synchronously at dispatch)
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

**Forbidden**: child→child task dispatch (must go through main); child committing to main.

---

## 4. Dispatch Package Format (main → child)

**4 required fields + 1 optional**. No `instance_id`: `task_id` is the sole identity.

### 4.1 FORMAT MANDATE — fenced JSON block
The dispatch prompt MUST embed the package as a fenced JSON block:

```json
{"task_id": "impl-20260911-01", "role": "impl", "objective": "Fix the 500 error of the login API", "acceptance_criteria": ["login API returns 200"], "feature_id": "login-api-fix"}
```

**Rationale**: machine-parseable, so a PreToolUse hook validates it reliably (field presence, well-formed JSON) instead of sniffing prose; it is also the anchor for reuse references (same-feature tasks point back to the exact package that produced the branch history).

**What the dispatch prompt carries**: the JSON block + **at most 3 lines of pointers** (paths/constraints). Never re-paste process text, contracts, feature background or memory — the child pulls those from files (index / memory / git log / SKILL.md); the standard flow (§5) is OWNED by this file, and repeating it per dispatch is drift. The main session never sends mid-flight messages to a running child.

**Child death**: a child that stops or fails is re-dispatched under a new task_id or reported to the user — the main session never absorbs the work itself.

**Beyond-workspace needs are tasks**: when work requires knowledge/data beyond the current workspace (web search, external APIs, external docs), the learning itself is dispatched to a `research-<id>` child which registers its product; the main session only reads what is already in the workspace.

**Wide read sweeps are tasks too**: within the workspace, Step 0's read-footprint gate decides who reads — narrow reads (path known, ~≤3 files, a specific fact) the main session takes directly; wide sweeps (unknown locations, many files, whole-directory scanning) dispatch ONE read-only explore child (`run_in_background: true`) that returns **conclusions, not file dumps**. The explore child writes nothing — no worktree, branch, or commit — dispatch mechanics, not a fourth routing state. Narrow-read hygiene: batch independent read-only commands in parallel; `grep -n` to locate, then read only the needed range; recursive greps over large trees belong to the dispatched sweep, not the main session.

### 4.2 Field table
| Field | Type | Req | Description |
|---|---|---|---|
| `task_id` | string | yes | `{role}-{YYYYMMDD}-{seq}`; sole primary key (index key, worktree dir, commit author) |
| `role` | string | yes | functional role (test/research/impl/review/debug/docs/deploy/custom) |
| `objective` | string | yes | specific, executable, verifiable |
| `acceptance_criteria` | string[] | yes | confirmed before dispatch; the executor self-checks each |
| `feature_id` | string | no | branch `feature/<feature_id>` & worktree; main-inferred, user-confirmed, reused |

---

## 5. Standard Flow After an Executor Receives a Dispatch

Moved to its own skill: **[skills/orch-lite-executor/SKILL.md](../skills/orch-lite-executor/SKILL.md)** — the executor-facing handbook (write-area selection, incremental commit discipline, commit-before-report, reporting format, fail-soft expectations). Executors are routed there by that skill's description gate; this file no longer duplicates the flow.

---

No worker dispatch on this platform: subagents lack the Agent tool (probe 2026-09-11, 01-judgment 4.2).

---

## 7. Parallel Decomposition & Feature Reuse (main agent's perspective)

### 7.1 Parallel-decomposition contract (T1)
Before dispatching, output a **decomposition list** — each work package with its file scope (the audit trail for parallel/serial):

| Condition | Decision |
|---|---|
| ≥2 packages, disjoint file scopes, no data dependency | **dispatch IN PARALLEL** (same-turn Agent calls, `run_in_background: true`) |
| Real dependency (data or file-scope overlap) | serial; the dependent package waits |
| >3 heterogeneous parallel packages | user approval (N11); homogeneous needs none |

Parallelism is the default for independent work; serial is justified only by a NAMED dependency or a shared-file constraint — an awaiting-user-review gate is not a dependency (implement on the branch; the integration merge is the review point).

### 7.2 Feature-reuse protocol
1. **Reuse check**: `index show --feature-id <fid>` — feature exists → propose reusing `feature/<fid>`; new branch only for a genuinely new feature.
2. **Context from the branch**: task #2+ reads background from the feature branch history (`git log`/`git diff`) + `index show --feature-id` products; the dispatch does NOT re-explain background.
3. **Products survive T2**: committed to the feature branch BEFORE reporting (executor handbook, commit discipline); the index `products` entry records paths/commit.

---

## 8. Experiences & Contracts (memory rules)

### 8.1 Positioning
| | Experience | Contract |
|---|---|---|
| Stability | mutable, temporary, correctable | stable, long-term, fixed constraint |
| Nature | **high-cost problems only** (problems that took a long time / a lot of effort to solve): why it was hard / attempted paths / the solution / when it applies | "what must be followed from now on" |
| Trigger threshold | **only** when a problem cost unusual time/energy to crack | any condensed recurring law / flow that avoids a high-frequency problem |
| Storage | `shared.json` `experiences[]` | `shared.json` `contracts[]` |

Write via `memory append --array experiences|contracts --entry <JSON>`; the CLI takes an internal flock on `multi-agent/memory/.lock` (N17).

**Reading rule (the other half of the loop — hidden cost if skipped)**: memory written but never read is sunk cost. Any agent — child or main — **when hitting a hard / non-obvious problem, read `experiences` first** before re-deriving from scratch. Dispatch context tells the child where to look (§5); the main agent is reminded in SKILL.md.

### 8.2 Record-time decision (if it can be a contract, don't write an experience)
```
Problem / failure / lesson occurs
    ↓
Can it be condensed into a "must follow from now on" rule or flow?
(high-frequency/recurring law, or a flow that avoids a high-frequency problem)
    ├── clear·yes → CONTRACT (memory append --array contracts)
    ├── clear·no  → EXPERIENCE (memory append --array experiences)
    └── unsure    → ASK THE USER (do not guess)
```

### 8.3 Refinement flow (experience → contract)
Experiences accumulate → a repeat pattern emerges (same-type problem ≥ 2×, or same-type severe risk ≥ 1×) → main/user proposes a contract → user confirms → write to `contracts` → children follow automatically.

### 8.4 How contracts take effect
1. Write to the shared-memory `contracts` field → 2. child reads it upon receiving a task → 3. follows while executing → 4. main references it when setting task scope at dispatch.
