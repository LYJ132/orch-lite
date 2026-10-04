# Hook Tests

Two ZCode hooks ship with the skill, deployed user-scope in
`~/.zcode/cli/config.json` (`hooks.enabled: true`). Scripts live in
`hooks/`, invoked by absolute path (hook context has no `${SKILL_DIR}`).

Run each line below from the skill root to verify behavior:

```bash
HOOKS=hooks
```

> Executable version of this matrix: `bash tests/run.sh` (self-contained, no network; ends with a per-case PASS/FAIL summary and `ALL PASS`, exit 0).

---

## Hook 1: `dispatch-validate.py` — PreToolUse, matcher `Agent|Task`, deny

v4 (2026-09-12) speaks ZCode's **exit-code hook contract**: the platform
parses hook stdout as strict JSON, and the legacy
`{"decision":"allow"/"deny","reason":...}` shape is Claude-Code vocabulary
(ZCode's schema accepts only `decision: approve|block`), so every legacy
output failed validation and the gate silently passed everything through.
v4 prints NOTHING on stdout: **pass = exit 0 with empty stdout; deny = exit
2 with the reason as a one-line human message on stderr; malformed stdin /
internal error = fail-open (exit 0, one-line stderr diagnostic)**.

v4 validates the **fenced-JSON dispatch package inside the prompt text** with
HARD ENFORCEMENT (logic identical to v3): the platform's Agent `tool_input`
only carries `description` / `prompt` / `subagent_type` /
`run_in_background`, so the dispatch package lives in the prompt as a ```json
fenced block. The hook takes the first ```json block (fallback: any fenced
block whose content contains `task_id`); with no fenced block the call is
**DENIED** — every Agent call from the main session is a dispatch and must be
re-sent with the fenced block. Calls whose `run_in_background` is not exactly
`true` are also **DENIED** — dispatches must be background so the main
session returns to the user immediately.

Enforces the **1.3.0 target contract** (constants single-sourced in
`hooks/dispatch-validate.py`; `hooks/session-init.py` renders the SessionStart
GATE_NOTICE from the same constants): required fields are `feature_id` /
`objective` / `acceptance_criteria` — `role` and `reuses` are DELETED (the
dispatch tool IS the role; reuse is `git log feature/<fid>`) and `task_id` is
gone (`feature_id` is the one key). The `feature_id` slug rule
(`^[a-z0-9][a-z0-9._-]*$`) is enforced — it names the `feature/<feature_id>`
branch and the `.worktrees/<feature_id>` worktree. The Agent tool's
`description` must equal the package's `feature_id` (the binding that makes
the agent resumable by feature). An optional `worktree` field must equal
`.worktrees/<feature_id>` and the directory must already exist.
`instance_id` stays RETIRED — not required, ignored when present.

| # | Input | Expected | Actual |
|---|---|---|---|
| 1.1 | valid fenced JSON (all 3 required fields) + `run_in_background: true` + matching `description` | exit 0, empty stdout | ✅ |
| 1.2 | fenced JSON missing `objective` (+ background) | exit 2, stderr: `...required field(s): objective` | ✅ |
| 1.3 | fenced JSON + `feature_id: "Bad_Branch!"` (+ background) | exit 2, stderr: `...must match ^[a-z0-9][a-z0-9._-]*$ (it names the feature/<feature_id> branch and the .worktrees/<feature_id> worktree)` | ✅ |
| 1.4 | prompt without any fenced block | exit 2, stderr: `no ```json fenced block found` | ✅ |
| 1.5 | fenced block containing malformed JSON (+ background) | exit 2, stderr: `dispatch fenced block is not valid JSON` | ✅ |
| 1.6 | fenced JSON incl. legacy `instance_id` field (+ background) | exit 0, empty stdout (instance_id retired, ignored) | ✅ |
| 1.7 | real-shaped Agent `tool_input` (description/prompt/subagent_type/run_in_background), no fenced JSON | exit 2 (no-block reason on stderr) | ✅ |
| 1.8 | malformed JSON on stdin | fail-open: exit 0, empty stdout, one-line stderr diagnostic | ✅ |
| 1.9 | `tool_name: Task` alias, valid fenced JSON + background | exit 0, empty stdout | ✅ |
| 1.10 | slug-legal `feature_id: "payment"` + matching description | exit 0, empty stdout | ✅ |
| 1.11 | valid fenced JSON but `run_in_background` absent | exit 2, stderr: `run_in_background must be exactly true` | ✅ |
| 1.12 | valid fenced JSON but `run_in_background: false` | exit 2 (foreground reason on stderr, as 1.11) | ✅ |
| 1.15 | prompt without the handbook-first instruction (no `skills/orch-lite-executor/SKILL.md` line) | exit 2, stderr names the handbook path | ✅ |
| 1.25 | fenced JSON without `feature_id` | exit 2, stderr: `...required field(s): feature_id` | ✅ |
| 1.26 | `description` differs from the package's `feature_id` | exit 2, stderr names the `description == feature_id` binding | ✅ |
| 1.27 | `description` absent from `tool_input` | exit 2 (binding cannot hold) | ✅ |
| 1.28 | `worktree` field of the wrong shape (`.worktrees/some-other-fid`) | exit 2, stderr: `worktree field must be .worktrees/<feature_id>` | ✅ |
| 1.29 | `worktree` shape right but the directory does not exist in the cwd | exit 2, stderr: `does not exist` | ✅ |
| 1.30 | `worktree` shape right + directory exists (sandbox cwd) | exit 0, empty stdout | ✅ |
| ROUTE | SKILL.md Step 0: routing line restated as a MUST; self-repair clause and the `[routing]` states (chat / task / orchestration / resume) intact | assertions on the Request Routing section | ✅ |
| GATE | session-init output: the `--- Dispatch gate (hook-enforced) ---` notice | rendered from the gate constants; names NO deleted field (`reuses` / `task_id` / `role`), names every gate constant | ✅ |

Hard enforcement (1.4, 1.7, 1.11–1.12) is the design point: the fenced
block is the only dispatch marker that actually reaches the hook, and its
absence blocks the call instead of passing through; foreground calls are
blocked so the main session always returns to the user immediately. When a
fenced block + background is present it is a dispatch and must satisfy the
target contract: 3 required fields (1.1–1.2), a slug-legal `feature_id`
(1.3, 1.10), the `description == feature_id` binding (1.26–1.27), the
optional-worktree checks (1.28–1.30), and retired `instance_id` ignored (1.6).

v3 behavior retained (2026-09-12 decision): the hook validates the
fenced-JSON package only — the MUST template is a prompt-shape requirement
owned by SKILL.md's "Dispatch Package (MUST template)" section, not a hook
validation rule (the handbook pointer is the one prompt-shape check the gate
duplicates).

---

## Hook 2: `dangling-occupancy-check.py` — RETIRED (deleted)

The PostToolUse hook was deleted in the hook sweep (方案 A) and its
registration was removed from `~/.zcode/cli/config.json`. Its duties moved:

- **Dirty-worktree refusal** — already enforced by the CLI: `multi-agent
  worktree remove --task-id` refuses a worktree with uncommitted changes.
- **Stale-worktree marking / main-commit checks** — now live in the
  `multi-agent doctor` subcommand (WP6c-1): dirty worktrees, stale worktrees
  (index cross-read) and task_id-authored commits on main, always exit 0;
  `worktree list` additionally flags `[stale]` rows via the same cross-read.

No PostToolUse hook is registered anymore; only SessionStart
(`session-init.py`) and PreToolUse (`dispatch-validate.py`) remain.

---

## Hook 3: `session-init.py` — SessionStart, verbatim contracts + gate notice + doctor probe

The hook assembles one `{"additionalContext": ...}` payload — attention-critical
contracts first, the doctor probe last. It writes NOTHING: 1.3.0 has no state
file (`.orch-lite/` is never created; the runtime bootstrap of older versions
is deleted).

1. **5 Invariants (memorize)** — the "## 5 Invariants (memorize)" section
   extracted verbatim from SKILL.md (the behavioral iron rules, seen before
   any routing/dispatch guidance);
2. **Request Routing** — the "## Request Routing" section extracted verbatim
   from SKILL.md;
3. **Dispatch Package (MUST template)** — the "## Dispatch Package (MUST
   template)" section extracted verbatim from SKILL.md;
4. **Dispatch gate (hook-enforced)** — the GATE_NOTICE, rendered from the
   gate contract constants single-sourced in `dispatch-validate.py`
   (importlib; the load failure path degrades to a generic notice naming no
   field — the regression pin is the `GATE` row in Hook 1's matrix);
5. **Health** — a probe of `multi-agent doctor`, captured but *tolerated for
   absence*: non-zero exit, empty output, or argparse "invalid choice" /
   "unrecognized" text → the section is skipped silently (the hook stays
   usable against CLI copies that predate doctor). When doctor exists, its
   output (the running version, `dirty:` / `stale:` / `main-violation:`
   findings, the merged-branch state, or `doctor: all clear`) appears
   verbatim.

The three contract sections come from SKILL.md only (single source of truth —
the hook holds no second copy; the extraction table in the hook just names
heading prefixes and labels). Iron-rule marker tags inside these sections
(`<EXTREMELY-IMPORTANT>` blocks) ride along verbatim — the injection shape
itself is unchanged.

All paths derive from `__file__` (zero hardcoded absolute paths), so the
skill is portable; any error still yields exactly one additionalContext
line with exit 0 — the hook never crashes the session.

| # | Setup | Expected | Actual |
|---|---|---|---|
| 3.3 | SKILL.md without a "## Request Routing" section | graceful fallback line "(contract section missing in SKILL.md)" in additionalContext for that section, no crash (exit 0), Health still works | ✅ |
| 3.4 | CLI copy predating the doctor subcommand | Health skipped silently (graceful-absence probe), the other sections intact, exit 0 | ✅ |
| 3.5 | SKILL.md with all three contract sections (current shape) | additionalContext contains "--- 5 Invariants (memorize) (from SKILL.md) ---", "--- Request Routing (from SKILL.md) ---" and "--- Dispatch Package (MUST template) (from SKILL.md) ---", each section byte-identical to the SKILL.md text (verified programmatically: `extract_contract` output vs the slice between headings) | ✅ |
| 3.6 | SKILL.md without the "## Dispatch Package (MUST template)" section | fallback line for that section only, no crash, exit 0 | ✅ |
| 3.7 | session cwd unwritable (chmod 555 dir; e.g. a root-owned 755 project) | hook exits 0; nothing is created (no state file to bootstrap); the words `Traceback`, `File "`, `PermissionError` never appear in the payload; contract sections still inject | ✅ |
| 3.8 | same unwritable cwd, raw `doctor` call | `doctor` → `(doctor: not a repo)`, exit 0, cwd untouched | ✅ |

> Note (2026-09-12, impl-20260912-04/07): rows 3.3–3.6 are executable —
> `bash tests/run.sh` covers them (3.5 asserts byte-identity via sha256;
> 3.3/3.6 run in mktemp sandboxes under a `GIT_CEILING_DIRECTORIES`
> ceiling so a stray repo at a TMPDIR ancestor cannot leak in). Rows 3.7/3.8
> are vacuously green when run as root.

The injected contract is byte-identical to the SKILL.md section (verified
programmatically), so editing SKILL.md is the only way the routing rule
changes — the hook never drifts from it.

---

## Platform sections (hooks.json manifest)

The shared `hooks/hooks.json` manifest carries only the
platform-accepted fields (`description` if used, `hooks`); which entries
belong to which platform lives here, since JSON cannot carry comments:

| Entries | Platform section |
|---|---|
| PreToolUse (`dispatch-validate.py`) | ZCode: full dispatch gate |
| SessionStart | Codex + ZCode: context injection |

> Incident lesson (hotfix of the 1.2.0 `_sections`/`_comment` markers):
> Codex validates hooks.json strictly — no extra keys; platform sectioning
> lives in docs, not in the manifest. An unknown top-level key makes Codex
> Desktop reject the whole file ("unknown field `_sections`, expected
> `description` or `hooks`"), so no manifest keys beyond the schema, ever.

---

## Setup notes

- **Python >= 3.9 required** by both hooks and `scripts/multi-agent`. Older
  interpreters get a one-line human message on stderr — hooks fail-open
  (exit 0, session unblocked), the CLI exits non-zero. uv users can run any
  script via `uv run --python 3.12 <script>` (documentation only; there is
  no dependency to install).
- The `multi-agent` CLI script was given its executable bit
  (`chmod +x scripts/multi-agent`). Without it, `process`-type hooks fail with
  `Permission denied` — and any three-copy sync (workspace → `~/.zcode` /
  `~/.agents`) must preserve permission bits (`cp -p`), not just file content.
- Config-file hooks are disabled by default; `~/.zcode/cli/config.json` sets
  `hooks.enabled: true`.
- Registered hooks: **SessionStart** (`session-init.py`) and **PreToolUse**
  (`dispatch-validate.py`, matcher `Agent|Task`). The PostToolUse entry was
  removed when `dangling-occupancy-check.py` was retired (Hook 2 above); the
  SubagentStart entry and `subagent-start.py` were deleted outright in 1.3.0
  (owner decision 2026-10-03 — a never-runtime-validated Codex adaptation;
  the dispatch gate's handbook pointer makes it redundant). No other hook
  files or registrations exist.
- Both hooks are idempotent, read-only or self-limiting, and degrade
  gracefully (empty output / silent) on malformed input — they never block
  the session.
