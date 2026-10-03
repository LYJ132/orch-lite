# Changelog

## 1.3.0 (2026-10-03)

Minimal, platform-agnostic release: **no state file** — every fact lives in
git, in the conversation, or in the platform's own affordances. Back-ports
the decisions validated in `dsh-orch-lite` and deletes everything that did
not pay for itself. Full design rationale: `docs/plan-1-3-0.md` and
`DEVLOG.md`.

### Added
- Four-line resume template (SUPERSEDES / STILL VALID / ACCEPTANCE / READ
  FIRST) for cross-session continuation with a fresh agent on the same
  `feature_id` (back-ported from dsh as new text).
- `DONE <fid>` / `STUCK <fid>` report states for child executors; STUCK is a
  clean end state — the main session informs the user, no write anywhere.
- Idempotent `worktree create`: an existing registered `.worktrees/<fid>/` is
  reused (real path printed, `reused:` + note, exit 0); it refuses only when
  the branch is checked out elsewhere (`feature busy`); writes no state
  (back-ported from dsh).
- Parallelism-by-default decomposition check: disjoint file sets and no named
  dependency → separate features, dispatched in parallel; serial needs a
  stated reason; unsure → parallel (prose discipline, no gate).
- One-sentence isolation rule (prose discipline, no gate): dispatch into the
  primary tree only when nothing else is running — no unreturned dispatch
  this session and a clean `git worktree list`; otherwise a worktree.
- Git bootstrap steps in the executor handbook (the child ensures a repo
  exists; replaces the retired `init` group).
- Dedicated worktree test coverage (create / idempotent reuse / feature-busy
  / list / remove / merge) — worktree is 1.3.0's load-bearing wall.

### Changed
- `feature_id` replaces `task_id` everywhere: branch `feature/<fid>`,
  worktree `.worktrees/<fid>/`, dispatch package field, Agent tool
  `description` (the gate now enforces `description == feature_id`), commit
  author. One string, one meaning.
- Dispatch package (final): required `feature_id` / `objective` /
  `acceptance_criteria`; optional `worktree`. `role` and `reuses` are
  deleted — the dispatch tool (Agent vs Explore) IS the role; reuse is
  `git log feature/<fid>`.
- Gate contract single-sourced in `hooks/dispatch-validate.py` (the
  enforcer): required fields, handbook path, background flag, slug rule,
  description binding, worktree shape/existence rules, every deny message.
  `session-init.py` renders the SessionStart GATE_NOTICE from those
  constants via importlib — the 1.2.1 notice/requirement drift is structurally
  impossible now, pinned by a regression test.
- `doctor` reads git only: running version, worktree hygiene (dirty +
  stale-when-merged via `git worktree list` and merged-branch state), the
  main-violation first-parent scan. `--compare-dir` install-drift check
  removed (~110 lines).
- References consolidated: rules are canonical in SKILL.md, rationale moved
  to DEVLOG.md; `references/01-judgment.md` deleted.

### Removed
- **No state file**: `.orch-lite/` is never created — no `index.json`, no
  `features.json`, no `memory.json`, no `hook-policy.json`. A legacy
  `.orch-lite/` is ignored, not migrated. Blocked-why is told to the user,
  recorded only on request (its loss self-heals via re-dispatch).
- The `index`, `memory` and `init` CLI groups; the CLI is `worktree` +
  `doctor` only.
- `session-init` runtime bootstrap (the hook writes nothing at session
  start).
- **SubagentStart hook** (owner decision 2026-10-03): `subagent-start.py`,
  its hooks.json entry, tests, docs — a never-runtime-validated Codex
  adaptation; the dispatch gate's handbook pointer makes it redundant.
