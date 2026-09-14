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
- v5 dispatch gate (same block-and-re-send loop):
  - no `registry` field in the package → deny (add a registered id from
    agents.json, or explicit null with a `registry_reason` string)
  - registry id not found in agents.json → deny, listing the valid ids
  - registry null without a non-empty `registry_reason` string → deny
  - prompt lacks the handbook-first instruction (no line telling the child
    to read skills/orch-lite-executor/SKILL.md first) → deny
  - agents.json missing or corrupt (only consulted when the package names a
    registry id) → deny; the message says the next session start recreates
    it from the bundled default (hooks/agents.default.json) or how to
    restore it manually
- otherwise         → allow (silent exit 0)

agents.json is resolved from the process cwd (hooks run with the session's
project cwd), i.e. the project-root registry that session-init bootstraps.

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
from typing import List, Optional, Tuple

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

# ---- v5 dispatch gate ----

# The dispatch package must carry a `registry` field: either a registered id
# from agents.json, or explicit null plus a `registry_reason` string.
MISSING_REGISTRY_REASON = (
    "Dispatch package is missing the `registry` field: add \"registry\": "
    "\"<id>\" (a registered agent id from agents.json) or \"registry\": null "
    "with a non-empty \"registry_reason\" string explaining why no registered "
    "agent fits; re-send the call with the registry field added"
)

UNKNOWN_REGISTRY_TMPL = (
    "Dispatch package names registry id %r, which is not in agents.json; "
    "valid ids: %s. Re-send with a registered id, or \"registry\": null plus "
    "a \"registry_reason\" string"
)

BAD_REGISTRY_TYPE_REASON = (
    "Dispatch package field `registry` must be a string (a registered id "
    "from agents.json) or null (with a non-empty `registry_reason` string); "
    "re-send with the registry field fixed"
)

MISSING_REGISTRY_REASON_TEXT_REASON = (
    "Dispatch package has \"registry\": null but no usable \"registry_reason\": "
    "add a non-empty string explaining why no registered agent fits; re-send "
    "with registry_reason added"
)

# Handbook-first: the prompt must tell the child which file to read first.
HANDBOOK_PATH = "skills/orch-lite-executor/SKILL.md"

MISSING_HANDBOOK_REASON = (
    "Dispatch is missing the handbook-first instruction: the prompt's first "
    "instruction to the child must tell it to read " + HANDBOOK_PATH + " "
    "(e.g. 'MANDATORY FIRST ACTION: read " + HANDBOOK_PATH + " (your "
    "handbook)'); re-send the call with that line added"
)

AGENTS_JSON_BROKEN_TMPL = (
    "agents.json at the project root is missing or corrupt (%s), so the "
    "registry id cannot be verified. Fix: the next session start recreates it "
    "from the bundled default (hooks/agents.default.json via the "
    "session-init bootstrap), or restore it manually by copying "
    "hooks/agents.default.json to agents.json and editing; re-send the "
    "dispatch afterwards"
)


def load_registry_ids() -> Tuple[Optional[List[str]], Optional[str]]:
    """(ids, None) when agents.json parses with an agents[] list of objects
    carrying string ids; (None, human-reason) when missing/corrupt."""
    path = Path.cwd() / "agents.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None, "file not found: %s" % path
    except Exception as exc:
        return None, "unreadable at %s: %s" % (path, type(exc).__name__)
    agents = data.get("agents") if isinstance(data, dict) else None
    if not isinstance(agents, list):
        return None, "no agents[] list at %s" % path
    ids = [
        a.get("id") for a in agents
        if isinstance(a, dict) and isinstance(a.get("id"), str)
    ]
    return ids, None


def evaluate_registry(package) -> Tuple[bool, str]:
    """Gate the package's `registry` field. Returns (allowed, reason)."""
    if "registry" not in package:
        return False, MISSING_REGISTRY_REASON
    registry = package["registry"]
    if registry is None:
        reason = package.get("registry_reason")
        if not isinstance(reason, str) or not reason.strip():
            return False, MISSING_REGISTRY_REASON_TEXT_REASON
        return True, ""
    if not isinstance(registry, str) or not registry.strip():
        return False, BAD_REGISTRY_TYPE_REASON
    ids, err = load_registry_ids()
    if ids is None:
        return False, AGENTS_JSON_BROKEN_TMPL % err
    if registry not in ids:
        return False, UNKNOWN_REGISTRY_TMPL % (registry, ", ".join(ids) or "(none)")
    return True, ""


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

    allowed, reason = evaluate_registry(package)
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
