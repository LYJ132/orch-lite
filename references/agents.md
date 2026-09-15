# Named-Agent Registry (agents.json)

A user-editable registry of recurring named subagents. It exists so the main agent can dispatch a familiar role — e.g. the `integrator` that performs the main agent's integration merges, pushes, index closeout, and worktree teardown — **without re-deriving or re-injecting the full binding-rules preamble every time**.

## Entry schema

Each entry in `agents[]` has:

| Field | Type | Req | Meaning |
|---|---|---|---|
| `id` | string | yes | Unique registry key; the dispatch package references the agent by this id |
| `role` | string | yes | One of the orch-lite roles (impl/test/research/review/ops/...) |
| `purpose` | string | yes | One-sentence standing objective; keep it general |
| `standard_acceptance` | string[] | yes | Standing acceptance checks applied to every dispatch of this agent |
| `notes` | string | no | Provenance / caveats |

The registry holds **feature-independent role definitions only**: what agents exist, what each is for, and its standing acceptance checks. Nothing here names a feature line — a `features` array (per-entry feature pins) is NOT part of this schema and MUST NOT be added.

Per-task specifics (task_id, the concrete objective for THIS dispatch, extra acceptance deltas, context pointers) are **never** stored here — they travel in the dispatch package as deltas.

## Two-layer model (registry > index)

| Layer | File | Carries | Scope |
|---|---|---|---|
| Agent definitions | root `agents.json` | `id` / `role` / `purpose` / `standard_acceptance` / `notes` | feature-independent: which named agents exist at all |
| Feature bindings | `multi-agent/index.json` | each entry's `agent` field (an agents.json id) + `feature_id` | feature-scoped: which registered agent works which feature |

Resolution order: **agents.json > index.** Index entries may only *reference* agent ids that already exist in `agents.json` — an index entry never defines a new agent. When the CLI can validate cheaply it enforces this: `index create/update --agent <id>` errors when the id is absent from `agents.json` (warns only when `agents.json` itself is missing or unreadable). Role definitions always resolve from `agents.json`; feature bindings always resolve from the index.

## How the owner adds an entry

Append a JSON object with the fields above to `agents[]` in `agents.json`. Keep `purpose` general — if you find yourself writing task-specific detail into it, that detail belongs in the next dispatch's deltas instead.

## How dispatches use the registry (main agent MUST)

1. **Before composing any dispatch, consult `agents.json`.** If a named agent fits the work, compose a **delta-only package**: identity line + abbreviated MUST block (the six rules stay summarized, never re-derived) + fenced JSON carrying the registry `id`, this task's `task_id`, `objective`, `acceptance_criteria` deltas, and context pointers. The registry entry's `standard_acceptance` are appended implicitly — do not re-paste them.
2. **Bind the agent to the feature in the index, not the registry.** When the dispatch carries a `feature_id`, register the task with `index create/update --agent <id>` so the feature's index entries record which registered agent works it; later dispatches for the same feature locate that agent (and prior conclusions) via `index show --feature-id <fid>`.
3. **Every dispatch package's first instruction to the child is:** `First action: read skills/orch-lite-executor/SKILL.md (your handbook) — the binding rules summarized in this package are abbreviated; the handbook is canonical`.

The registry refines dispatch **composition** only: routing is untouched — the three states and the 5 invariants are unchanged.
