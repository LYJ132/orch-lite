#!/usr/bin/env python3
"""SessionStart hook: bootstrap the multi-agent runtime and inject context.

The skill must travel as a unit, so every path here derives from this file's
own location (`__file__`) — zero hardcoded absolute paths. On session start:

1. Consume the stdin event JSON (best-effort; its content is not needed).
2. Idempotently run `<skill>/scripts/multi-agent init` (the CLI only creates
   files that don't exist; it never overwrites).
3. Run `multi-agent index list` and inject the agent index.
4. Probe `multi-agent doctor` — captured but tolerated: the subcommand does
   not exist yet (a future task adds it). A non-zero exit or argparse-style
   "invalid choice"/"unrecognized" output means "absent" and the Health
   section is skipped silently; a successful non-empty run becomes "Health".
5. Extract the "## Request Routing" and "## Dispatch Package (MUST template)"
   sections verbatim from SKILL.md (single source of truth; the hook holds no
   second copy of the contracts) and inject each as its own labeled part.

Graceful degradation: any error → best-effort output; the hook always exits 0
and prints exactly one {"additionalContext": ...} JSON — it never crashes the
session.
"""
# Lazy annotations: builtin-generic / `X | None` annotations must never be
# evaluated at import time, or an interpreter older than 3.9/3.10 turns the
# hook into an uncaught traceback before main() (fail-soft contract).
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

# Skill root: this hook lives in <skill>/hooks/, so the parent's parent is the
# skill root. Everything (CLI, SKILL.md) is resolved from here — the skill
# works no matter where it is installed.
SKILL_DIR = Path(__file__).resolve().parent.parent
CLI = SKILL_DIR / "scripts" / "multi-agent"
# Plugin layout keeps SKILL.md at skills/orch-lite/SKILL.md; the legacy flat
# skill layout had it at the root. Prefer the plugin layout, fall back to flat.
_SKILL_MD_CANDIDATES = (
    SKILL_DIR / "skills" / "orch-lite" / "SKILL.md",
    SKILL_DIR / "SKILL.md",
)
SKILL_MD = next(
    (p for p in _SKILL_MD_CANDIDATES if p.is_file()), _SKILL_MD_CANDIDATES[0]
)

# Sections injected verbatim from SKILL.md: (heading prefix, label). Each runs
# from its heading to the next '---' or '## ' heading. SKILL.md is the single
# source of truth — the hook holds no second copy.
CONTRACT_SECTIONS = (
    ("## Request Routing", "Request Routing"),
    ("## Dispatch Package (MUST template)", "Dispatch Package (MUST template)"),
)
MISSING_CONTRACT = "(contract section missing in SKILL.md)"

# argparse marks a not-yet-existing subcommand with these strings.
DOCTOR_ABSENT_MARKERS = ("invalid choice", "unrecognized")


def read_stdin_event() -> dict:
    """Consume the SessionStart event JSON; anything unreadable → {}."""
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def run_cli(args: list[str], timeout: int = 15) -> tuple[int, str]:
    """Run the skill CLI via the current Python interpreter (no exec bit
    required), returning (returncode, output). Never raises."""
    try:
        # Run via sys.executable so the CLI never needs the executable bit.
        proc = subprocess.run(
            [sys.executable, str(CLI), *args],
            capture_output=True, text=True, timeout=timeout,
        )
        out = (proc.stdout or "").strip() or (proc.stderr or "").strip()
        return proc.returncode, out
    except Exception as exc:
        return 1, f"(hook error: {exc})"


def health_section() -> str:
    """`multi-agent doctor` output, or '' while the subcommand is absent.

    Absence (non-zero exit, empty output, or argparse usage/error text) is
    skipped silently — doctor is added by a future task.
    """
    code, out = run_cli(["doctor"])
    if code != 0 or not out:
        return ""
    if any(marker in out for marker in DOCTOR_ABSENT_MARKERS):
        return ""
    return out


def extract_contract(heading_prefix: str, lines: list[str]) -> str:
    """Extract one section (heading → next '---' / '## ') from `lines` verbatim.

    Falls back to a one-line warning if missing — never crashes.
    """
    start = None
    for i, line in enumerate(lines):
        if line.strip().startswith(heading_prefix):
            start = i
            break
    if start is None:
        return MISSING_CONTRACT

    section = [lines[start]]
    for line in lines[start + 1:]:
        stripped = line.strip()
        if stripped == "---" or stripped.startswith("## "):
            break
        section.append(line)
    contract = "\n".join(section).strip()
    return contract or MISSING_CONTRACT


def contract_sections() -> list[tuple[str, str]]:
    """(label, verbatim section text) pairs for every CONTRACT_SECTIONS entry."""
    try:
        lines = SKILL_MD.read_text().splitlines()
    except Exception:
        lines = []
    return [
        (label, extract_contract(prefix, lines))
        for prefix, label in CONTRACT_SECTIONS
    ]


def build_context() -> str:
    """Assemble the single additionalContext payload (compact)."""
    _, init_out = run_cli(["init"])
    _, index_out = run_cli(["index", "list"])
    health = health_section()

    parts = [
        "[orch-lite]",
        f"--- Bootstrap (multi-agent init) ---\n{init_out or '(no output)'}",
        f"--- Agent Index (multi-agent index list) ---\n{index_out or '(empty)'}",
    ]
    if health:
        parts.append(f"--- Health (multi-agent doctor) ---\n{health}")
    for label, section in contract_sections():
        parts.append(f"--- {label} (from SKILL.md) ---\n{section}")
    return "\n\n".join(parts)


def main() -> int:
    read_stdin_event()  # consume the event payload; content not needed
    try:
        print(json.dumps({"additionalContext": build_context()}))
    except Exception:
        # Last-resort degradation: never crash the session.
        try:
            print(json.dumps({
                "additionalContext":
                    "[orch-lite] session-init degraded (internal error)."
            }))
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
