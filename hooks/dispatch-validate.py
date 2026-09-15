#!/usr/bin/env python3
"""PreToolUse hook: validate the fenced-JSON dispatch package in the prompt.

ZCode hook contract (exit-code style — the safe one): stdout is parsed as
STRICT JSON, so this hook prints NOTHING on stdout. Passing = exit 0 with
empty output; denying = exit 2 (ZCode's deny for PreToolUse) with the reason
as a one-line human message on STDERR. The legacy {"decision": ...} JSON
shape is Claude-Code vocabulary: ZCode's output schema only accepts
decision approve|block, so every legacy deny/allow JSON failed validation,
the run was marked hook.run.failed and the gate silently passed everything
through (fail-open forever). The exit-code path needs no output schema at
all.

v4 validation logic is IDENTICAL to v3 — only the output channel changed.
Every Agent call from the main session is a dispatch. Scans the prompt for a
fenced JSON block (```json ... ```; fallback: any fenced block whose content
contains "task_id") and validates:

- no fenced block   → deny (re-send with a ```json fenced block containing
  task_id/role/objective/acceptance_criteria (+optional feature_id))
- run_in_background is not exactly true → deny (dispatches must be
  background so the main session returns to the user immediately)
- invalid JSON      → deny ("dispatch fenced block is not valid JSON")
- missing required fields (task_id / role / objective / acceptance_criteria)
                    → deny, listing them
- feature_id present but not ^[a-z0-9][a-z0-9._-]*$
                    → deny (it names the feature/<feature_id> branch)
- v6 feature-branch binding (packages WITH a feature_id only; packages
  without one are unaffected):
  - refs/heads/feature/<feature_id> absent (git rev-parse in the session
    cwd) → deny with exactly two fixes: (1) NEW feature → include in the
    package an explicit instruction for the child to create branch
    feature/<feature_id> from the current mainline HEAD; (2) otherwise fix
    the feature_id. Git unavailable / cwd not a repo → fail-open pass.
- v7 reuse loop (the guaranteed-reuse gate; packages WITHOUT a feature_id
  are unaffected):
  - package has a feature_id AND .orch-lite/index.json (project cwd) has
    prior entries for that feature_id, but the package carries no `reuses`
    field → deny ONCE with a digest of those entries (task ids, statuses,
    one-line summaries) and the instruction to re-send with a `reuses`
    field listing the task_ids the main session has read. The hook is
    stateless, so the requirement is uniform: every dispatch whose feature
    has index history must carry `reuses` — the digest denial teaches it.
  - `reuses` present → every listed task_id must exist in the index; an
    unknown id → deny naming the valid ones.
  - feature_id with NO index history → passes without the loop (no
    `reuses` required).
- prompt lacks the handbook-first instruction (no line telling the child
  to read skills/orch-lite-executor/SKILL.md first) → deny
- otherwise         → allow (silent exit 0)

The index is resolved from the process cwd (hooks run with the session's
project cwd), i.e. the .orch-lite/ runtime that session-init bootstraps.

instance_id is RETIRED: no longer a required or valid field; if present it is
ignored. Malformed stdin or any internal error → fail-open: exit 0 with a
one-line diagnostic on stderr — the hook never blocks a call by accident.

Requires Python >= 3.9 (guarded below: older interpreters get a one-line
stderr message and fail-open exit 0, never a traceback).
"""

import sys

if sys.version_info < (3, 9):
    # One-line human message, then fail-open: a hook that cannot run must
    # never block the session. `%`-formatting: this line must also parse on
    # pre-3.6 interpreters (no f-strings before the guard).
    sys.stderr.write(
        "[orch-lite] dispatch-validate requires Python >= 3.9 "
        "(found %d.%d); failing open (call allowed). Upgrade Python or run "
        "via `uv run --python 3.12 <script>`.\n" % sys.version_info[:2]
    )
    sys.exit(0)

import json
import re
from pathlib import Path
from typing import Optional, Tuple

REQUIRED_FIELDS = ["task_id", "role", "objective", "acceptance_criteria"]

# Optional field: names the feature/<feature_id> worktree branch, so it must
# be a safe branch-name component.
FEATURE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")

# A fenced block: ```<lang>\n<content>``` (lang optional, content non-greedy
# up to the first closing fence). Inline ```spans``` without a newline after
# the language tag never match.
FENCE_RE = re.compile(r"```([A-Za-z0-9_-]*)[ \t]*\r?\n(.*?)```", re.DOTALL)

INVALID_JSON_REASON = "dispatch fenced block is not valid JSON"

NO_BLOCK_REASON = (
    "Every Agent call from the main session is a dispatch: re-send the call "
    "with a ```json fenced block in the prompt containing task_id / role / "
    "objective / acceptance_criteria (+ optional feature_id)"
)

FOREGROUND_REASON = (
    "Dispatches must run in the background (run_in_background=true) so the "
    "main session returns to the user immediately; re-send with "
    "run_in_background set to exactly true"
)

# ---- v7 reuse loop ----
# A package carrying a feature_id must NOT skip what the feature line already
# knows: when the index has prior entries for that feature_id, the package
# must carry a `reuses` field listing the task_ids the main session has read
# before composing. The hook is stateless, so the requirement is uniform —
# every dispatch whose feature has index history needs `reuses`; the first
# dispatch is denied exactly once with a digest of the prior entries, which
# teaches the requirement while surfacing the reusable history.

REUSES_REQUIRED_TMPL = (
    "Feature %s already has tasks in the index (.orch-lite/index.json), so "
    "this dispatch must reuse them rather than re-derive. Prior entries:\n%s\n"
    "Read their conclusions (index show / feature-branch history), then "
    "re-send the dispatch with a \"reuses\" field listing the task_ids you "
    "have read (e.g. \"reuses\": [\"<task_id>\"]). Every dispatch whose "
    "feature has index history must carry \"reuses\"."
)

UNKNOWN_REUSES_TMPL = (
    "Dispatch package field \"reuses\" names unknown task_id(s): %s. Valid "
    "index task_ids: %s. Re-send with \"reuses\" listing only valid ids"
)

BAD_REUSES_TYPE_REASON = (
    "Dispatch package field \"reuses\" must be a non-empty list of index "
    "task_ids (strings); re-send with \"reuses\" fixed"
)


def load_index_tasks() -> Optional[dict]:
    """Index task map from .orch-lite/index.json in the process cwd, or None
    when the index is missing/unreadable (nothing to gate against — fail-open
    for the reuse loop, exactly like the other environment gates)."""
    path = Path.cwd() / ".orch-lite" / "index.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    tasks = data.get("tasks") if isinstance(data, dict) else None
    return tasks if isinstance(tasks, dict) else None


def feature_digest(tasks: dict, feature_id: str) -> str:
    """One line per prior entry of the feature: task_id, status, summary."""
    lines = []
    for tid, entry in tasks.items():
        if not isinstance(entry, dict):
            continue
        if entry.get("feature_id") != feature_id:
            continue
        summary = entry.get("output") or entry.get("objective") or ""
        summary = " ".join(str(summary).split())[:100]
        lines.append("- %s | status=%s | %s" % (
            tid, entry.get("status", "?"), summary or "(no summary)"))
    return "\n".join(lines) if lines else "(no entries)"


def evaluate_reuse(package, feature_id) -> Tuple[bool, str]:
    """Gate a feature-bound package against the index's prior feature work."""
    if feature_id is None:
        return True, ""  # unbound dispatch: unaffected
    tasks = load_index_tasks()
    if not tasks:
        return True, ""  # no index: passes without the loop
    has_history = any(
        isinstance(e, dict) and e.get("feature_id") == str(feature_id)
        for e in tasks.values()
    )
    if not has_history:
        return True, ""  # no prior entries for THIS feature: no loop
    reuses = package.get("reuses")
    if reuses is None:
        digest = feature_digest(tasks, str(feature_id))
        return False, REUSES_REQUIRED_TMPL % (feature_id, digest)
    if (
        not isinstance(reuses, list)
        or not reuses
        or not all(isinstance(r, str) and r.strip() for r in reuses)
    ):
        return False, BAD_REUSES_TYPE_REASON
    unknown = [r for r in reuses if r not in tasks]
    if unknown:
        return False, UNKNOWN_REUSES_TMPL % (
            ", ".join(unknown), ", ".join(tasks.keys()))
    return True, ""

# Handbook-first: the prompt must tell the child which file to read first.
HANDBOOK_PATH = "skills/orch-lite-executor/SKILL.md"

MISSING_HANDBOOK_REASON = (
    "Dispatch is missing the handbook-first instruction: the prompt's first "
    "instruction to the child must tell it to read " + HANDBOOK_PATH + " "
    "(e.g. 'MANDATORY FIRST ACTION: read " + HANDBOOK_PATH + " (your "
    "handbook)'); re-send the call with that line added"
)

# ---- v6 feature-branch binding ----
# A package carrying a feature_id binds the dispatch to the feature line's
# recorded state (branch feature/<feature_id> + index + memory). When the
# branch does not exist at dispatch time, related work would fragment onto a
# fresh line, so the gate denies with exactly two fixes: declare the branch
# creation (new feature) or fix the feature_id (existing feature).

BRANCH_MISSING_TMPL = (
    "Branch feature/%s does not exist in this repository, so the dispatch "
    "cannot bind to that feature line's recorded state (branch + index + "
    "memory). Fix in exactly one of two ways: (1) if this is a NEW feature, "
    "include in the package an explicit instruction for the child to create "
    "branch feature/%s from the current mainline HEAD (e.g. 'git checkout "
    "-b feature/%s' from mainline HEAD) before its first write; "
    "(2) otherwise fix the feature_id to the existing feature line "
    "(see `python3 scripts/multi-agent index list`)"
)


def feature_branch_exists(feature_id: str) -> Tuple[Optional[bool], Optional[str]]:
    """(True, None) when refs/heads/feature/<fid> exists; (False, None) when
    it does not; (None, diagnostic) when git itself is unusable (fail-open —
    a hook must never block a call because git is missing or cwd is not a
    repo)."""
    import subprocess

    ref = "refs/heads/feature/%s" % feature_id
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "--verify", "--quiet", ref],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=10,
        )
    except Exception as exc:
        return None, "git unavailable: %r" % (exc,)
    if proc.returncode == 0:
        return True, None
    if "not a git repository" in (proc.stderr or b"").decode("utf-8", "replace"):
        return None, "cwd is not a git repository"
    return False, None


def evaluate_feature_binding(feature_id) -> Tuple[bool, str]:
    """Gate a package's feature_id against the repository's branch state."""
    if feature_id is None:
        return True, ""  # generic (unbound) dispatch: unaffected
    exists, diag = feature_branch_exists(str(feature_id))
    if exists is True or exists is None:
        return True, ""  # bound, or git unusable -> fail-open
    return False, BRANCH_MISSING_TMPL % (feature_id, feature_id, feature_id)


def find_dispatch_block(text: str) -> Optional[str]:
    """First ```json block; else the first fenced block mentioning task_id."""
    blocks = FENCE_RE.findall(text or "")
    for lang, content in blocks:
        if lang.lower() == "json":
            return content
    for _lang, content in blocks:
        if "task_id" in content:
            return content
    return None


def evaluate(prompt, run_in_background):
    """Validate the dispatch package found in `prompt`.

    Returns (allowed, reason): (True, "") when the call may proceed,
    (False, reason) with a human-readable deny reason otherwise.
    """
    block = find_dispatch_block(prompt)
    if block is None:
        return False, NO_BLOCK_REASON

    if run_in_background is not True:
        return False, FOREGROUND_REASON

    try:
        package = json.loads(block)
    except Exception:
        return False, INVALID_JSON_REASON
    if not isinstance(package, dict):
        package = {}  # valid JSON but not an object → all required fields missing

    missing = [f for f in REQUIRED_FIELDS if f not in package]
    if missing:
        return False, (
            "Dispatch package violates N15: a dispatch must carry these "
            "4 required fields (task_id, role, objective, "
            "acceptance_criteria; instance_id is retired; optional: "
            "feature_id). Missing: " + ", ".join(missing)
        )

    feature_id = package.get("feature_id")
    if feature_id is not None and not FEATURE_ID_RE.match(str(feature_id)):
        return False, (
            "feature_id must match [a-z0-9][a-z0-9._-]* (used as the "
            "feature/<feature_id> branch name)"
        )

    # v6 binding: a feature_id must point at an existing feature branch, or
    # the package must carry the create-branch instruction (new feature).
    allowed, reason = evaluate_feature_binding(feature_id)
    if not allowed:
        return False, reason

    allowed, reason = evaluate_reuse(package, feature_id)
    if not allowed:
        return False, reason

    # Handbook-first: some line in the prompt must point the child at its
    # handbook path (the dispatch MUST block carries it verbatim).
    if HANDBOOK_PATH not in (prompt or ""):
        return False, MISSING_HANDBOOK_REASON

    return True, ""


def main():
    try:
        raw = sys.stdin.read()
        event = json.loads(raw) if raw.strip() else {}
        if not isinstance(event, dict):
            return 0

        tool_name = event.get("tool_name") or ""
        if tool_name and tool_name not in ("Agent", "Task", "spawn_agent"):
            return 0  # the matcher scopes this hook; belt-and-braces only

        tool_input = event.get("tool_input") or {}
        if not isinstance(tool_input, dict):
            return 0

        # The dispatch package lives in the prompt text; description is the
        # fallback carrier.
        prompt = tool_input.get("prompt")
        if not isinstance(prompt, str) or not prompt:
            prompt = tool_input.get("description") or ""
        if not isinstance(prompt, str):
            prompt = str(prompt)

        allowed, reason = evaluate(prompt, tool_input.get("run_in_background"))
        if allowed:
            return 0  # pass: empty stdout, exit 0 (ZCode exit-code contract)
        # deny: reason on STDERR, exit 2 (ZCode's deny for PreToolUse).
        sys.stderr.write(reason.rstrip() + "\n")
        return 2
    except Exception as exc:
        # Malformed stdin / internal error → fail-open, with a diagnostic.
        sys.stderr.write(
            "[orch-lite] dispatch-validate internal error, failing open "
            "(call allowed): %r\n" % (exc,)
        )
        return 0


if __name__ == "__main__":
    sys.exit(main())
