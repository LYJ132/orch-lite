#!/usr/bin/env python3
"""SessionStart hook: bootstrap the multi-agent runtime and inject context.

The skill must travel as a unit, so every path here derives from this file's
own location (`__file__`) — zero hardcoded absolute paths. On session start:

1. Consume the stdin event JSON (best-effort; its content is not needed).
2. Idempotently run `<skill>/scripts/multi-agent init` (the CLI only creates
   files that don't exist; it never overwrites).
3. Run `multi-agent index list` and probe `multi-agent doctor` (Health). A
   non-zero doctor exit with argparse-style "invalid choice"/"unrecognized"
   output means the subcommand is absent and the section is skipped silently;
   an empty output is likewise skipped.
4. Extract the "## 5 Invariants (memorize)", "## Request Routing" and
   "## Dispatch Package (MUST template)" sections verbatim from SKILL.md
   (single source of truth; the hook holds no second copy of the contracts)
   and inject each as its own labeled part.
5. Assemble the payload attention-first: the three SKILL.md contract sections
   open it (iron rules before routing before dispatch), the runtime state
   sections (Bootstrap, Agent Index, Health) close it.

Fail-soft rendering: a CLI-derived section whose CLI call fails (non-zero
exit, a "bootstrap skipped: ..." line, or traceback-shaped output — e.g. the
session cwd is unwritable) collapses to ONE human line,
'--- <Section> (skipped: <reason>) ---'. The words "Traceback", 'File "' and
"PermissionError" never survive into the payload, so an unwritable cwd can no
longer poison the session context with a raw traceback.

Graceful degradation: any error → best-effort output; the hook always exits 0
and prints exactly one {"additionalContext": ...} JSON — it never crashes the
session. (That shape is ZCode-valid: stdout JSON is parsed against a schema
that accepts a top-level additionalContext string.)

Requires Python >= 3.9 (guarded below: older interpreters get a one-line
stderr message and fail-open exit 0, never a traceback).
"""
# Python >= 3.9 guard, first thing after the docstring: an interpreter too
# old to run the hook must print one human line and fail-open (exit 0), not
# traceback. `%`-formatting only — this file must also PARSE on pre-3.6
# interpreters (no f-strings before the guard).
import sys

if sys.version_info < (3, 9):
    sys.stderr.write(
        "[orch-lite] session-init requires Python >= 3.9 "
        "(found %d.%d); failing open (session continues without injected "
        "context). Upgrade Python or run via `uv run --python 3.12 "
        "<script>`.\n" % sys.version_info[:2]
    )
    sys.exit(0)

import json
import re
import subprocess
from pathlib import Path
from typing import List, Tuple

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
# source of truth — the hook holds no second copy. Tuple order is injection
# order: the iron rules come first so they are read before the routing and
# dispatch sections. Contract sections as a block precede the runtime state
# sections (Bootstrap / Agent Index / Health), which render last.
CONTRACT_SECTIONS = (
    ("## 5 Invariants (memorize)", "5 Invariants (memorize)"),
    ("## Request Routing (main agent's first decision)", "Request Routing"),
    ("## Dispatch Package (MUST template)", "Dispatch Package (MUST template)"),
)
MISSING_CONTRACT = "(contract section missing in SKILL.md)"

# argparse marks a not-yet-existing subcommand with these strings.
DOCTOR_ABSENT_MARKERS = ("invalid choice", "unrecognized")

# ---- Bootstrap (runs before/alongside the CLI init; pure + idempotent) ----
# The runtime state dir is `.orch-lite/` (dot prefix = tool-managed runtime).
# Flat layout: `.orch-lite/index.json` + `.orch-lite/memory.json`. The hook
# NEVER probes or touches any legacy directory — a user's project may contain
# its own `multi-agent/` directory, which is none of this plugin's business.
STATE_DIR = Path.cwd() / ".orch-lite"

INDEX_SKELETON = '{"tasks": {}}'
MEMORY_SKELETON = '{"common_knowledge": {}, "experiences": [], "task_patterns": {}, "contracts": []}'

# Fixed visibility line: the dispatch gate must be seen from session start.
GATE_NOTICE = (
    "Dispatch gate: every Agent dispatch is hook-validated — its package must "
    "carry the required fields (task_id / role / objective / "
    "acceptance_criteria, run_in_background=true) and its first instruction "
    "must tell the child to read skills/orch-lite-executor/SKILL.md; when the "
    "package's feature already has index entries, it must also carry a "
    "`reuses` field listing the index task_ids the main session has read; "
    "dispatches missing any of this are blocked before they run."
)


def _write_if_absent(path: Path, content: str) -> bool:
    """Create `path` with `content` only when it does not exist."""
    if path.exists():
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return True


def bootstrap_runtime() -> List[str]:
    """Idempotent, never-destructive runtime bootstrap. Returns human lines.

    - `.orch-lite/` created when missing (default `memory.json` skeleton,
      empty `index.json` — flat layout).
    Nothing existing is ever modified or deleted. Any OSError collapses to
    one human line — never a traceback.
    """
    lines: List[str] = []
    try:
        created = _write_if_absent(STATE_DIR / "index.json", INDEX_SKELETON)
        created |= _write_if_absent(STATE_DIR / "memory.json", MEMORY_SKELETON)
        if created:
            lines.append("bootstrap: .orch-lite/ created (fresh skeleton)")
    except OSError as exc:
        reason = getattr(exc, "strerror", None) or type(exc).__name__
        lines.append("bootstrap skipped: %s" % reason)
    return lines

# Traceback machinery words that must never reach the payload (an unwritable
# cwd once injected a raw PermissionError traceback via the CLI's stderr).
TRACEBACK_MARKERS = ("Traceback", 'File "', "PermissionError")
# The fail-soft CLI announces a degraded bootstrap with this line prefix.
BOOTSTRAP_SKIP_PREFIX = "bootstrap skipped: "
# Final line of a raw Python traceback for an OS error, e.g.
# "PermissionError: [Errno 13] Permission denied: '/home/x/multi-agent'" --
# reduced to path + reason, the exception machinery itself is dropped.
_ERRNO_EXC_RE = re.compile(
    r"^[A-Za-z_][\w.]*(?:Error|Exception): \[Errno \d+\] (.+): '(.+)'$"
)


def _has_traceback_markers(text: str) -> bool:
    return any(marker in text for marker in TRACEBACK_MARKERS)


def _skip_detail(out: str) -> str:
    """The reason clause of the CLI's own fail-soft line, or '' when absent."""
    for line in (out or "").splitlines():
        line = line.strip()
        if line.startswith(BOOTSTRAP_SKIP_PREFIX):
            return line[len(BOOTSTRAP_SKIP_PREFIX):]
    return ""


def _failure_detail(out: str, code: int) -> str:
    """One human clause from a failed CLI run; traceback text never survives.

    A raw traceback (older CLI, or a crash on stderr) is reduced to its final
    exception line's path + reason; a human one-liner (e.g. python's "can't
    open file ...") passes through as-is; anything traceback-shaped or empty
    becomes a generic clause.
    """
    for line in reversed((out or "").splitlines()):
        m = _ERRNO_EXC_RE.match(line.strip())
        if m:
            return "cannot create %s: %s" % (m.group(2), m.group(1))
    for line in reversed((out or "").splitlines()):
        line = line.strip()
        if line and not _has_traceback_markers(line):
            return line[:160]
    return "CLI failed (exit %d)" % code


def _render_cli(label: str, args: List[str], default_body: str,
                code: int, out: str) -> str:
    """Render one CLI-derived section with fail-soft fallback.

    Success → '--- <label> (multi-agent <args>) ---' plus the CLI output.
    Failure (non-zero exit, a bootstrap-skip line, or traceback-shaped text)
    → the single human line '--- <label> (skipped: <reason>) ---'.
    """
    out = (out or "").strip()
    skip = _skip_detail(out)
    if code == 0 and skip == "" and not _has_traceback_markers(out):
        return "--- %s (multi-agent %s) ---\n%s" % (
            label, " ".join(args), out or default_body
        )
    detail = skip if skip else _failure_detail(out, code)
    return "--- %s (skipped: %s) ---" % (label, detail)


def read_stdin_event() -> dict:
    """Consume the SessionStart event JSON; anything unreadable → {}."""
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def run_cli(args: List[str], timeout: int = 15) -> Tuple[int, str]:
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
    """`multi-agent doctor` output as the Health section, or '' when there is
    nothing to report.

    Absence (argparse usage/error text on a non-zero exit) or empty output is
    skipped silently — doctor may be absent on an older install. A hard
    failure renders the human '--- Health (skipped: ...) ---' fallback line.
    """
    code, out = run_cli(["doctor"])
    out = (out or "").strip()
    if not out:
        return ""
    if code != 0 and any(marker in out for marker in DOCTOR_ABSENT_MARKERS):
        return ""
    return _render_cli("Health", ["doctor"], "", code, out)


def extract_contract(heading_prefix: str, lines: List[str]) -> str:
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


def contract_sections() -> List[Tuple[str, str]]:
    """(label, verbatim section text) pairs for every CONTRACT_SECTIONS entry."""
    try:
        lines = SKILL_MD.read_text(encoding="utf-8").splitlines()
    except Exception:
        lines = []
    return [
        (label, extract_contract(prefix, lines))
        for prefix, label in CONTRACT_SECTIONS
    ]


def build_context() -> str:
    """Assemble the single additionalContext payload (compact).

    Attention-critical content first: the SKILL.md contract sections (iron
    rules, routing, dispatch) open the payload; the runtime state sections
    (Bootstrap, Agent Index, Health) close it.
    """
    code, init_out = run_cli(["init"])
    index_code, index_out = run_cli(["index", "list"])

    parts = ["[orch-lite]"]
    for label, section in contract_sections():
        parts.append(f"--- {label} (from SKILL.md) ---\n{section}")
    parts.append("--- Dispatch gate (hook-enforced) ---\n" + GATE_NOTICE)
    bootstrap_lines = bootstrap_runtime()
    if bootstrap_lines:
        parts.append("--- Bootstrap (hook) ---\n" + "\n".join(bootstrap_lines))
    parts.append(
        _render_cli("Bootstrap", ["init"], "(no output)", code, init_out)
    )
    parts.append(
        _render_cli("Agent Index", ["index", "list"], "(empty)", index_code, index_out)
    )
    health = health_section()
    if health:
        parts.append(health)
    return "\n\n".join(parts)


def main() -> int:
    event = read_stdin_event()  # consume the event payload; content not needed
    try:
        context = build_context()
        if event.get("hook_event_name") == "SessionStart":
            payload = {
                "hookSpecificOutput": {
                    "hookEventName": "SessionStart",
                    "additionalContext": context,
                }
            }
        else:
            payload = {"additionalContext": context}
        print(json.dumps(payload))
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
