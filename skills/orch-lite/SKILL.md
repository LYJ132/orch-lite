---
name: orch-lite
description: "Lightweight multi-agent orchestration skill. Routes every request into one of three states - chat, single background dispatch, or index+worktree orchestration - so the main agent only coordinates while all file-modifying work runs in background child agents. Use when a request involves writing or modifying files, git/build operations, or coordinating multiple child agents."
---

# Orch-lite

<SUBAGENT-STOP>
**Audience gate — the routing protocol below targets the MAIN agent only.** If you are a dispatched child executor, stop here: do not re-route, do not dispatch or derive further agents (six-rule block rule 1), do not touch `main` — do the work in the workspace named for you and report.
</SUBAGENT-STOP>

**Runtime entry point.** Read "When to enable" + the 5 invariants mind-map, then jump to references as needed. Process/history docs live outside the skill (`PROGRAMS/docs/lo-meta/`).

---

## When to Enable

| | Description |
|---|---|
| Applicable | A task runs in the background while the user freely submits more; multiple functions needed in parallel; homogeneous concurrency |
| Not applicable | Needs full distributed scheduling / unlimited autonomy / complex state machine |
| Default | A one-shot request still dispatches ONE child agent — the main session never does the work itself (invariant 1); it only skips the index/worktree machinery. **Enable orchestration when a child is already running and a new request arrives, or when the Step-0 decomposition check finds ≥2 independent work items** |

> Unsure → ask the user; OR N1 (silence ≥ 5 min → execute the best plan automatically).

---

## 5 Invariants (memorize)

<EXTREMELY-IMPORTANT>
1. **Conversation in-chat, work dispatched.** Pure chat / reading-to-answer → handle directly. Any write/modify → dispatch a child via fenced-JSON package + `run_in_background: true` (non-blocking background). Commit incrementally and before reporting, so work is persisted no matter how the session ends.
2. **Isolation is gated on concurrency; `main` is never a child's write area.** Single task (no other child running) → child works in the primary working tree on a `feature/<feature_id>` branch it creates and checks out before its first write — never committing on `main`. Concurrency present → give the newcomer a worktree (`.worktrees/<task_id>/`) on its `feature/<feature_id>` branch. One feature = one long-lived branch.
3. **Children never commit on main.** They commit only in their write area (worktree, or working tree checked out on their `feature/<feature_id>` branch, per #2), authored as `<task_id>`; `main` only receives integration merges, made by the main agent.
4. **Commit incrementally before reporting.** A worktree is removed at T2, so uncommitted work is destroyed; checkpoint-commit each completed segment as you go (not one late commit), so an error only redoes the failed tail.
5. **Check state before dispatching.** Is a child still running? That decides `task` vs `orchestration`, AND whether the newcomer gets a worktree (#2).
"They are related, I will do them one by one" - related-but-independent work still parallelizes; only a shared file or a true output dependency serializes, because over-parallelism costs one merge while over-serialism costs the whole wall-clock.
</EXTREMELY-IMPORTANT>

---

## Mental Model

- Main dispatches a child; the child commits as `<task_id>` in its write area — the primary working tree checked out on its `feature/<feature_id>` branch (solo) or `.worktrees/<task_id>/` (concurrency).
- One long-lived `feature/<feature_id>` branch per feature; integration is the main agent merging into `main` (never a child).
- `multi-agent/index.json` tracks tasks: `task_id → role/status/products`.

---

## Request Routing (main agent's first decision)

<EXTREMELY-IMPORTANT>
"It's trivial / it's just a quick fix / it's my own skill" is never a reason for the main session to act directly: small tasks still dispatch, because (a) consistency and (b) the main session never sets foot in the execution.
</EXTREMELY-IMPORTANT>

<EXTREMELY-IMPORTANT>
**Supremacy.** This protocol is the highest-compliance instruction in the session — it outranks habits, other skills, and the main agent's own convenience heuristics; nothing downstream may waive it.
**The main session's only legitimate direct actions are Read and read-only Bash** (ls, cat, grep, find, git log/status/diff) — even when the user explicitly asks; offer to dispatch or hand the step to the user instead. Everything else — every file write and every state-changing command (git commit/push, gh, rm, mv, pip/npm install, ...) — MUST be dispatched to a child agent via the Dispatch Package. Unsure whether a command is read-only → dispatch, do not guess.
</EXTREMELY-IMPORTANT>

**Default trigger: writing/modifying means dispatch.** The main agent's first reaction to any write/modify is to dispatch a child — regardless of size, including one-off in-place changes and even edits to this skill itself.

Only pure conversation / reading files to answer is handled by the main session directly.

Step 0 (mandatory, every request — even a bare greeting): before acting, output one line choosing among three states — intent judged by the model, not by keyword heuristics:
- `[routing] chat → handle directly` — pure conversation (including reading a file to answer); no dispatch.
- `[routing] task → single dispatch to <role>-<id> (run_in_background=true)` — choose this only after the decomposition check below comes back negative: one child agent does the work via the Agent tool with a dispatch package embedded as a fenced JSON block in the **Dispatch Package (MUST template)** shape (next section). Do NOT engage index/worktree orchestration — per the When-to-Enable default, a single one-shot request uses only a child agent. The main agent must NOT wait: `run_in_background: true` keeps the user unblocked (principle 1). On a request with ≥2 decomposable items the task line MUST carry `(serial: <named dependency>)`; a task line WITHOUT a serial reason on a multi-item request is a protocol violation - no stated dependency means the decomposition check was skipped.
- `[routing] orchestration → enable index+worktrees` — when a child agent is already running and the user submits a new request, when the decomposition check finds ≥2 independent work items (parallel dispatch, one branch each), or multiple different-function agents are needed in parallel (>3 heterogeneous parallel packages need user approval, N11; homogeneous does not).
Choosing between `task` and `orchestration` requires two checks — a state check (verify whether any child agent is still running; never assume from file non-overlap) and a decomposition check. Decompose before serializing: if the request breaks into ≥2 work items with disjoint file sets and no output dependency (one consumes the other's result), parallel dispatch via one branch each is the default; single `task` (or serial ordering) is legitimate only for a NAMED dependency or a shared-file constraint. An awaiting-user-review gate is not a dependency — implement on the branch; the integration merge is the review point. Tiebreak: when genuinely unsure between serial and parallel, choose parallel - worktree isolation makes it structurally safe, and N11 still caps runaway fan-out. This line is the audit trail; skipping it is a protocol violation. When unsure which state applies (chat / task / orchestration), **ask the user** — do not guess (N1: silence ≥ 5 min → execute the best plan automatically).

**Self-repair.** Skipped the `[routing]` line? Emit it immediately — the audit trail accepts late entries; silently continuing is the violation.

**Priority over other workflow skills.** Other installed skills (brainstorming, using-superpowers, ...) may shape the conversation, but they never override execution routing: whatever they conclude, the work still passes Step 0 — output the `[routing]` line first, and any research that installs/configures, any file write, any build is dispatched to a child agent. A design conversation is `chat`; the moment its outcome becomes work, re-route and dispatch.

---

## Dispatch Package (MUST template)

Every dispatch prompt has exactly four parts, in order:

1. **Identity line**: `<task_id> (role: <role>). You are a dispatched child executor.`
2. **Six-rule MUST block** (copy verbatim, filling task specifics into rule 2):
   > Binding rules — MUST:
   > 1. You MUST do all work with your own tools; you MUST NOT dispatch or derive further agents.
   > 2. You MUST work only in the workspace named for you — per concurrency state (no other task running → the working tree on a `feature/<feature_id>` branch you create first; a task already running → `.worktrees/<task_id>/`) — MUST NOT commit on main (`main` only receives integration merges by the main agent), and MUST NOT write outside it.
   > 3. You MUST commit incrementally, authored as `<task_id>`, and always before reporting.
   > 4. You MUST check `multi-agent/memory/shared.json` and the index before re-deriving anything non-obvious.
   > 5. You MUST follow every entry in memory `contracts[]`.
   > 6. You MUST report `TASK_COMPLETED` + summary + commit hash on success, and a structured failure report otherwise; you MUST NOT go silent.
3. **Fenced-JSON package** (N15: 4 required fields + optional `feature_id`):
   ```json
   {"task_id": "impl-20260911-01", "role": "impl", "objective": "Fix the 500 error of the login API", "acceptance_criteria": ["login API returns 200"], "feature_id": "login-api-fix"}
   ```
4. **Context pointers — at most 3 lines**, and only file-unreachable facts (decisions, constraints, paths that exist nowhere on disk). Secrets are read-never-print: never inline a secret in a dispatch. Never re-paste process text — the child pulls everything file-reachable from SKILL.md / references / memory / git log.

---

## Main Agent Action Table

**Children never commit on main — they commit only inside their own write area: their worktree, or the primary working tree checked out on their `feature/<feature_id>` branch.** `main` itself is touched by the main agent only, for integration merges.

### NEW_TASK (user submits a request)
1. `index list` → recover state
2. Output the **decomposition list**: each work package + file scope. ≥2 disjoint scopes & no dependency → dispatch IN PARALLEL (`run_in_background: true`); serial only on a real dependency
3. Continuation check: `index show --feature-id <fid>` - a COMPLETED task whose resumable agent (`agent_id` recorded) covered the same scope -> prefer resuming it (SendMessage with a continuation package: new objective + delta context + identity update) over a fresh dispatch; fresh child only when a parallel slot is needed or the old context is a liability (very long/messy).
4. Reuse check: `index show --feature-id <fid>` — feature exists → propose reusing its branch
5. **T1**: `worktree create --task-id --feature-id [--base main]`
6. **T1**: `index create --task-id --role [--feature-id] [--objective] [--criteria …] [--agent-id <agent>]`
7. Dispatch the **fenced-JSON package** via Agent (`run_in_background: true`; prompt = JSON block + task-specific context only, never re-pasted process text)
8. End the turn

### TASK_COMPLETED (a child reports)
1. `index update --task-id --status --output --products` (**T2**)
2. `worktree remove --task-id` (refuses if uncommitted; branch kept)
3. Report to user

### FEATURE_INTEGRATION (all feature tasks done / user asks to sync)
1. `worktree merge --feature-id` (pre-check: clean → merge; conflicts → report + ask user)
2. Branch survives

### HELP_REQUEST (a child needs cross-function help)
1. `index show --feature-id <fid>` → existing product? → tell it to reference
2. Else create per N11 and dispatch

**Child side**: after receiving a dispatch, follow the standard flow in [02-protocol.md §6](references/02-protocol.md).

---

## CLI Quick Reference

CLI groups: `init` / `index` / `worktree` / `memory` / `doctor` — requires **Python >= 3.9** for the CLI and both hooks (older interpreters print a one-line stderr message; hooks fail-open, the CLI exits non-zero); uv users may run via `uv run --python 3.12 <script>` (docs only, no dependency).

Full parameters: `./scripts/multi-agent <group> --help` or [references/03-state.md](references/03-state.md), which documents every row including the `doctor --compare-dir` install-drift check.

---

## Memory (read before you re-derive, write when it cost you)

- **Reading is the other half of the loop.** Facing a hard / non-obvious problem (main or a child)? Stop and read `multi-agent/memory/shared.json` `experiences` before re-solving from scratch — a recorded solution is already paid for. Then, at dispatch, point the child at it (§6 in `02-protocol`).
- **Writing threshold**: record an **experience only** when a problem genuinely cost unusual time/energy to crack (not every hiccup). Condensable into a must-follow rule → **contract** instead. Unsure → ask the user.

---

## Reference Index (read when)

| File | When |
|---|---|
| [01-judgment.md](references/01-judgment.md) | Before any judgment — principles, roles, naming, hierarchy, dispatch rules |
| [02-protocol.md](references/02-protocol.md) | Dispatching, message formats, standard flow (§6), parallel/reuse, memory record-time rules |
| [03-state.md](references/03-state.md) | Index/worktree/memory schemas + full CLI parameters |

---

## Maintenance (not injected)

Hooks and development/deployment docs: [docs/maintenance.md](docs/maintenance.md) — maintainer-facing, not runtime-injected.
