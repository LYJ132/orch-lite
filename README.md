# orch-lite

**Stop waiting for your agent.**

orch-lite turns the coding-agent conversation from a serial queue into a parallel workflow. The moment you submit a request, the actual work is dispatched to a background child agent — and the conversation is yours again. Submit the next idea, ask a question, or review what just finished, while the agent keeps working.

## The problem: the conversation is a lock

With a vanilla coding agent, talking and working share one channel:

- You send a request → the agent works → **you wait**.
- Mid-work you spot the next requirement, or remember a question — but you can't say it. The chat is busy until the agent finishes.
- Review is serial too: you approve task N only after it completes, and task N+1 only starts after that. Either you block the agent, or the agent blocks you.

## The idea: you and the agent run in parallel

orch-lite moves every write/modify operation off the conversation and into background child agents:

- **The conversation never blocks.** Dispatch is non-blocking (`run_in_background: true`); the main agent ends its turn immediately and you keep talking.
- **Approval becomes a pipeline.** While a child works on task N+1, you are reviewing task N. Integration into `main` is the review point — and it never gates the next dispatch.
- **The main session only coordinates.** It routes requests, dispatches children, tracks state in files, and reports results. It never touches the files itself, so it is always free to answer you.

```
time ──────────────────────────────────────────────────────►

you:        submit A ──┐  submit B ──┐   review A ✓   submit C ──┐   review B ✓
main agent:            └─ dispatch A └─ dispatch B    (chatting) └─ dispatch C
background:                A ████████✓      B ████████████✓           C ████…
```

One conversation, many tasks in flight — and you are never the one waiting.

## How it works

1. **Every request is routed** into one of three states:
   - `chat` — pure conversation or read-to-answer: handled in-session, instantly.
   - `task` — any write/modify/build request: dispatched to **one background child agent**. Your conversation returns immediately.
   - `orchestration` — a child is already running and you submit more, or the request splits into ≥2 independent work items: parallel background children, each isolated by construction.
2. **Dispatch is a fenced-JSON package** (`task_id`, `role`, `objective`, `acceptance_criteria`). A `PreToolUse` hook validates every dispatch, so a malformed package is denied — never silently misrouted.
3. **Work is durable.** Children commit incrementally on a `feature/<feature-id>` branch (never on `main`). A finished task survives even if the session dies before you review it.
4. **Isolation is lazy and by construction.** Solo work uses the primary tree on its feature branch; the moment a second child is running, the newcomer gets its own git worktree (`.worktrees/<task_id>/`). Concurrent writes cannot collide.
5. **State lives in files.** `multi-agent/index.json` tracks tasks; `multi-agent/memory/shared.json` accumulates experiences and contracts. A fresh session resumes from disk, not from chat history.
6. **Integration is the review point.** When you approve a feature, the main agent merges its branch into `main`, with a pre-merge conflict check. Feature branches are long-lived; merging is integration, not closure.

## Features

- **Non-blocking dispatch** — the user is never blocked; new requests are accepted while children run.
- **Pipelined approval** — review finished work while the next task is already in progress.
- **Parallel by default** — independent work items are dispatched in parallel; serializing requires a named dependency.
- **Worktree isolation** — per-task write areas under `.worktrees/`, created at dispatch, removed at completion.
- **Incremental commits** — checkpoint commits as work progresses; an error only redoes the failed tail.
- **Shared memory** — flock-serialized writes; experiences and contracts accumulate across sessions and agents.
- **Hygiene scanner** — `doctor` reports dirty/stale worktrees, direct commits on `main`, and install drift (never blocks).
- **Two hooks, zero config** — `SessionStart` injects the routing protocol; `PreToolUse` validates dispatch packages.
- **Claude Code / ZCode and Codex** — hooks auto-register on Claude/ZCode; Codex needs one manual trust step.

## Install

Requires **Python ≥ 3.9** (CLI and hooks).

**Marketplace (recommended):** in ZCode's plugin Discover UI, press `+` and add the repository `LYJ132/orch-lite`.

**Local directory (development):** clone the repo and point the plugin loader at the checkout directory.

> **Single install only.** If a pre-existing flat copy (e.g. `~/.agents/skills/orch-lite`) exists, retire it and remove its absolute-path hook entries from the CLI config — otherwise hooks and skills register twice.

## Quick start

Once installed, just talk. The routing happens on every request:

```
you:  fix the 500 error on the login API

agent: [routing] task → single dispatch to impl-20260913-01 (run_in_background=true)
       → dispatched; the child is working in the background. Anything else?

you:  while that's running, also draft the changelog for v1.1

agent: [routing] orchestration → enable index+worktrees
       → dispatched docs-20260913-01 in its own worktree.
```

Later, the child reports `TASK_COMPLETED`; the main agent updates the index, removes the worktree, and reports to you. You approve — the branch merges into `main`. Meanwhile your next request is already running.

Inspect state yourself at any time:

```bash
./scripts/multi-agent index list          # who is doing what
./scripts/multi-agent worktree list       # live work areas, grouped by branch
./scripts/multi-agent memory list         # accumulated knowledge
./scripts/multi-agent doctor              # hygiene scan (always exits 0)
```

## CLI

| Group | Commands | Purpose |
|---|---|---|
| `init` | — | Initialize `multi-agent/` (+ git bootstrap when absent) |
| `index` | `create` `update` `list` `show` | Task state (T1 assign → T2 status update); `task_id` is the sole primary key |
| `worktree` | `create` `list` `remove` `merge` | Per-task worktrees on long-lived `feature/<id>` branches; pre-checked merges into `main` |
| `memory` | `list` `get` `set` `append` | Shared knowledge: `common_knowledge`, `experiences`, `task_patterns`, `contracts` |
| `doctor` | — | Hygiene scan: dirty/stale worktrees, branch-discipline violations, install drift |

Full parameters: `./scripts/multi-agent <group> --help` or [references/03-state.md](references/03-state.md).

## Platform support

| Platform | Level | Notes |
|---|---|---|
| Claude Code / ZCode | Full | Hooks auto-register via the plugin manifest |
| Codex | Hooks-capable | Hooks ship with the plugin; trust them once via `/hooks` (the skill stays safe without hooks — it degrades to model-layer discipline) |

## Documentation map

| Document | Audience | Content |
|---|---|---|
| [skills/orch-lite/SKILL.md](skills/orch-lite/SKILL.md) | The main agent (runtime) | Routing protocol, 5 invariants, dispatch template |
| [skills/orch-lite-executor/SKILL.md](skills/orch-lite-executor/SKILL.md) | Dispatched children (runtime) | Executor handbook: flow, commit discipline, reporting |
| [references/](references/) | The main agent (on demand) | Judgment principles, protocol details, state schemas + full CLI |
| [docs/maintenance.md](docs/maintenance.md) | Maintainers | Install paths, hooks, deployment rules |
| [tests/](tests/) | Maintainers | Executable test matrix: `bash tests/run.sh` |

## License

MIT © linyujian
