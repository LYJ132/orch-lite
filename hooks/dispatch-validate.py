#!/usr/bin/env python3
"""PreToolUse hook: validate the fenced-JSON dispatch package in the prompt.

The platform's Agent tool_input carries only description / prompt /
subagent_type / run_in_background — the dispatch package lives inside the
prompt TEXT as a fenced block, so the old marker-key sniffing never fired.
v3 is HARD ENFORCEMENT: every Agent call from the main session is a
dispatch. Scans the prompt for a fenced JSON block (```json ... ```;
fallback: any fenced block whose content contains "task_id") and validates:

- no fenced block   → deny (re-send with a ```json fenced block containing
  task_id/role/objective/acceptance_criteria (+optional feature_id))
- run_in_background is not exactly true → deny (dispatches must be
  background so the main session returns to the user immediately)
- invalid JSON      → deny ("dispatch fenced block is not valid JSON")
- missing required fields (task_id / role / objective / acceptance_criteria)
                    → deny, listing them
- feature_id present but not ^[a-z0-9][a-z0-9._-]*$
                    → deny (it names the feature/<feature_id> branch)
- otherwise         → allow

instance_id is RETIRED: no longer a required or valid field; if present it is
ignored. Malformed stdin or any internal error → silent exit 0 — the hook
never blocks a call by accident.
"""
import json
import re
import sys

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


def find_dispatch_block(text: str) -> str | None:
    """First ```json block; else the first fenced block mentioning task_id."""
    blocks = FENCE_RE.findall(text or "")
    for lang, content in blocks:
        if lang.lower() == "json":
            return content
    for _lang, content in blocks:
        if "task_id" in content:
            return content
    return None


def evaluate(prompt: str, run_in_background) -> dict:
    """Validate the dispatch package found in `prompt`.

    Returns {"decision": "allow"} or {"decision": "deny", "reason": ...}.
    """
    block = find_dispatch_block(prompt)
    if block is None:
        return {"decision": "deny", "reason": NO_BLOCK_REASON}

    if run_in_background is not True:
        return {"decision": "deny", "reason": FOREGROUND_REASON}

    try:
        package = json.loads(block)
    except Exception:
        return {"decision": "deny", "reason": INVALID_JSON_REASON}
    if not isinstance(package, dict):
        package = {}  # valid JSON but not an object → all required fields missing

    missing = [f for f in REQUIRED_FIELDS if f not in package]
    if missing:
        return {
            "decision": "deny",
            "reason": (
                "Dispatch package violates N15: a dispatch must carry these "
                "4 required fields (task_id, role, objective, "
                "acceptance_criteria; instance_id is retired; optional: "
                "feature_id). Missing: " + ", ".join(missing)
            ),
        }

    feature_id = package.get("feature_id")
    if feature_id is not None and not FEATURE_ID_RE.match(str(feature_id)):
        return {
            "decision": "deny",
            "reason": (
                "feature_id must match [a-z0-9][a-z0-9._-]* (used as the "
                "feature/<feature_id> branch name)"
            ),
        }

    return {"decision": "allow"}


def main() -> int:
    try:
        raw = sys.stdin.read()
        event = json.loads(raw) if raw.strip() else {}
        if not isinstance(event, dict):
            return 0

        tool_name = event.get("tool_name") or ""
        if tool_name and tool_name not in ("Agent", "Task"):
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

        decision = evaluate(prompt, tool_input.get("run_in_background"))
        print(json.dumps(decision))
    except Exception:
        return 0  # malformed stdin / internal error → never block
    return 0


if __name__ == "__main__":
    sys.exit(main())
