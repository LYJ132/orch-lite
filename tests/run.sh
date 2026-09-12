#!/usr/bin/env bash
# tests/run.sh — executable counterpart of the manual matrix in tests/hooks.md.
#
# Self-contained: no network, no writes outside mktemp -d sandboxes (negative
# paths never touch the real multi-agent/ runtime state; running session-init
# inside the repo is idempotent by design — init creates-if-missing, list and
# doctor are pure reads).
#
# Usage: bash tests/run.sh   (exit 0 + per-case PASS/FAIL summary + ALL PASS)
set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SKILL_DIR" || exit 1

TMP_DIRS=()
cleanup() { [ ${#TMP_DIRS[@]} -gt 0 ] && rm -rf "${TMP_DIRS[@]}"; }
trap cleanup EXIT

CASE_COUNT=0
PASS_COUNT=0
SUMMARY=()

# run_case <name> <fn...> — the fn prints details on failure; rc!=0 marks FAIL.
run_case() {
  local name="$1"; shift
  local out rc=0
  CASE_COUNT=$((CASE_COUNT + 1))
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    SUMMARY+=("PASS  $name")
  else
    SUMMARY+=("FAIL  $name")
    [ -n "$out" ] && while IFS= read -r line; do SUMMARY+=("        | $line"); done <<< "$out"
  fi
}

fresh_copy() {
  # Clone the pieces the hooks need into a throwaway skill dir; echo its path.
  local d
  d="$(mktemp -d)" || return 1
  TMP_DIRS+=("$d")
  mkdir -p "$d/skill" || return 1
  cp -r "$SKILL_DIR/hooks" "$SKILL_DIR/scripts" "$SKILL_DIR/SKILL.md" "$d/skill/" || return 1
  printf '%s\n' "$d/skill"
}

# --- assertion helpers (exit non-zero with a message on mismatch) ---

expect_allow() {  # $1=hook stdout
  python3 - "$1" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(f"not valid JSON: {sys.argv[1][:200]!r}")
if d.get("decision") != "allow":
    sys.exit(f"expected allow, got {d}")
PY
}

expect_deny() {  # $1=hook stdout  $2=required reason substring
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(f"not valid JSON: {sys.argv[1][:200]!r}")
if d.get("decision") != "deny":
    sys.exit(f"expected deny, got {d}")
if sys.argv[2] and sys.argv[2] not in d.get("reason", ""):
    sys.exit(f"reason lacks {sys.argv[2]!r}: {d.get('reason')!r}")
PY
}

# Build an Agent-shaped PreToolUse event; args: tool_name, prompt, rib(true|false|absent)
agent_event() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
tool_name, prompt, rib = sys.argv[1], sys.argv[2], sys.argv[3]
ti = {"description": "d", "prompt": prompt, "subagent_type": "impl"}
if rib == "true":
    ti["run_in_background"] = True
elif rib == "false":
    ti["run_in_background"] = False
print(json.dumps({"tool_name": tool_name, "tool_input": ti}))
PY
}

dv_with_event() {  # $1=event json — run PreToolUse hook, print its stdout
  printf '%s' "$1" | python3 hooks/dispatch-validate.py
}

PKG_OK='{"task_id": "probe-1", "role": "impl", "objective": "o", "acceptance_criteria": ["a"]}'

fenced_prompt() {  # $1=fenced payload content
  printf 'context line\n\n```json\n%s\n```\n' "$1"
}

# --- frontmatter ---

case_fm_parse() {
  python3 - <<'PY'
import yaml
src = open("SKILL.md").read()
parts = src.split("---", 2)
if len(parts) < 3:
    raise SystemExit("no '---' frontmatter block")
d = yaml.safe_load(parts[1])
if not isinstance(d, dict):
    raise SystemExit(f"frontmatter is {type(d).__name__}, not a mapping")
for key in ("name", "description"):
    assert key in d, f"missing key {key!r}"
PY
}

# --- Hook 1: dispatch-validate (matrix 1.1–1.12) ---

case_1_1() { expect_allow "$(dv_with_event "$(agent_event Agent "$(fenced_prompt "$PKG_OK")" true)")"; }

case_1_2() {
  local pkg='{"task_id": "probe-1", "role": "impl", "acceptance_criteria": ["a"]}'
  expect_deny "$(dv_with_event "$(agent_event Agent "$(fenced_prompt "$pkg")" true)")" "Missing: objective"
}

case_1_3() {
  local pkg="{\"task_id\": \"probe-1\", \"role\": \"impl\", \"objective\": \"o\", \"acceptance_criteria\": [\"a\"], \"feature_id\": \"Bad_Branch!\"}"
  expect_deny "$(dv_with_event "$(agent_event Agent "$(fenced_prompt "$pkg")" true)")" "feature_id must match"
}

case_1_4() {
  expect_deny "$(dv_with_event "$(agent_event Agent "just prose, no fences here" true)")" "Every Agent call from the main session is a dispatch"
}

case_1_5() {
  local prompt out
  prompt="$(fenced_prompt '{"task_id": broken,,,}')"
  out="$(dv_with_event "$(agent_event Agent "$prompt" true)")" || return 1
  expect_deny "$out" "not valid JSON"
}

case_1_6() {
  local pkg="{\"task_id\": \"probe-1\", \"role\": \"impl\", \"objective\": \"o\", \"acceptance_criteria\": [\"a\"], \"instance_id\": \"retired-ignorer\"}"
  expect_allow "$(dv_with_event "$(agent_event Agent "$(fenced_prompt "$pkg")" true)")"
}

case_1_7() {
  # Real-shaped Agent tool_input (description/prompt/subagent_type/run_in_background),
  # no fenced JSON → deny, never crash.
  local ev out
  ev="$(agent_event Agent 'Dispatch the login fix.
No package here — this shape is what the platform actually sends.' true)"
  out="$(dv_with_event "$ev")" || return 1
  expect_deny "$out" "Every Agent call from the main session is a dispatch"
}

case_1_8() {
  # Malformed stdin → silent exit 0, empty stdout, never block.
  # (No NUL bytes: bash command substitution silently drops them.)
  local out
  out="$(printf '%s' 'not json {{{ %%%' | python3 hooks/dispatch-validate.py)" || return 1
  [ -z "$out" ] || { printf 'expected empty stdout, got %s\n' "$out"; return 1; }
  out="$(printf '\xff\xfe\x80binary-invalid-utf8' | python3 hooks/dispatch-validate.py)" || return 1
  [ -z "$out" ]
}

case_1_9() {
  expect_allow "$(dv_with_event "$(agent_event Task "$(fenced_prompt "$PKG_OK")" true)")"
}

case_1_10() {
  local pkg="{\"task_id\": \"probe-1\", \"role\": \"impl\", \"objective\": \"o\", \"acceptance_criteria\": [\"a\"], \"feature_id\": \"payment\"}"
  expect_allow "$(dv_with_event "$(agent_event Agent "$(fenced_prompt "$pkg")" true)")"
}

case_1_11() {
  expect_deny "$(dv_with_event "$(agent_event Agent "$(fenced_prompt "$PKG_OK")" absent)")" "run_in_background"
}

case_1_12() {
  expect_deny "$(dv_with_event "$(agent_event Agent "$(fenced_prompt "$PKG_OK")" false)")" "run_in_background"
}

# Fail-soft audit probe: structurally broken tool_input payloads must yield
# silent exit 0 (not a traceback), same family as 1.8.
case_1_audit_shapes() {
  local out
  out="$(printf '%s' '{"tool_name": "Agent", "tool_input": ["not","a","dict"]}' | python3 hooks/dispatch-validate.py)" || return 1
  [ -z "$out" ] || { printf 'list tool_input should be silent, got %s\n' "$out"; return 1; }
  out="$(printf '%s' '{"tool_name": "Agent", "tool_input": {"prompt": 42, "run_in_background": "true"}}' | python3 hooks/dispatch-validate.py)" || return 1
  expect_deny "$out" "Every Agent call"  # non-str prompt coerced; still a deny decision, no crash
}

# --- Hook 3: session-init (matrix 3.1–3.6) + fail-soft audit ---

case_3_1() {
  local d ctx
  d="$(fresh_copy)" || return 1
  ( cd "$d" && python3 hooks/session-init.py >o.json ) || return 1
  python3 - "$d" <<'PY'
import json, sys, pathlib
d = pathlib.Path(sys.argv[1])
ma = d / "multi-agent"
for p in ("index.json", "memory/shared.json"):
    if not (ma / p).is_file():
        sys.exit(f"missing {p}")
if not (ma / "comm").is_dir():
    sys.exit("missing comm/")
if not (d / ".git").exists():
    sys.exit("git not bootstrapped")
mem = json.loads((ma / "memory" / "shared.json").read_text())
for key in ("common_knowledge", "experiences", "task_patterns", "contracts"):
    assert key in mem, f"memory lacks {key}"
ctx = json.loads((d / "o.json").read_text())["additionalContext"]
assert "Index is empty" in ctx, "empty index line missing"
assert "doctor: all clear" in ctx, "health line missing"
PY
}

case_3_2() {
  local d
  d="$(fresh_copy)" || return 1
  ( cd "$d" && python3 scripts/multi-agent index create --task-id probe-20260912-99 --role impl ) >/dev/null || return 1
  ( cd "$d" && python3 hooks/session-init.py >o.json ) || return 1
  python3 - "$d" <<'PY'
import json, sys, pathlib
ctx = json.loads(pathlib.Path(sys.argv[1], "o.json").read_text())["additionalContext"]
assert "probe-20260912-99" in ctx, "populated index not injected"
assert "Request Routing" in ctx
PY
}

# Drop one '## <heading>' line from the copy's SKILL.md.
strip_heading() {  # $1=dir $2=heading prefix
  python3 - "$1" "$2" <<'PY'
import sys
path = f"{sys.argv[1]}/SKILL.md"
lines = open(path).read().splitlines()
out = [l for l in lines if not l.strip().startswith(sys.argv[2])]
open(path, "w").write("\n".join(out) + "\n")
PY
}

expect_fallback_for() {  # $1=o.json path $2=label that fell back $3=label that must stay verbatim
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys, pathlib
FALLBACK = "(contract section missing in SKILL.md)"
ctx = json.loads(pathlib.Path(sys.argv[1]).read_text())["additionalContext"]

def part(label):
    marker = f"--- {label} (from SKILL.md) ---\n"
    i = ctx.index(marker) + len(marker)
    j = ctx.find("\n\n--- ", i)
    return ctx[i:j if j != -1 else len(ctx)].strip()

missing, intact = sys.argv[2], sys.argv[3]
if part(missing) != FALLBACK:
    sys.exit(f"{missing!r} part is not the fallback: {part(missing)[:80]!r}")
body = part(intact)
if FALLBACK in body:
    sys.exit(f"{intact!r} part unexpectedly fell back")
if not body.startswith("## "):
    sys.exit(f"{intact!r} part is not the verbatim section: {body[:80]!r}")
PY
}

case_3_3() {
  local d
  d="$(fresh_copy)" || return 1
  strip_heading "$d" "## Request Routing" || return 1
  ( cd "$d" && python3 hooks/session-init.py >o.json ) || return 1
  expect_fallback_for "$d/o.json" "Request Routing" "Dispatch Package (MUST template)"
}

case_3_6() {
  local d
  d="$(fresh_copy)" || return 1
  strip_heading "$d" "## Dispatch Package (MUST template)" || return 1
  ( cd "$d" && python3 hooks/session-init.py >o.json ) || return 1
  expect_fallback_for "$d/o.json" "Dispatch Package (MUST template)" "Request Routing"
}

case_3_5() {
  # Byte-identity: both SKILL.md contract segments in the hook payload match
  # the corresponding SKILL.md slices (mirrors tests/hooks.md 3.5). Runs in
  # the repo — session-init is idempotent/read-only there by design.
  local json
  json="$(printf '{}' | python3 hooks/session-init.py)" || return 1
  python3 - "$json" <<'PY'
import hashlib, json, sys

ctx = json.loads(sys.argv[1])["additionalContext"]

def hook_segment(label):
    marker = f"--- {label} (from SKILL.md) ---\n"
    i = ctx.index(marker) + len(marker)
    j = ctx.find("\n\n--- ", i)
    return ctx[i:j if j != -1 else len(ctx)]

def skill_slice(lines, prefix):
    start = next(i for i, l in enumerate(lines) if l.strip().startswith(prefix))
    section = [lines[start]]
    for line in lines[start + 1:]:
        s = line.strip()
        if s == "---" or s.startswith("## "):
            break
        section.append(line)
    return "\n".join(section).strip()

lines = open("SKILL.md").read().splitlines()
for prefix, label in (
    ("## Request Routing", "Request Routing"),
    ("## Dispatch Package (MUST template)", "Dispatch Package (MUST template)"),
):
    h, s = hook_segment(label), skill_slice(lines, prefix)
    hh, sh = hashlib.sha256(h.encode()).hexdigest(), hashlib.sha256(s.encode()).hexdigest()
    if h != s or hh != sh:
        sys.exit(f"{label} not byte-identical (hook {hh[:12]} vs skill {sh[:12]})")
print("both segments byte-identical")
PY
}

case_si_garbage_stdin() {
  local out
  out="$(printf '%s' 'not json {{{ %%% <<<>>>' | python3 hooks/session-init.py)" || return 1
  printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'additionalContext' in d"
}

case_si_empty_stdin() {
  local out
  out="$(python3 hooks/session-init.py </dev/null)" || return 1
  printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'additionalContext' in d"
}

# Fail-soft audit probes: broken CLI / missing SKILL.md → still exit 0 + valid JSON.
case_si_audit_no_cli() {
  local d
  d="$(fresh_copy)" || return 1
  rm "$d/scripts/multi-agent" || return 1
  ( cd "$d" && python3 hooks/session-init.py >o.json ) || return 1
  python3 - "$d" <<'PY'
import json, sys, pathlib
ctx = json.loads(pathlib.Path(sys.argv[1], "o.json").read_text())["additionalContext"]
# Interpreter starts but the script file is gone: python's "can't open file"
# text (exit 2) or the hook's own "(hook error" — either must degrade into the
# bootstrap line, never abort the payload.
assert "Bootstrap" in ctx and ("can't open file" in ctx or "(hook error" in ctx), \
    "CLI-absent path should degrade into the bootstrap line"
assert "Request Routing" in ctx
PY
}

case_si_audit_no_skillmd() {
  local d
  d="$(fresh_copy)" || return 1
  rm "$d/SKILL.md" || return 1
  ( cd "$d" && python3 hooks/session-init.py >o.json ) || return 1
  python3 - "$d" <<'PY'
import json, sys, pathlib
ctx = json.loads(pathlib.Path(sys.argv[1], "o.json").read_text())["additionalContext"]
assert ctx.count("(contract section missing in SKILL.md)") == 2, "both sections should fall back"
assert "[orch-lite]" in ctx
PY
}

# --- doctor check (3) in scratch repos: direct-on-main flagged, merged clean ---

case_doctor() {
  # Branch discipline (post-schism rule): a task_id-authored commit made
  # DIRECTLY on main surfaces as main-violation; the same commit reaching main
  # through the main agent's --no-ff merge (second parent) must NOT — the scan
  # is first-parent. doctor always exits 0. Sandboxes are mktemp -d, fully
  # independent of this repo's history and multi-agent/ state.
  local dir out

  # (a) direct task commit on main -> violation
  dir="$(mktemp -d)" || return 1
  TMP_DIRS+=("$dir")
  git -C "$dir" init -q -b main || return 1
  git -C "$dir" -c user.name=baseline -c user.email=baseline@local commit -q --allow-empty -m baseline || return 1
  mkdir -p "$dir/multi-agent" && printf '{"tasks": {}}' > "$dir/multi-agent/index.json" || return 1
  git -C "$dir" -c user.name=ops-20260912-99 -c user.email=child@local commit -q --allow-empty -m "child work committed on main" || return 1
  out="$(cd "$dir" && python3 "$SKILL_DIR/scripts/multi-agent" doctor)" || { echo "doctor exited non-zero"; return 1; }
  printf '%s\n' "$out"
  grep -q "main-violation: ops-20260912-99" <<< "$out" || { echo "(a) expected main-violation for a direct commit on main"; return 1; }

  # (b) task commit on a feature branch, merged into main -> no violation
  dir="$(mktemp -d)" || return 1
  TMP_DIRS+=("$dir")
  git -C "$dir" init -q -b main || return 1
  git -C "$dir" -c user.name=baseline -c user.email=baseline@local commit -q --allow-empty -m baseline || return 1
  mkdir -p "$dir/multi-agent" && printf '{"tasks": {}}' > "$dir/multi-agent/index.json" || return 1
  git -C "$dir" checkout -q -b feature/demo || return 1
  git -C "$dir" -c user.name=impl-20260912-99 -c user.email=child@local commit -q --allow-empty -m "child work on feature branch" || return 1
  git -C "$dir" checkout -q main || return 1
  git -C "$dir" -c user.name=orchestrator-merge -c user.email=orchestrator@local merge -q --no-ff feature/demo -m "Merge feature/demo into main" || return 1
  out="$(cd "$dir" && python3 "$SKILL_DIR/scripts/multi-agent" doctor)" || { echo "doctor exited non-zero"; return 1; }
  printf '%s\n' "$out"
  grep -q "main-violation" <<< "$out" && { echo "(b) merge-integrated task commit must NOT surface as main-violation"; return 1; }
  grep -q "doctor: all clear" <<< "$out" || { echo "(b) expected 'doctor: all clear' in the merged-clean repo"; return 1; }
}

# --- run everything ---

run_case "FM.1   SKILL.md YAML frontmatter parses"        case_fm_parse
run_case "1.1    valid fenced package + background"       case_1_1
run_case "1.2    missing objective -> deny"               case_1_2
run_case "1.3    bad feature_id -> deny"                  case_1_3
run_case "1.4    no fenced block -> deny"                 case_1_4
run_case "1.5    malformed fenced JSON -> deny"           case_1_5
run_case "1.6    retired instance_id ignored -> allow"    case_1_6
run_case "1.7    real-shaped no-fence input -> deny"      case_1_7
run_case "1.8    malformed stdin -> silent exit 0"        case_1_8
run_case "1.9    Task alias + valid package -> allow"     case_1_9
run_case "1.10   branch-safe feature_id -> allow"         case_1_10
run_case "1.11   background absent -> deny"               case_1_11
run_case "1.12   run_in_background=false -> deny"         case_1_12
run_case "audit  dispatch-validate broken shapes"         case_1_audit_shapes
run_case "3.1    fresh project bootstrap (temp copy)"     case_3_1
run_case "3.2    populated index injected (temp copy)"    case_3_2
run_case "3.3    missing Request Routing -> fallback"     case_3_3
run_case "3.6    missing Dispatch Package -> fallback"    case_3_6
run_case "3.5    contract sections byte-identical"        case_3_5
run_case "audit  session-init garbage stdin -> exit 0"    case_si_garbage_stdin
run_case "audit  session-init empty stdin -> exit 0"      case_si_empty_stdin
run_case "audit  session-init missing CLI -> exit 0"      case_si_audit_no_cli
run_case "audit  session-init missing SKILL.md -> exit 0" case_si_audit_no_skillmd
run_case "doctor main-violation: direct flagged, merged clean" case_doctor

printf '%s\n' "${SUMMARY[@]}"
echo
printf '%d/%d cases passed\n' "$PASS_COUNT" "$CASE_COUNT"
if [ "$PASS_COUNT" -eq "$CASE_COUNT" ]; then
  echo "ALL PASS"
  exit 0
fi
echo "FAILURES: $((CASE_COUNT - PASS_COUNT))"
exit 1
