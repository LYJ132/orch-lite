# Test Scenarios

---

The scenarios below can be pasted directly into a new Codex conversation to verify skill behavior.

---

## Scenario 1: Single Task Dispatch and Completion

### Prompt
```
Use the orch-lite skill.
Task: create a simple Python function `add(a, b)` that returns the sum of two numbers and write it to `src/math/add.py`, and create a test `tests/math/test_add.py`.
Please dispatch it to the impl agent.
```

### Expected
- The main agent routes `[routing] task` (single one-shot → one child, no orchestration ceremony)
- Dispatches a fenced-JSON package with the 4 required fields (`task_id` / `role` / `objective` / `acceptance_criteria`) + optional `feature_id`
- The executor works inside its worktree `.worktrees/<task_id>/` (on `feature/<feature_id>`), creates the files, and **commits there as `<task_id>`** — never on main
- On completion, reports TASK_COMPLETED; the main agent reports to the user

### Forbidden
- The main agent writing code directly
- Creating unneeded extra agents

---

## Scenario 2: New Task Submitted While Another Task Is Running

### Prompt
```
(Assume scenario 1's task is running in the background)
The user submits a new task: research "Python async testing framework comparison", output to `docs/research/async-test-frameworks.md`.
Please dispatch it to the research agent.
```

### Expected
- The main agent receives NEW_TASK, does not wait for the previous task
- Because a child is already running, it routes `[routing] orchestration` and enables index+worktrees
- The two tasks run in parallel with their own worktrees (`run_in_background: true`)
- The user can check both tasks' status at any time

### Forbidden
- The main agent being blocked by the running task
- Merging the two tasks

---

## Scenario 3: A Child Agent Requests Cross-Function Help

### Prompt
```
(Assume the impl executor is implementing the payment API)
It finds it needs a security review of the newly added encryption logic and issues a HELP_REQUEST.
```

### Expected
- The executor sends `HELP_REQUEST from=<task_id> need="security review the payment API encryption logic" suggested_owner=review`
- The main agent checks existing products (`index show --feature-id`) → none → creates/reuses a review executor
- The main agent dispatches a package to review
- After review completes, the product is written to the index and the impl executor can poll and read it

### Forbidden
- The impl executor creating a review agent directly
- Bypassing the main agent

---

## Scenario 4: Same-Type Concurrency (Flat Parallelism Fallback)

### Prompt
```
Test task: need to run 3 test suites simultaneously:
- tests/unit/test_auth.py
- tests/unit/test_payment.py
- tests/unit/test_notification.py
Please have the test agent handle it.
```

### Expected
- Per N19, on this platform child-spawned workers are unavailable → the **main agent dispatches the 3 homogeneous shards directly in parallel** (same-turn Agent calls, `run_in_background: true`, shared worktree per N19, disjoint shards, never commit)
- The main/test coordinator aggregates the results and reports
- If a single command parallelizes (e.g. `pytest -n auto`), use that instead of extra agents

### Forbidden
- Child-spawned level-2 workers being created on a platform where the Agent tool is unavailable inside subagents
- Deriving deeper agents

---

## Scenario 5: Concurrency Optimization (Command-Level Parallelism)

### Prompt
```
Test task: run all unit tests `pytest tests/unit/`.
```

### Expected
- The test executor judges that a single command `pytest -n auto` is enough for parallelism
- Does not create extra agents; runs the command directly
- Reports on completion

### Forbidden
- Creating unnecessary agents for command-level parallelism

---

## Scenario 6: Integration Conflict Handling

### Prompt
```
Two impl tasks of the same feature modify src/auth/login.py in diverging directions. When both complete, the main agent runs `worktree merge --feature-id login-api-fix`.
```

### Expected
- Each task worked in its own worktree on `feature/login-api-fix`, so they never touched each other's files
- `worktree merge` runs a `git merge-tree` pre-check and reports the conflicting file(s)
- The main agent does NOT touch main: it reports the conflict to the user and asks how to resolve (abort by default, or `--no-commit` for manual resolution)
- The main working tree stays untouched until the user decides

### Forbidden
- The main agent silently auto-resolving the conflict
- Writing to main before the user decides
- Children resolving it between themselves

---

## Scenario 7: Feature Busy (Second Writable Worktree Refused)

### Prompt
```
While an impl task on feature `login-api-fix` is still running (worktree `.worktrees/impl-20260911-01/` exists), a second task on the same feature is dispatched and the main agent runs `worktree create --task-id impl-20260911-02 --feature-id login-api-fix`.
```

### Expected
- The CLI refuses: at most ONE writable worktree per feature branch, and one is already checked out
- The refusal guides the alternatives: give the new task a different `feature_id`, or (same-feature extra scope) have it share the running task's worktree as disjoint workers that never commit (N19)
- The main agent does not force-create the worktree or remove the running task's worktree

### Forbidden
- Two writable worktrees on the same feature branch
- Working around the refusal with a bare `git worktree add`

---

## Scenario 8: User Silence Timeout

### Prompt
```
The main agent asks the user to confirm acceptance criteria; the user does not respond for 5 minutes.
```

### Expected
- Pauses for 5 minutes, then auto-executes the "best plan" (recoverable + resumable + non-high-risk)
- Has an auto-degradation fallback before executing

### Forbidden
- Waiting indefinitely
- Executing high-risk / non-recoverable operations

---

## Scenario 9: More Than 3 Heterogeneous Child Agents Need User Approval

### Prompt
```
Complex task: need to start 5 agents of different functions simultaneously: impl, test, review, research, deploy.
```

### Expected
- The main agent detects more than 3 heterogeneous functions
- Asks the user to confirm each one's purpose, prompt, acceptance criteria
- Creates them only after approval

### Forbidden
- Creating 4+ heterogeneous agents without user approval

---

## Scenario 10: Multiple Same-Function Concurrency Needs No Approval

### Prompt
```
Need to run 5 different test suites simultaneously, all handled by the test agent.
```

### Expected
- The main agent judges: same-function concurrency
- Runs the suites in parallel (flat shards per N19 fallback), no user approval needed

### Forbidden
- Requiring approval for homogeneous concurrency

---

## Scenario 10b: Communication Failure Goes to the Temp Doc

### Prompt
```
A test executor completes the task but direct communication with the main session fails.
```

### Expected
- It writes `multi-agent/comm/temp-<timestamp>.json`
- The main agent reads and processes it on the next resume
- Deletes the temp file after processing

### Forbidden
- Losing the result
- Not cleaning up the temp doc

---

## Scenario 11: Product Handoff Goes Through the Index Doc

### Prompt
```
A research executor completes and produces `docs/research/api-design.md`. An impl executor needs that document to start implementation.
```

### Expected
- After completing, the research executor reports; the main agent writes the product path to the index (`index update`)
- The impl executor discovers the product by reading the index (`index show --feature-id` / `index list` / polling)
- **No point-to-point message**

### Forbidden
- Children sending direct product-handoff messages to each other

---

## Scenario 12: Refining an Experience into a Contract

### Prompt
```
(During accumulated running)
The test agent caused incidents 3 times in a row by modifying production config.
```

### Expected
- The repeat pattern is discovered (N18: it can be a contract → record-time decision)
- The contract is refined: "The test Agent is forbidden to modify production config"
- Written to the shared-memory `contracts` field via `memory append --array contracts`
- Later test executors follow it automatically

### Forbidden
- Not refining, repeating the same type of mistake

---

## Scenario 13: The Index Doc Does Not Carry Real-Time Communication

### Prompt
```
A user queries current task status.
```

### Expected
- The main agent reads `index list` and returns status
- Does not set up a subscribe/push mechanism

### Forbidden
- The index doc implementing real-time push

---

## Scenario 14: Worktree Lifecycle (Created at T1, Removed at T2, Branch Kept)

### Prompt
```
A task on feature `login-api-fix` is dispatched (T1) and later completes (T2).
```

### Expected
- T1: `worktree create --task-id --feature-id login-api-fix` + `index create --task-id --role --objective --criteria …` before dispatching; the child works only inside `.worktrees/<task_id>/` and commits there as `<task_id>` (GIT_AUTHOR_NAME)
- T2: `index update --task-id --status … --output … --products …`, then `worktree remove --task-id` (refuses if uncommitted; `--force` overrides)
- The branch `feature/login-api-fix` is **kept** after removal (long-lived, one per feature; only the user deletes an abandoned branch manually)
- The main agent never edits a child's worktree; its own primary tree is used only for integration merges (`worktree merge --feature-id`)

### Forbidden
- The main agent creating/editing files inside a child's worktree
- Auto-deleting the feature branch at worktree removal

---

## Scenario 15: Document Paths and Platform Adaptation

### Prompt
```
Running on a platform whose config directory is `.claude/`.
```

### Expected
- The runtime data directory is fixed at the project root `multi-agent/`
- Does not depend on platform-specific directories (`.claude/`, `.codex/`)
- `init` auto-creates the `multi-agent/` structure

### Forbidden
- Writing runtime data into the platform config directory

---

## Scenario 16: Recover System State Rather Than Full Context

### Prompt
```
The main agent resumes upon receiving a TASK_COMPLETED event.
```

### Expected
- Reads only: the index's relevant tasks, the relevant worktree state (`worktree list` / `.worktrees/`), the relevant dispatch package
- Does not load: all past conversations, all past tasks, all agents' full context

### Forbidden
- Restoring full session history

---

## Scenario 17: Three-Layer / Ephemeral-Executor Architecture Verification

### Prompt
```
Verify the full flow: user submits a request → main agent dispatches an impl executor → it does the work in its worktree → reports → main agent removes the worktree and reports to the user.
```

### Expected
- Executors are ephemeral (fresh session per dispatch; state lives in files under the `task_id` key)
- The three-layer limit is respected (no Level 3)
- All principles are followed

---

## Automated Test Suggestions

| Test type | Tool | Covered scenarios |
|---|---|---|
| Unit tests | pytest | CLI commands, `worktree merge` conflict pre-check, dispatch parsing, fenced-JSON validation |
| Integration tests | manual/script | scenarios 1–17 end to end |
| Stress tests | concurrency script | concurrent worktree creation on one feature branch (feature-busy refusal), conflict handling |

---

## Running Tests

```bash
# After installing the skill
cd /path/to/project
multi-agent init

# Run unit tests
pytest tests/

# Manually verify scenarios
# Run the Prompts above in Codex
```