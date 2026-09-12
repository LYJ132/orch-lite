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

Enforces N15 (amended): a dispatch must carry 4 required fields
(`task_id` / `role` / `objective` / `acceptance_criteria`); the optional
`feature_id` must match `^[a-z0-9][a-z0-9._-]*$` (it names the
`feature/<feature_id>` branch). `instance_id` is RETIRED — not required,
ignored when present.

| # | Input | Expected | Actual |
|---|---|---|---|
| 1.1 | valid fenced JSON (all 4 required fields) + `run_in_background: true` | exit 0, empty stdout | ✅ |
| 1.2 | fenced JSON missing `objective` (+ background) | exit 2, stderr: `...Missing: objective` | ✅ |
| 1.3 | fenced JSON + `feature_id: "Bad_Branch!"` (+ background) | exit 2, stderr: `...feature_id must match [a-z0-9][a-z0-9._-]* (used as the feature/<feature_id> branch name)` | ✅ |
| 1.4 | prompt without any fenced block | exit 2, stderr: `Every Agent call from the main session is a dispatch: re-send the call with a ```json fenced block in the prompt containing task_id / role / objective / acceptance_criteria (+ optional feature_id)` | ✅ |
| 1.5 | fenced block containing malformed JSON (+ background) | exit 2, stderr: `dispatch fenced block is not valid JSON` | ✅ |
| 1.6 | fenced JSON incl. legacy `instance_id` field (+ background) | exit 0, empty stdout (instance_id retired, ignored) | ✅ |
| 1.7 | real-shaped Agent `tool_input` (description/prompt/subagent_type/run_in_background), no fenced JSON | exit 2 (no-block reason on stderr) — the case that was dead under v1's marker sniffing | ✅ |
| 1.8 | malformed JSON on stdin | fail-open: exit 0, empty stdout, one-line stderr diagnostic | ✅ |
| 1.9 | `tool_name: Task` alias, valid fenced JSON + background | exit 0, empty stdout | ✅ |
| 1.10 | fenced JSON + valid `feature_id: "payment"` + background | exit 0, empty stdout | ✅ |
| 1.11 | valid fenced JSON but `run_in_background` absent | exit 2, stderr: `Dispatches must run in the background (run_in_background=true) so the main session returns to the user immediately; re-send with run_in_background set to exactly true` | ✅ |
| 1.12 | valid fenced JSON but `run_in_background: false` | exit 2 (foreground reason on stderr, as 1.11) | ✅ |

Hard enforcement (1.4, 1.7, 1.11–1.12) is the v3 design point: the fenced
block is the only dispatch marker that actually reaches the hook, and its
absence now blocks the call instead of passing through; foreground calls are
blocked so the main session always returns to the user immediately. When a
fenced block + background is present it is a dispatch and must satisfy N15:
4 required fields (1.1–1.2), optional `feature_id` safe as a branch-name
component (1.3, 1.10), retired `instance_id` ignored (1.6).

v3 behavior retained (2026-09-12 decision): the hook validates the
fenced-JSON package only — the six-rule MUST template is a prompt-shape
requirement owned by SKILL.md's "Dispatch Package (MUST template)" section,
not a hook validation rule.

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

## Hook 3: `session-init.py` — SessionStart, v3: bootstrap + index + doctor probe + verbatim contracts

The v3 hook assembles one `{"additionalContext": ...}` payload with five
sections:

1. **Bootstrap** — idempotent `multi-agent init` (creates what's missing,
   overwrites nothing; also bootstraps git in a repo-less project);
2. **Agent Index** — `multi-agent index list` (flat task list), so principle
   3 ("recover minimal state") is automatic;
3. **Health** — a probe of `multi-agent doctor`, captured but *tolerated for
   absence*: non-zero exit, empty output, or argparse "invalid choice" /
   "unrecognized" text → the section is skipped silently (the hook stays
   usable against CLI copies that predate doctor). When doctor exists, its
   findings (`dirty:` / `stale:` / `main-violation:` lines, or
   `doctor: all clear`) appear verbatim;
4. **Request Routing** — the "## Request Routing" section extracted verbatim
   from SKILL.md;
5. **Dispatch Package (MUST template)** — the "## Dispatch Package (MUST
   template)" section extracted verbatim from SKILL.md.

Both contract sections come from SKILL.md only (single source of truth — the
hook holds no second copy; the extraction table in the hook just names
heading prefixes and labels).

All paths derive from `__file__` (zero hardcoded absolute paths), so the
skill is portable; any error still yields exactly one additionalContext
line with exit 0 — the hook never crashes the session.

| # | Setup | Expected | Actual |
|---|---|---|---|
| 3.1 | fresh project, no `multi-agent/` | creates the full tree (`index.json`, `memory/shared.json`, `comm/`; git bootstrapped when repo-less); all four memory sections present, index shows `Index is empty`, Health shows `doctor: all clear` | ✅ |
| 3.2 | project with a populated index / existing `multi-agent/` | re-runs init idempotently (no overwrite), shows the flat task list, injects the Request Routing section, Health reflects doctor (e.g. stale/dirty findings) | ✅ |
| 3.3 | SKILL.md without a "## Request Routing" section | graceful fallback line "(contract section missing in SKILL.md)" in additionalContext for that section, no crash (exit 0), init + index + Health still work | ✅ |
| 3.4 | CLI copy predating the doctor subcommand | Health skipped silently (graceful-absence probe), the other sections intact, exit 0 | ✅ |
| 3.5 | SKILL.md with both contract sections (current shape) | additionalContext contains both "--- Request Routing (from SKILL.md) ---" and "--- Dispatch Package (MUST template) (from SKILL.md) ---", each section byte-identical to the SKILL.md text (verified programmatically: `extract_contract` output vs the slice between headings) | ✅ |
| 3.6 | SKILL.md without the "## Dispatch Package (MUST template)" section | fallback line for that section only, no crash, exit 0 | ✅ |

> Note (2026-09-12, impl-20260912-04/07): rows 3.1–3.6 are executable —
> `bash tests/run.sh` covers them (3.5 asserts byte-identity via sha256;
> 3.1/3.2/3.3/3.6 run in mktemp sandboxes under a `GIT_CEILING_DIRECTORIES`
> ceiling so a stray repo at a TMPDIR ancestor cannot leak in).

The injected contract is byte-identical to the SKILL.md section (verified
programmatically), so editing SKILL.md is the only way the routing rule
changes — the hook never drifts from it.

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
  (`dispatch-validate.py`, matcher `Agent|Task`) only. The PostToolUse entry
  was removed when `dangling-occupancy-check.py` was retired (Hook 2 above);
  no other hook files or registrations exist.
- Both remaining hooks are idempotent, read-only or self-limiting, and degrade
  gracefully (empty output / silent) on malformed input — they never block
  the session.
