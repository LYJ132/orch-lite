#!/usr/bin/env python3
"""orch-lite SubagentStart hook (Codex).

allow -> {"hookSpecificOutput": {"hookEventName": "SubagentStart",
                                 "additionalContext": "..."}}
deny  -> {"continue": false, "stopReason": "...",
          "hookSpecificOutput": {"hookEventName": "SubagentStart"}}
any internal error -> allow silently (fail-open)
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HANDBOOK_LINE = ("[orch-lite SubagentStart] You are an orch-lite executor. "
                 "First action: read skills/orch-lite-executor/SKILL.md (your handbook); "
                 "check .orch-lite/memory.json contracts[] before any write.")

def load_policy(cwd):
    p = Path(cwd) / ".orch-lite" / "hook-policy.json"
    try:
        with p.open(encoding="utf-8") as f:
            data = json.load(f)
        return data.get("subagent_start", {}) if isinstance(data, dict) else {}
    except Exception:
        return {}  # no policy / broken policy -> zero rules, fail-open

def inside_git_repo(cwd):
    try:
        r = subprocess.run(["git", "-C", cwd, "rev-parse", "--is-inside-work-tree"],
                           capture_output=True, text=True, timeout=5)
        return r.returncode == 0 and r.stdout.strip() == "true"
    except Exception:
        return None  # git unavailable -> skip check (fail-open, like v6 binding)

def under_roots(path, roots):
    # normalize both sides: absolute + case-fold + separator normalization
    # (Windows mixed separators, relative paths, drive-letter case)
    norm = os.path.normcase(os.path.abspath(str(path)))
    return any(norm.startswith(os.path.normcase(os.path.abspath(str(r))))
               for r in roots)

def audit(cwd, decision, reason, data):
    rec = {"v": 1, "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
           "decision": decision, "reason": reason,
           "agent_id": data.get("agent_id"), "agent_type": data.get("agent_type"),
           "model": data.get("model"), "session_id": data.get("session_id"),
           "turn_id": data.get("turn_id"), "cwd": cwd}
    for target in (Path(cwd) / ".orch-lite" / "subagent-start.log",
                   Path.home() / ".orch-lite" / "hook-observe" / "subagent-start.log"):
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("a", encoding="utf-8") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        except OSError:
            pass

def main():
    try:
        data = json.load(sys.stdin)
        cwd = data.get("cwd") or ""
        if not cwd:
            return  # missing cwd -> allow, silent (fail-open)
    except Exception:
        return  # malformed stdin -> allow, silent

    policy = load_policy(cwd)
    reason = None
    if policy.get("require_git_repo"):
        ok = inside_git_repo(cwd)
        if ok is False:
            reason = "cwd is not inside a git work tree (orch-lite policy: require_git_repo)"
    if reason is None and policy.get("allowed_roots"):
        if not under_roots(cwd, policy["allowed_roots"]):
            reason = "cwd outside allowed_roots (orch-lite policy)"
    if reason is None and policy.get("blocked_roots"):
        if under_roots(cwd, policy["blocked_roots"]):
            reason = "cwd inside blocked_roots (orch-lite policy)"

    decision = "deny" if reason else "allow"
    audit(cwd, decision, reason, data)

    if decision == "deny":
        print(json.dumps({"continue": False, "stopReason": reason,
                          "hookSpecificOutput": {"hookEventName": "SubagentStart"}}))
        return
    if policy.get("inject_handbook", True):
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "SubagentStart",
            "additionalContext": HANDBOOK_LINE}}, ensure_ascii=False))
    # allow without injection: print nothing (continue defaults to true)

if __name__ == "__main__":
    main()
