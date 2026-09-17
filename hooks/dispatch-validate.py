#!/usr/bin/env python3
"""PreToolUse hook: validate the fenced-JSON dispatch package in the prompt.

Minimal gate (lightweight-core): the gate checks ONLY the package's shape —
a fenced-JSON block present and valid, the required fields (task_id /
objective / acceptance_criteria; role is optional, defaulting to impl),
run_in_background=true, and the handbook-pointer line. feature_id is
optional plain metadata: binding is a convention (one feature one branch),
not hook-enforced — the gate no longer checks branch existence, the index,
or a `reuses` field. Deny messages point at the handbook/template instead
of restating the rules.

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
from typing import Optional, Tuple

REQUIRED_FIELDS = ["task_id", "objective", "acceptance_criteria"]

# A fenced block: ```<lang>\n<content>``` (lang optional, content non-greedy
# up to the first closing fence). Inline ```spans``` without a newline after
# the language tag never match.
FENCE_RE = re.compile(r"```([A-Za-z0-9_-]*)[ \t]*\r?\n(.*?)```", re.DOTALL)

HANDBOOK_PATH = "skills/orch-lite-executor/SKILL.md"

NO_BLOCK_REASON = (
    "Dispatch rejected: no ```json fenced block found in the prompt. The "
    "dispatch package format is defined in " + HANDBOOK_PATH + " and the "
    "orch-lite SKILL.md Dispatch Package template — re-send the call with "
    "the fenced-JSON package embedded in the prompt"
)

FOREGROUND_REASON = (
    "Dispatch rejected: run_in_background must be exactly true (dispatches "
    "are background calls) — see the Dispatch Package template in the "
    "orch-lite SKILL.md"
)

INVALID_JSON_REASON = "dispatch fenced block is not valid JSON"

MISSING_HANDBOOK_REASON = (
    "Dispatch rejected: the prompt never points the child at its handbook. "
    "The first instruction must tell it to read " + HANDBOOK_PATH + " — see "
    "the Dispatch Package template in the orch-lite SKILL.md"
)


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
            "Dispatch package missing required field(s): "
            + ", ".join(missing)
            + " — see the Dispatch Package template in the orch-lite SKILL.md"
        )

    # Handbook-first: some line in the prompt must point the child at its
    # handbook path (the dispatch template carries it as the first
    # instruction).
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
