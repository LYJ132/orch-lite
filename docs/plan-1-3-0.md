# PLAN — orch-lite 1.3.0 (minimal, platform-agnostic) — rev 2

Back-port the decisions validated in `dsh-orch-lite` (the Node implementation of
this same protocol at
`/mnt/d/Documents/deepseek-harness/default-workspace/dsh-orch-lite`; provenance
for the four-line resume template, the DONE/STUCK report states, idempotent
worktree create, gate single-sourcing and lazy isolation), keep only the DSH
ideas that survive the filter below, and delete everything that does not pay
for itself.

**Rev 2 (2026-10-03, owner review).** Changes from rev 1:
`features.json` is dropped entirely — no `.orch-lite/` directory is created any
more; the `role` package field is deleted; `worktree create` becomes idempotent
(code change); README drift is fixed instead of frozen; batch 1 pins the
*target* contract, not today's drifted notice; isolation stays prose
discipline, no gate checks beyond the ones named in §4.

**Not in scope (owner decisions):** no main-session write gate; no subagent
dispatch-depth gate (the original's flexibility is kept deliberately); no
mechanism that assumes a DSH-only capability (task board, `list_agents()`,
named hook events); no new enforcement mechanism on the zcode side beyond §4 —
the concurrency decision in particular stays prose discipline.

## 0. Decision filter

A mechanism is added only if **all four** hold:

1. the fact it stores cannot be answered by **git**, by the **package**, or by
   the **platform**;
2. losing it is harmless — git or a retry recovers the situation;
3. it adds no step the model must remember to perform (the CLI writes it, or it
   falls out of an action that already happens);
4. it couples to no platform capability that may be absent.

Otherwise: no mechanism.

## 1. Essence

The plugin makes the main session coordinate only, hands every write to one
continuable child per feature, and keeps "one feature = one branch = one agent"
recognisable across turns, sessions and platforms — with **no state file at
all**: every fact lives in git, in the conversation, or in the platform's own
affordances.

`index.json` was never a better design: it is a **portability patch** for
platforms that expose no queryable agent/task state. The whole optimization is
therefore: move every fact back to whichever source can already answer it.
`features.json` (rev 1's residue) was the same disease in miniature and is gone
in rev 2.

## 2. Fact owners

| Fact | Owner |
|---|---|
| which features exist; what each produced; merged or not; history | **git** (`feature/<fid>` branch, `git branch --merged`, `git log/diff`) |
| is anything running right now | the main session's own context **plus `git worktree list`**; otherwise unknown → worktree |
| in flight but not committed yet | visible as uncommitted changes or an unmerged `feature/<fid>` branch — git |
| blocked, and why | **nowhere (deliberately).** The main session tells the user; recorded only on request (a DEVLOG line or the next dispatch's context). Losing it self-heals: a re-dispatch re-derives the blocker at the cost of one wasted dispatch |
| which agent to resume | the conversation — the dispatch result carries the agent id. Cross-session: fresh agent, same `feature_id`, surviving conclusions into `STILL VALID` |
| ~~task status map, products, agent_id~~ | deleted with `index.json`; no replacement file |

## 3. No state file

`.orch-lite/` is not created any more: no `index.json`, no `features.json`, no
`memory.json`, no `hook-policy.json`.

- The naming convention (`feature/<fid>`, `.worktrees/<fid>`) plus git answer
  everything the files used to.
- The one fact git cannot answer — "blocked, and why" — fails the filter's own
  condition 3 (its sole mandatory write was a remember-step), and its loss
  self-heals (§2).
- `worktree create` stays write-free; doctor reads git only.
- dsh runs this protocol with zero state files (roster + git) — validated.
- **memory**: the plugin stops creating `memory.json`; every child-facing
  reference to it is removed. The dev repo's own `.orch-lite/` was already
  removed by hand on 2026-10-03, ahead of the release: the development
  memory migrated into `DEVLOG.md` (contracts + experiences + pain log, with
  1.3.0 obsolescence notes); `index.json` was left to git history as
  designed. Note: until batch 2 removes `bootstrap_runtime`, session-init
  recreates empty `.orch-lite/` skeletons on each SessionStart (write-if-
  absent) — harmless, never destructive.
- The `init` group is deleted; the repo-less-cwd bootstrap moves into the
  executor handbook (the dsh executor pattern: the child ensures a repo
  exists).

## 4. Behaviour changes

- **`feature_id` replaces `task_id`** everywhere: branch `feature/<fid>`,
  worktree `.worktrees/<fid>`, package field, agent `description`. One string,
  one meaning.
- **Dispatch package fields (final)**: required `feature_id` / `objective` /
  `acceptance_criteria`; `run_in_background=true`; first instruction points to
  the executor handbook; optional `worktree` (present whenever another worker
  is live). **`role` and `reuses` are deleted** — the dispatch tool (Agent vs
  Explore) *is* the role; reuse is `git log feature/<fid>`.
- **Dispatch gate**: keep the shape checks; add the `description ==
  feature_id` binding (parse the package's feature_id, compare with
  `tool_input.description`; today the gate reads description only as a
  fallback when prompt is empty — dispatch-validate.py:134-138 — and zcode's
  Agent tool requires the field, verified) and the worktree checks (value must
  match `.worktrees/<fid>` and the directory must exist). No write gate, no
  depth gate, no concurrency gate.
- **Isolation**: one-sentence rule, prose discipline, no mechanism: *"dispatch
  into the primary tree (solo) only when you can confirm nothing else is
  running — no unreturned dispatch this session and a clean `git worktree
  list`; otherwise create a worktree."* Misjudging costs one extra worktree,
  which the flow already pays for. (dsh can gate-enforce this half because its
  host counts live workers for free; zcode does not, so the text carries it.)
- **Parallelism is the default across independent features** (dsh's
  decomposition check, `lib/index.js:96`): a multi-item or complex request is
  *expected* to split. Disjoint file sets and no named dependency → separate
  features, dispatched **in parallel**, one agent per feature. Serial needs a
  stated reason (a real dependency, or the same feature — its agent commits
  serially). Unsure → parallel. Anti-pattern: piling unrelated items onto one
  agent — it lengthens the agent's context and the user's wait; never chain
  unrelated features onto one agent. No mechanism: the isolation rule already
  isolates every concurrent worker (first solo, each additional one in its own
  worktree), and `[routing] orchestration <fids>` already exists as the audit
  state.
- **Integration**: `worktree merge --feature-id` unchanged; the executor
  report states are back-ported from dsh (`DONE <fid>` / `STUCK <fid>`, plus
  summary, commit hash, product paths). STUCK is a clean end state; on STUCK
  the main session informs the user — no CLI write anywhere.
- **Continuation**: the four-line resume message (`SUPERSEDES` / `STILL
  VALID` / `ACCEPTANCE` / `READ FIRST`) is back-ported from dsh
  (`skills/orch-lite/SKILL.md:94-97`) as **new** text in the coordinator skill
  — it does not exist in 1.2.1 and there is no anchor to "keep".
- **CLI**: `worktree` (`create` / `list` / `remove` / `merge`) and `doctor`
  only. The `index`, `memory`, `init` groups are deleted; a `features` group
  never ships. `worktree create` becomes **idempotent**: an existing
  `.worktrees/<fid>` is reused and its real path printed (dsh returns
  `reused` + note); it refuses only when the branch is checked out elsewhere;
  it writes no state.
- **`doctor`**: drop the `--compare-dir` blob-hash install-drift check (≈110
  lines); rewrite the stale-worktree check from index cross-read to `git
  worktree list` + merged-branch state; report the running version, worktree
  hygiene and merged-branch state.
- **SubagentStart**: **deleted entirely** (owner decision 2026-10-03 — the
  hook was a Codex adaptation never runtime-validated there, and the owner
  cannot test Codex). Remove the hook file `subagent-start.py`, the
  `hooks.json` SubagentStart entry, tests 4.1-4.6, the hooks.md Hook 4
  section and platform table row, the README hook-list mentions, and retire
  `docs/codex-subagent-start.md`. The system does not depend on it: the
  dispatch gate already requires the package to point the child at the
  handbook, and the hook was fail-open on every path.
- **README**: minimal drift fix, not frozen — four spots, see §6.

## 5. Contract single-source (no new files)

The contract constants live in `dispatch-validate.py` — the enforcer, which
must have them anyway: required fields (no `role`, no `reuses`), the handbook
path, the background flag, the slug rule, the description binding, the
worktree shape/existence rules, and every deny message. `session-init.py`
loads that module (importlib — the filename carries a hyphen; both scripts
have `__main__` guards and are import-safe, verified) and renders the
GATE_NOTICE from the same constants. One regression test pins the rendered
notice: no field name outside the gate constants (no `reuses`, no `task_id`,
no `role`).

Reason: 1.2.1 ships an injected `GATE_NOTICE` demanding a `reuses` field the
gate no longer checks (session-init.py:100-108 vs dispatch-validate.py:39) and
listing `role` as required when the gate treats it as optional. Rejected
alternatives: a separate `gate_rules.py` (works, but is one file more than
needed) and a JSON data file (the drift was in *logic*, not just data — the
formatting code would still exist twice). **Batch 1 must write the target
contract directly — single-sourcing today's drifted text would
institutionalise the bug.**

## 6. Deletions and doc repairs

- `memory`: CLI group, `_memory_lock`, skeletons, and every child-facing
  reference (SKILL.md Memory section, executor rules 4-5, stuck-trigger
  pointer). The dev memory file itself stays on disk, uncoupled from the
  published plugin.
- `index.json`: creation, migration writer, schema docs — legacy file is
  **ignored**, not migrated (one deprecation line at most; the work itself
  lives in git).
- the `index`, `memory`, `init` CLI groups (init's git bootstrap moves into
  the executor handbook).
- `role` and `reuses` from the package format and every text mentioning them
  (incl. tests/hooks.md v7 reuse-loop section).
- `doctor --compare-dir` blob hashing (code + `case_doctor_drift`).
- Platform-limitation prose (`01-judgment.md` §4.2 grandchild probe), retired
  level-2 worker sections.
- SubagentStart ripples: `hooks/hooks.json` entry, `tests/run.sh` cases
  4.1-4.6, `tests/hooks.md` Hook 4 section + platform-table row, README
  hook-list mentions, `docs/codex-subagent-start.md`.
- tests: `case_index_agent_id`, `case_index_agent_binding`, `case_3_1/3_2`,
  `case_mem_set_list`, `case_doctor_drift` deleted; **worktree
  create/list/remove/merge tests added, including the idempotency case**
  (worktree has no dedicated tests today and is 1.3.0's load-bearing wall);
  gate cases updated to the target contract.
- `references/` consolidation: rules → `SKILL.md` (02-protocol §4 dispatch
  format, 03-state worktree model + CLI table, 01-judgment §7-8); rationale →
  new `DEVLOG.md` (01-judgment §1-6, plus the dsh provenance chain); drop the
  three "View, not authority" headers; fix the 02-protocol §6 numbering gap;
  rewrite 01-judgment §1.11 to the one-sentence isolation rule.
- README drift fix (4 spots): L185 + L203-207 (index.json task-tracking
  claims), L233 (stale `memory/shared.json` path — already wrong today),
  L121/127/405/411 ("1.2.1+" version pins). No rewrite.

## 7. Explicitly not adopted

Any state file (`features.json` included — its only non-derivable fact,
blocked-why, fails filter #3 and self-heals); a concurrency/worktree gate on
zcode (the host exposes no liveness; prose discipline plus the fail-safe
default suffice); CAS/`rev` on state writes; event-sourced JSONL; task-board
mirroring; `depends_on` / `scope` fields; an evidence/merge gate; per-feature
state files; commit trailers (`Orch-Feature:`) — the branch name already
carries it, and branches are never deleted.

## 8. Batches

1. Contract single-source in the **target** form: constants pinned in
   `dispatch-validate.py` (no `reuses`, no `role`), `session-init.py` renders
   the GATE_NOTICE from them + regression pin + tests/hooks.md v7 section +
   02-protocol §6 numbering gap.
2. `feature_id` rename + worktree create idempotency (+ tests, same batch) +
   CLI reduced to `worktree`/`doctor` (index/memory/init deleted, legacy
   index.json ignored) + session-init `bootstrap_runtime` removed +
   SubagentStart deleted (hook file, hooks.json entry, tests, docs).
3. One-sentence isolation wording in `01-judgment.md` §1.11 and the SKILL.md
   invariants; decomposition/parallelism wording in the SKILL.md routing
   section (port dsh's check: unsure → parallel, serial needs a stated
   reason); back-port the four-line resume template and the DONE/STUCK report
   states.
4. Deletions + `references/` consolidation + `DEVLOG.md` rationale (the file
   was seeded 2026-10-03 with the migrated dev memory) + doctor git rewrite +
   README drift fixes.
5. Version 1.3.0 across the **two** manifests (`.claude-plugin/plugin.json`,
   `.codex-plugin/plugin.json` — marketplace.json carries no version field) +
   new `CHANGELOG.md` + first git tag.

Every batch ends with `tests/run.sh` green.

## 9. Resolved (owner decisions — rev 2)

- **Version: 1.3.0.** Two version-bearing manifests, not three.
- **No state file**: `.orch-lite/` is never created; blocked-why is recorded
  only on request, by the owner, outside any mechanism.
- **Package fields**: `feature_id` / `objective` / `acceptance_criteria`;
  `role` and `reuses` deleted; `description == feature_id` binding kept
  (zcode-verified); worktree shape/existence checks ported (dsh-validated).
- **Contract single-source, no new files**: constants in
  `dispatch-validate.py`, GATE_NOTICE rendered from them by `session-init.py`.
- **Parallelism by default** across independent features (dsh's decomposition
  check, prose only): disjoint files + no named dependency → parallel; serial
  needs a stated reason; unsure → parallel.
- **SubagentStart deleted** (owner decision 2026-10-03): never-validated
  Codex adaptation, untestable by the owner; the gate's handbook pointer
  makes the hook redundant, so it goes instead of shrinking.
- **worktree create idempotent** — a code change, not a doc note.
- **Isolation stays prose discipline** — one-sentence mechanical criterion,
  no gate; misjudgement costs one worktree.
- **memory**: file kept as dev doc, child-facing references removed.
- **README**: drift fixed (4 spots), not rewritten, not frozen.
- No write gate and no dispatch-depth gate; `feature_id` replaces `task_id`.
