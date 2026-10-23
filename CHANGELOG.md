# Changelog

## 1.3.2 (2026-10-20)

### Changed
- **Routing converged to three states: `chat`, `task`, `resume`.** The
  retired `orchestration` state is gone — single-task, multi-task and complex
  dependencies are all handled by `task`, which is judged in a fixed order
  (pure conversation → an existing child agent to continue → a delegated
  executor). The routing line is followed by the orchestration declaration
  (`任务 @branch`, `[A, B]`, `A → B`, `[A, B] → C`, `[A → C, B → D]`), so
  parallelism and dependencies are stated explicitly instead of being encoded
  in a separate routing state. Each task shows its branch.
- **Isolation is now by construction: every dispatched write task runs in its
  own worktree.** The retired rule ("dispatch into the primary tree when
  nothing else is running") is removed. A dispatched read-only task needs no
  worktree — it writes nothing. The main agent prepares the worktree before
  the dispatch; if the preparation fails, the dispatch stops and the problem
  is reported — there is no fallback to writing in the primary tree. The main
  agent's own bookkeeping (branch creation, integration merges, the worktree
  CLI) is not a dispatched write task and stays in the primary tree.
- **The Agent tool's `description` is no longer bound to `feature_id`.** The
  description describes the task; it is not an internal task identifier.
  `DESCRIPTION_BINDING`, its validation and its error message are deleted
  from `hooks/dispatch-validate.py`, and the SessionStart GATE_NOTICE no
  longer mentions the binding. Resume stays a platform concern — the skill
  states the intent, not the underlying mechanism.
- **The executor's git bootstrap is bounded, and enforced by code.** It now
  reuses an existing repository first (via `git rev-parse --show-toplevel`) and
  never re-initializes inside a repository subdirectory. A repository is
  initialized only when the project root is unambiguous and nothing would be
  overwritten; `.gitignore` keeps its existing content and gains the
  `.worktrees/` rule only when it is missing; the user's existing project
  files are never staged or committed to manufacture a baseline. An unclear
  project root stops the executor and reports — it no longer initializes a
  repository by guesswork. (These rules moved into the `repo` command — see
  below; the executor handbook now verifies its workspace instead of
  hand-rolling a bootstrap.)
- **The CLI resolves the repository root instead of trusting the current
  directory.** `PROJECT_ROOT` was `Path.cwd()`, so a CLI call from a
  repository subdirectory created the worktree in the wrong place. It is now
  the repository's MAIN working tree (resolved through
  `git worktree list --porcelain`, with `--show-toplevel` as a fallback), so
  create / list / remove / merge all act on the right repository from any
  subdirectory. Outside any repository the CLI fails with an explicit error
  and creates nothing — it never guesses a project root and never initializes
  a repository. A failed `git worktree add` no longer leaves a stray feature
  branch behind, and its message states that the write task must not be
  dispatched.
- **The Git-init rules are now code-enforced by a new `repo` CLI command.**
  The plan's rules were prose in the executor handbook; they are now the
  behaviour of `scripts/orch-lite repo` (idempotent, runs before
  `worktree create`): an existing repository is always reused (the main
  working tree is the root — a nested repository is never created); a
  repository is initialized only when the project root is unambiguous (the
  directory holds files, no parent directory holds a repository, and it is
  not a workspace of existing child repositories); `.gitignore` keeps its
  content and gains the `.worktrees/` rule plus a secret safety net
  (`.env*`, `*.pem`, `*.p12`, `id_rsa*`, `id_ed25519*`) only when missing;
  the user's project files ARE the baseline (staged with `git add -A`), so
  a work area checks them out and every subsequent edit is trackable — a
  baseline of `.gitignore` alone left worktrees empty of user code; an
  ambiguous project root (an empty directory, a workspace of child
  repositories) is reported, not guessed. The executor handbook now
  *verifies* the workspace it was given instead of hand-rolling a
  bootstrap.
- **The Git-init rules also had to move earlier in the flow.** With the
  worktree now prepared by the main agent *before* the dispatch, the
  repository must already exist at that point — but the bootstrap still
  lived in the executor handbook, where it ran too late. `repo` closes the
  gap: the main agent runs it as part of the isolation preparation.
- **A worktree holds the committed tree only.** Files that are not
  committed yet do not exist inside a new worktree, so the write task would
  find them missing. `worktree create` now reports the uncommitted paths in
  the primary tree instead of letting the child discover the gap mid-task.
- **The dispatch gate resolves the worktree path against the repository
  root**, not the process cwd. A session started in a repository
  subdirectory used to be denied ("worktree does not exist") even though the
  worktree existed at the root — the same bug class the CLI had. The deny
  reason now names the project root and states that a write task must have
  its isolation workspace before it is dispatched.

### Added
- **New `repo` CLI command** — the code-level guarantee behind the Git-init
  rules (see Changed above). Idempotent; runs before `worktree create`.
- Executor handbook workspace guard: immediately before the git bootstrap step,
  the child lists the immediate subdirectories (skipping `node_modules`,
  `.venv`, `venv`, `vendor`, `target`, `build`, `dist`, `.git`, `.cache`). If any
  contains a `.git`, the directory is a workspace of existing repos, not a
  project: do NOT `git init` -- report the project paths to the main session and
  stop. Rationale: `git rev-parse --is-inside-work-tree` only looks UP the tree,
  so bootstrapping at a workspace root succeeds and wraps the existing child
  repos in a new parent repo -- the same family as the stray `/tmp/.git`
  incident recorded in `DEVLOG.md`. Handbook rule only; no CLI/hook code.
  (Superseded by the `repo` command, which now enforces the same rule in
  code; the handbook keeps a verification step instead of a hand-rolled
  bootstrap.)

### Removed
- The `description == feature_id` gate check and the `orchestration` routing
  state.

### Fixed
- **`doctor`'s main-violation detection was blind to the current feature_id
  shape (P0).** The scan matched `^[a-z]+-[0-9]{8}-[0-9]+$` — the pre-1.3.0
  `{role}-{YYYYMMDD}-{seq}` task_id shape. Since 1.3.0 the feature_id is a
  slug (`^[a-z0-9][a-z0-9._-]*$`), so the pattern matched NOTHING and a
  child committing straight to `main` was reported as `doctor: all clear`:
  a branch-discipline violation passed the hygiene scan. The scan now uses
  the feature_id slug rule and separates a child's commit from a human's by
  three signals instead of one: a merge commit (more than one parent) is
  never a violation; the repository owner's own git identity is never a
  violation; and the slug shape alone is not enough — a plain name like
  `linyujian` matches the slug rule too. On this repository the scan now
  reports the 26 real direct-to-main commits and flags no human commit.
- **The `doctor` test could not catch the above.** It used the OLD author
  shape, so it passed while the real shape failed. A new case
  (`case_doctor_slug_author`) covers the current slug shape, the no-false-
  positive case (a human's own commit) and the legitimate `--no-ff`
  integration case.
- **Dead code in `tests/run.sh`:** `case_1_10` was defined twice — the first
  definition called an undefined `fresh_git_repo` and carried the deleted
  `task_id` / `role` fields, and the second silently overwrote it. The
  dead definition is removed.

### Changed
- **Dangling references removed.** `N1` / `N11` / `P1–P8` pointed at
  documents that live outside the repository (`PROGRAMS/docs/lo-meta/`), so
  a reader of the plugin could not resolve them. The two `N1` mentions now
  state the rule inline, and `docs/maintenance.md` no longer cites the
  open-question numbering.

## 1.3.1 (2026-10-04)

### Added
- Agent reuse across follow-ups: when a follow-up order for `feature/<fid>`
  finds the owning child agent still alive, the main agent resumes that agent
  via SendMessage with a four-line SUPERSEDES order (`SUPERSEDES` /
  `STILL VALID` / `ACCEPTANCE` / `READ FIRST`) instead of dispatching a fresh
  one. A fresh hand-off is used only when the agent is worn, stuck, failed, or
  its id was lost. This adds a fourth routing state
  (`[routing] resume <fid> (agent_<id>)`) and codifies the
  `agent_<id>` id-handle convention: dispatch receipts report the agent id,
  and it is the only durable handle to a live child agent.

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
