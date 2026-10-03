#!/usr/bin/env python3
"""PreToolUse hook: validate the fenced-JSON dispatch package in the prompt.

Target contract (1.3.0, single-sourced here): the gate checks the package's
SHAPE — a fenced-JSON block present and valid, the required fields
(feature_id / objective / acceptance_criteria), the background flag, the
handbook-pointer line, the `description == feature_id` binding, and the
optional `worktree` checks (shape + directory existence). There is no
`role` (the dispatch tool IS the role) and no `reuses` (reuse is
`git log feature/<fid>`). The feature_id slug rule keeps it a safe
branch/worktree name.

This module is ALSO the single source of the gate contract: hooks/session-init.py
imports these constants (importlib — the filename carries a hyphen) and renders
the SessionStart GATE_NOTICE from them. Keep every fact the notice states in a
constant here; do not restate rules in strings elsewhere.

ZCode hook contract (exit-code style — the safe one): stdout is parsed as
STRICT JSON, so this hook prints NOTHING on stdout. Passing = exit 0 with
empty output; denying = exit 2 (ZCode's deny for PreToolUse) with a one-line
human reason on STDERR. Malformed stdin or any internal error → fail-open:
exit 0 with a one-line diagnostic on stderr — the hook never blocks a call
by accident. Requires Python >= 3.9 (guarded below: older interpreters get
a one-line stderr message and fail-open exit 0, never a traceback).
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

# ---- Gate contract constants (single source; session-init renders from these) ----

# Required dispatch-package fields. `role` and `reuses` are deleted: the
# dispatch tool (Agent vs Explore) is the role; reuse is `git log feature/<fid>`.
REQUIRED_FIELDS = ("feature_id", "objective", "acceptance_criteria")

# The Agent tool's description binds the agent for resume: it must equal the
# package's feature_id (one string, one meaning).
DESCRIPTION_BINDING = "description == feature_id"

# The background flag: dispatches are background calls, exactly true.
BACKGROUND_FLAG = "run_in_background"

# Handbook path: the prompt's first instruction must point the child here.
HANDBOOK_PATH = "skills/orch-lite-executor/SKILL.md"

# Slug rule: feature_id names the feature/<fid> branch and the
# .worktrees/<fid> worktree, so it must be a safe name for both.
FEATURE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")

# Worktree convention: an optional package field naming a pre-created worktree.
WORKTREE_PREFIX = ".worktrees/"

# A fenced block: ```<lang>\n<content>``` (lang optional, content non-greedy
# up to the first closing fence). Inline ```spans``` without a newline after
# the language tag never match.
FENCE_RE = re.compile(r"```([A-Za-z0-9_-]*)[ \t]*\r?\n(.*?)```", re.DOTALL)

NO_BLOCK_REASON = (
    "Dispatch rejected: no ```json fenced block found in the prompt. The "
    "dispatch package format is defined in " + HANDBOOK_PATH + " and the "
    "orch-lite SKILL.md Dispatch Package template — re-send the call with "
    "the fenced-JSON package embedded in the prompt"
)

FOREGROUND_REASON = (
    "Dispatch rejected: " + BACKGROUND_FLAG + " must be exactly true "
    "(dispatches are background calls) — see the Dispatch Package template "
    "in the orch-lite SKILL.md"
)

INVALID_JSON_REASON = "dispatch fenced block is not valid JSON"

MISSING_HANDBOOK_REASON = (
    "Dispatch rejected: the prompt never points the child at its handbook. "
    "The first instruction must tell it to read " + HANDBOOK_PATH + " — see "
    "the Dispatch Package template in the orch-lite SKILL.md"
)


def _missing_fields_reason(missing) -> str:
    return (
        "Dispatch package missing required field(s): "
        + ", ".join(missing)
        + " — see the Dispatch Package template in the orch-lite SKILL.md"
    )


def _slug_reason(feature_id: str) -> str:
    return (
        "Dispatch rejected: feature_id %r must match "
        "^[a-z0-9][a-z0-9._-]*$ (it names the feature/<feature_id> branch "
        "and the .worktrees/<feature_id> worktree)" % (feature_id,)
    )


def _binding_reason(description, feature_id) -> str:
    return (
        "Dispatch rejected: the Agent tool's description must equal the "
        "package's feature_id (binding: description == feature_id, so the "
        "agent is resumable by feature) — description %r != feature_id %r"
        % (description, feature_id)
    )


def _worktree_shape_reason(value) -> str:
    return (
        "Dispatch rejected: the package's worktree field must be "
        + WORKTREE_PREFIX
        + "<feature_id> (the concurrency worktree created for this feature) "
        "— got %r" % (value,)
    )


def _worktree_missing_reason(value) -> str:
    return (
        "Dispatch rejected: worktree %r does not exist in the project cwd — "
        "create it first (`worktree create --feature-id <fid>`), or drop the "
        "field to dispatch into the primary tree" % (value,)
    )


def find_dispatch_block(text: str) -> Optional[str]:
    """First ```json block; else the first fenced block mentioning feature_id."""
    blocks = FENCE_RE.findall(text or "")
    for lang, content in blocks:
        if lang.lower() == "json":
            return content
    for _lang, content in blocks:
        if "feature_id" in content:
            return content
    return None


def evaluate(prompt, run_in_background, description=None, cwd=None):
    """Validate the dispatch package found in `prompt`.

    Returns (allowed, reason): (True, "") when the call may proceed,
    (False, reason) with a human-readable deny reason otherwise.
    `description` is the Agent tool_input description (the binding target);
    `cwd` is the project root the optional worktree path is resolved against.
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
        return False, _missing_fields_reason(missing)

    feature_id = package.get("feature_id")
    if not isinstance(feature_id, str) or not FEATURE_ID_RE.match(feature_id):
        return False, _slug_reason(feature_id)

    # Handbook-first: some line in the prompt must point the child at its
    # handbook path (the dispatch template carries it as the first
    # instruction).
    if HANDBOOK_PATH not in (prompt or ""):
        return False, MISSING_HANDBOOK_REASON

    # description == feature_id binding: the platform description is how the
    # agent is found again for continuation; it must carry the feature id.
    if description != feature_id:
        return False, _binding_reason(description, feature_id)

    # Optional worktree checks: the value must match the feature's worktree
    # shape and the directory must already exist (created by the CLI at T1).
    worktree = package.get("worktree")
    if worktree is not None:
        expected = WORKTREE_PREFIX + feature_id
        if worktree != expected:
            return False, _worktree_shape_reason(worktree)
        base = Path(cwd) if cwd is not None else Path.cwd()
        if not (base / worktree).is_dir():
            return False, _worktree_missing_reason(worktree)

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
        # binding field (compared against the package's feature_id).
        prompt = tool_input.get("prompt")
        if not isinstance(prompt, str) or not prompt:
            prompt = tool_input.get("description") or ""
        if not isinstance(prompt, str):
            prompt = str(prompt)
        description = tool_input.get("description")

        allowed, reason = evaluate(
            prompt, tool_input.get("run_in_background"), description
        )
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
