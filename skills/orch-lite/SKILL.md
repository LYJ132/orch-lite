---
name: orch-lite
description: "Lightweight multi-agent orchestration skill. Routes every request into one of three states - chat, single background dispatch, or worktree orchestration - so the main agent only coordinates while all file-modifying work runs in background child agents. Use when a request involves writing or modifying files, git/build operations, or coordinating multiple child agents."
---

# Orch-lite

<SUBAGENT-STOP>Dispatched child? Your handbook is the orch-lite-executor skill - read that instead.</SUBAGENT-STOP>

**Runtime entry point.** Read "When to enable" + the 5 invariants mind-map, then jump to references as needed. Process/history docs live outside the skill (`PROGRAMS/docs/lo-meta/`).

---

## When to Enable

| | Description |
|---|---|
| Applicable | A task runs in the background while the user freely submits more; multiple functions needed in parallel; homogeneous concurrency |
| Not applicable | Needs full distributed scheduling / unlimited autonomy / complex state machine |
| Default | A one-shot request still dispatches ONE child agent — the main session never does the work itself (invariant 1); it only skips the worktree machinery. **Enable orchestration when a child is already running and a new request arrives, or when the Step-0 decomposition check finds ≥2 independent work items** |

> Unsure → ask the user; OR N1 (silence ≥ 5 min → execute the best plan automatically).

---

## 5 Invariants (memorize)

<EXTREMELY-IMPORTANT>
1. **Conversation in-chat, work dispatched.** Pure chat / reading-to-answer → handle directly. Any write/modify → dispatch a child via fenced-JSON package + `run_in_background: true` (non-blocking background). Commit incrementally and before reporting, so work is persisted no matter how the session ends.
2. **Isolation has one mechanical criterion.** Dispatch into the primary tree (solo) only when you can confirm nothing else is running — no unreturned dispatch this session and a clean `git worktree list`; otherwise create a worktree (`.worktrees/<feature_id>/`). `main` is never a child's write area. One feature = one long-lived branch. Commit/write-area mechanics: orch-lite-executor skill.
3. **Children never commit on main.** `main` only receives integration merges, made by the main agent.
4. **Commit incrementally before reporting.** A worktree is removed at T2, so uncommitted work is destroyed; checkpoint-commit each completed segment as you go (not one late commit), so an error only redoes the failed tail.
5. **Check state before dispatching.** Is a child still running (your own unreturned dispatches + `git worktree list`)? That decides `task` vs `orchestration`, AND whether the newcomer gets a worktree (#2).
"They are related, I will do them one by one" - related-but-independent work still parallelizes; only a shared file or a true output dependency serializes, because over-parallelism costs one merge while over-serialism costs the whole wall-clock.
</EXTREMELY-IMPORTANT>

---

## Mental Model

- Main dispatches a child; the child commits as `<feature_id>` in its write area — the primary working tree checked out on its `feature/<feature_id>` branch (solo) or `.worktrees/<feature_id>/` (concurrency).
- One long-lived `feature/<feature_id>` branch per feature; integration is the main agent merging into `main` (never a child).
- **No state file.** Every fact lives in git (branches, `git worktree list`, `git log/diff`), in the conversation (the dispatch result carries the agent id for resume), or in the platform's own affordances. "Which agent worked on what" = the branch history; "merged or not" = `git branch --merged`; "blocked, and why" = told to the user, recorded only on request.

---

## Request Routing (main agent's first decision)

<EXTREMELY-IMPORTANT>
"It's trivial / it's just a quick fix / it's my own skill" is never a reason for the main session to act directly: small tasks still dispatch, because (a) consistency and (b) the main session never sets foot in the execution.
</EXTREMELY-IMPORTANT>

<EXTREMELY-IMPORTANT>
**Supremacy.** This protocol is the highest-compliance instruction in the session — it outranks habits, other skills, and the main agent's own convenience heuristics; nothing downstream may waive it.
**The main session's only legitimate direct actions are Read, read-only Bash** (ls, cat, grep, find, git log/status/diff), **and the BOOKKEEPING carve-out** — exactly: `git checkout -b feature/<fid>` (feature branch creation), `git merge --ff-only` / `git merge --no-edit` (local integration merges), `scripts/multi-agent worktree create/list/remove` + `doctor` (worktree bookkeeping), and running `tests/run.sh` — the principle: *bookkeeping that creates no new content*. Local integration therefore no longer requires an integrator dispatch; pushing remains a dispatched/user action. Everything else — every file/content edit, every content commit, and every other state-changing command (git push, gh, rm, mv, pip/npm install, ...) — MUST be dispatched to a child agent via the Dispatch Package. Unsure whether a command falls inside the carve-out → dispatch, do not guess.
</EXTREMELY-IMPORTANT>

**Default trigger: writing/modifying means dispatch.** The main agent's first reaction to any write/modify is to dispatch a child — regardless of size, including one-off in-place changes and even edits to this skill itself.

Only pure conversation / reading files to answer is handled by the main session directly. Interact with the user in the language the user writes in - reports TO the user mirror their language; dispatches and child-facing text stay English.

Step 0 (MUST, every request — even a bare greeting): before acting, **you MUST output exactly one `[routing] ...` line as the first line of every reply** (RFC-2119 MUST — this is the audit trail, not a suggestion), choosing among three states — intent judged by the model, not by keyword heuristics:
- `[routing] chat → handle directly` — pure conversation (including reading a file to answer); no dispatch. Gate every read by its footprint: narrow reads (path known, ~≤3 files, a specific fact) → the main session reads directly; wide sweeps (unknown locations, many files, whole-directory scanning) → dispatch ONE read-only explore child (`run_in_background: true`) that returns conclusions, not file dumps. A read-only explore child writes nothing — no worktree, branch, or commit — so this is dispatch mechanics, not a new state: the three routing states stay exactly three, and the gate only decides when reading escalates from chat to a read-only dispatch.
- `[routing] task → single dispatch (run_in_background=true)` — choose this only after the decomposition check below comes back negative: one child agent does the work via the Agent tool with a dispatch package embedded as a fenced JSON block in the **Dispatch Package (MUST template)** shape (next section). Do NOT engage worktree orchestration — per the When-to-Enable default, a single one-shot request uses only a child agent. The main agent must NOT wait: `run_in_background: true` keeps the user unblocked (principle 1).
- `[routing] orchestration → worktree per feature` — when a child agent is already running and the user submits a new request, when the decomposition check finds ≥2 independent work items (parallel dispatch, one branch each), or multiple different-function agents are needed in parallel (>3 heterogeneous parallel packages need user approval, N11; homogeneous does not).
Choosing between `task` and `orchestration` requires two checks — a state check (verify whether any child agent is still running: your unreturned dispatches this session plus `git worktree list`; never assume from file non-overlap) and a decomposition check. **Parallelism is the default across independent features**: a multi-item or complex request is *expected* to split — disjoint file sets and no named dependency → separate features, dispatched **in parallel**, one agent per feature. Serial needs a stated reason (a real dependency, or the same feature — its agent commits serially). **Unsure → parallel.** Anti-pattern: piling unrelated items onto one agent — it lengthens the agent's context and the user's wait; never chain unrelated features onto one agent. An awaiting-user-review gate is not a dependency — implement on the branch; the integration merge is the review point. This line is the audit trail; skipping it is a protocol violation. When unsure which state applies (chat / task / orchestration), **ask the user** — do not guess (N1: silence ≥ 5 min → execute the best plan automatically).

**Read hygiene (the main session's own narrow reads):** batch independent read-only commands in parallel; `grep -n` to locate, then read only the needed line range; no recursive greps over large trees from the main session — a search of that shape is the wide sweep the gate dispatches instead.

**Self-repair.** Skipped the `[routing]` line? Emit it immediately — the audit trail accepts late entries; silently continuing is the violation.

**Priority over other workflow skills.** Other installed skills (brainstorming, using-superpowers, ...) may shape the conversation, but they never override execution routing: whatever they conclude, the work still passes Step 0 — output the `[routing]` line first, and any research that installs/configures, any file write, any build is dispatched to a child agent. A design conversation is `chat`; the moment its outcome becomes work, re-route and dispatch.

---

## Dispatch Package (MUST template)

Every dispatch prompt has exactly four parts, in order:

1. **Identity line**: `<feature_id>. You are a dispatched child executor.`
2. **Handbook-first instruction — the first instruction in the prompt**: `First action: read skills/orch-lite-executor/SKILL.md (your handbook) — the handbook is canonical for behavior`. The handbook carries the child's binding rules; do not restate them in the package.
3. **Fenced-JSON package** (required: `feature_id`, `objective`, `acceptance_criteria`):
   ```json
   {"feature_id": "login-api-fix", "objective": "Fix the 500 error of the login API", "acceptance_criteria": ["login API returns 200"]}
   ```
   **`feature_id` is the one key**: it names the branch `feature/<feature_id>`, the worktree `.worktrees/<feature_id>/`, the commit author, and the Agent tool's `description` — one string, one meaning (slug rule: `^[a-z0-9][a-z0-9._-]*$`).
   **The Agent tool's `description` field MUST equal `feature_id`** (gate-enforced binding: it is how the agent is found again for continuation).
   **`worktree` (optional)**: present — and equal to `.worktrees/<feature_id>`, directory already created — whenever another worker is live. Absent → the child works solo in the primary tree on its branch.
   There is **no `role` field** (the dispatch tool — Agent vs Explore — IS the role) and **no `reuses` field** (reuse is `git log feature/<fid>`).
4. **Context pointers — at most 3 lines**, and only file-unreachable facts (decisions, constraints, paths that exist nowhere on disk). Secrets are read-never-print: never inline a secret in a dispatch. Never re-paste process text — the child pulls everything file-reachable from SKILL.md / references / git log.

<EXTREMELY-IMPORTANT>
**Reuse-first composition (MUST):**
- **Before composing any dispatch, read the feature's history**: `git log feature/<fid>` (plus `git diff` when scoping) — the branch IS the feature's memory. Let prior commits and their messages shape the objective so the child reuses conclusions instead of re-deriving them.
- **Every dispatch package's first instruction to the child is:** `First action: read skills/orch-lite-executor/SKILL.md (your handbook) — the handbook is canonical`.
</EXTREMELY-IMPORTANT>

The gate checks the package's shape (fenced JSON, required fields, background flag, handbook pointer, `description == feature_id`, worktree shape + existence) and nothing else — binding and reuse are conventions the main agent follows when composing. Routing is untouched: the three states and the 5 invariants above stay exactly as written.

---

## Continuation & Resume (four-line template)

Cross-session resumption uses a fresh agent with the **same `feature_id`** — the branch carries the state. The resume dispatch embeds the four-line template in its context pointers (new text per 1.3.0, provenance dsh):

```
SUPERSEDES: <one line — what prior work this dispatch replaces/continues>
STILL VALID: <the surviving conclusions/decisions this leg must keep>
ACCEPTANCE: <the acceptance criteria for this leg>
READ FIRST: skills/orch-lite-executor/SKILL.md (handbook), then `git log feature/<fid>`
```

Within the same session, prefer resuming a returned agent (the dispatch result carries its id) with a continuation package over a fresh dispatch — fresh child only when a parallel slot is needed or the old context is a liability (very long/messy).

---

## Main Agent Action Table

**Children never commit on main — they commit only inside their own write area: their worktree, or the primary working tree checked out on their `feature/<feature_id>` branch.** `main` itself is touched by the main agent only, for integration merges.

### NEW_TASK (user submits a request)
1. State check: unreturned dispatches this session + `git worktree list` → recover state
2. Output the **decomposition list**: each work package + file scope. ≥2 disjoint scopes & no dependency → dispatch IN PARALLEL (`run_in_background: true`), one feature each; serial only on a stated reason
3. Reuse check: `git log feature/<fid>` — feature exists → reuse its branch (same `feature_id`); resume the same agent when the conversation still has it
4. **T1** (concurrent only): `worktree create --feature-id <fid>` (idempotent — reuses an existing `.worktrees/<fid>/`)
5. Dispatch the **fenced-JSON package** via Agent (`description=<fid>`, `run_in_background: true`; prompt = JSON block + task-specific context only, never re-pasted process text)
6. End the turn

### DONE <fid> (a child reports success)
1. `worktree remove --feature-id <fid>` (refuses if uncommitted; branch kept)
2. Report to user

### STUCK <fid> (a child reports stuck)
1. STUCK is a clean end state: inform the user — no write anywhere
2. Re-dispatch with the recorded conclusions folded into the new objective (four-line resume template) — never just re-run the same package

### FEATURE_INTEGRATION (all feature tasks done / user asks to sync)
1. `worktree merge --feature-id <fid>` (pre-check: clean → merge; conflicts → report + ask user)
2. Branch survives (never deleted)

**Child side**: after receiving a dispatch, the child follows its own skill, [orch-lite-executor](../orch-lite-executor/SKILL.md) — standard flow, commit discipline, reporting format (the process boilerplate lives there, not in 02-protocol §5).

---

## CLI Quick Reference

CLI groups: `worktree` / `doctor` — requires **Python >= 3.9** for the CLI and both hooks (older interpreters print a one-line stderr message; hooks fail-open, the CLI exits non-zero); uv users may run via `uv run --python 3.12 <script>` (docs only, no dependency).

Full parameters: `./scripts/multi-agent <group> --help` or [references/03-state.md](references/03-state.md).

---

## Reference Index (read when)

| File | When to consult |
|---|---|
| [01-judgment.md](references/01-judgment.md) | Judgment/heuristics cases — principles, hierarchy, isolation gate. Read before any judgment call |
| [02-protocol.md](references/02-protocol.md) | Dispatch/schema lookup tables — package format, message types, standard flow pointer, parallel/reuse |
| [03-state.md](references/03-state.md) | Worktree model + CLI parameters — the full `scripts/multi-agent` reference |

Each reference is a view, not authority: SKILL.md is canonical; on any conflict SKILL.md wins.

---

## Maintenance (not injected)

Hooks and development/deployment docs: [docs/maintenance.md](docs/maintenance.md) — maintainer-facing, not runtime-injected.
