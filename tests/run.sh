#!/usr/bin/env bash
# tests/run.sh — executable counterpart of the manual matrix in tests/hooks.md.
#
# Self-contained: no network, no writes outside mktemp -d sandboxes (negative
# paths never touch the real multi-agent/ runtime state; running session-init
# inside the repo is idempotent by design — init creates-if-missing, list and
# doctor are pure reads).
#
# Git discovery is ceiling-restricted so the sandboxes are HERMETIC: a repo at
# an ancestor of $TMPDIR (e.g. a stray /tmp/.git left by an init run whose cwd
# was reset) must never be discovered inside a temp project — that exact leak
# is what broke 3.1 ("git not bootstrapped": init saw /tmp's repo and skipped
# bootstrapping). The ceiling dir itself is excluded from the upward walk.
export GIT_CEILING_DIRECTORIES="${TMPDIR:-/tmp}"
#
# dispatch-validate is asserted against ZCode's real hook contract (v4):
# pass = exit 0 with EMPTY stdout; deny = exit 2 with the reason on STDERR;
# internal error = fail-open exit 0 with a stderr diagnostic. No JSON ever.
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

# dispatch-validate run harness: DV_RC / DV_STDOUT / DV_STDERR globals.
DV_ERR_FILE="$(mktemp)"
TMP_DIRS+=("$DV_ERR_FILE")
DV_RC=0
DV_STDOUT=""
DV_STDERR=""

dv_run() {  # $1=event json — run the PreToolUse hook, capture all three channels
  DV_STDOUT="$(printf '%s' "$1" | python3 hooks/dispatch-validate.py 2>"$DV_ERR_FILE")"
  DV_RC=$?
  DV_STDERR="$(cat "$DV_ERR_FILE")"
}

expect_pass() {  # ZCode pass shape: exit 0, empty stdout (reason channel unused)
  if [ "$DV_RC" -ne 0 ]; then
    printf 'expected exit 0 (pass), got %s (stderr: %s)\n' "$DV_RC" "$DV_STDERR"
    return 1
  fi
  if [ -n "$DV_STDOUT" ]; then
    printf 'expected EMPTY stdout on pass, got %s\n' "$DV_STDOUT"
    return 1
  fi
}

expect_deny() {  # $1=required stderr substring — ZCode deny shape: exit 2, empty stdout, reason on stderr
  local reason="$1"
  if [ "$DV_RC" -ne 2 ]; then
    printf 'expected exit 2 (deny), got %s (stderr: %s)\n' "$DV_RC" "$DV_STDERR"
    return 1
  fi
  if [ -n "$DV_STDOUT" ]; then
    printf 'deny must print nothing on stdout, got %s\n' "$DV_STDOUT"
    return 1
  fi
  case "$DV_STDERR" in
    *"$reason"*) : ;;
    *) printf 'stderr lacks %s: got %s\n' "$reason" "$DV_STDERR"; return 1 ;;
  esac
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

# --- Hook 1: dispatch-validate (matrix 1.1–1.12, v4 exit-code contract) ---

case_1_1() { dv_run "$(agent_event Agent "$(fenced_prompt "$PKG_OK")" true)"; expect_pass; }

case_1_2() {
  local pkg='{"task_id": "probe-1", "role": "impl", "acceptance_criteria": ["a"]}'
  dv_run "$(agent_event Agent "$(fenced_prompt "$pkg")" true)"
  expect_deny "Missing: objective"
}

case_1_3() {
  local pkg="{\"task_id\": \"probe-1\", \"role\": \"impl\", \"objective\": \"o\", \"acceptance_criteria\": [\"a\"], \"feature_id\": \"Bad_Branch!\"}"
  dv_run "$(agent_event Agent "$(fenced_prompt "$pkg")" true)"
  expect_deny "feature_id must match"
}

case_1_4() {
  dv_run "$(agent_event Agent "just prose, no fences here" true)"
  expect_deny "Every Agent call from the main session is a dispatch"
}

case_1_5() {
  dv_run "$(agent_event Agent "$(fenced_prompt '{"task_id": broken,,,}')" true)"
  expect_deny "not valid JSON"
}

case_1_6() {
  local pkg="{\"task_id\": \"probe-1\", \"role\": \"impl\", \"objective\": \"o\", \"acceptance_criteria\": [\"a\"], \"instance_id\": \"retired-ignorer\"}"
  dv_run "$(agent_event Agent "$(fenced_prompt "$pkg")" true)"
  expect_pass
}

case_1_7() {
  # Real-shaped Agent tool_input (description/prompt/subagent_type/run_in_background),
  # no fenced JSON → deny, never crash.
  local ev
  ev="$(agent_event Agent 'Dispatch the login fix.
No package here — this shape is what the platform actually sends.' true)"
  dv_run "$ev"
  expect_deny "Every Agent call from the main session is a dispatch"
}

case_1_8() {
  # Malformed stdin → fail-open: exit 0, empty stdout, one-line stderr
  # diagnostic (v4 contract; never blocks the call).
  # (No NUL bytes: bash command substitution silently drops them.)
  local out rc=0
  out="$(printf '%s' 'not json {{{ %%%' | python3 hooks/dispatch-validate.py 2>"$DV_ERR_FILE")" || rc=$?
  [ "$rc" -eq 0 ] || { printf 'expected exit 0 (fail-open), got %s\n' "$rc"; return 1; }
  [ -z "$out" ] || { printf 'expected empty stdout, got %s\n' "$out"; return 1; }
  grep -q "failing open" "$DV_ERR_FILE" || { printf 'expected fail-open diagnostic on stderr, got: %s\n' "$(cat "$DV_ERR_FILE")"; return 1; }
  out="$(printf '\xff\xfe\x80binary-invalid-utf8' | python3 hooks/dispatch-validate.py 2>/dev/null)" || return 1
  [ -z "$out" ]
}

case_1_9() {
  dv_run "$(agent_event Task "$(fenced_prompt "$PKG_OK")" true)"
  expect_pass
}

case_1_10() {
  local pkg="{\"task_id\": \"probe-1\", \"role\": \"impl\", \"objective\": \"o\", \"acceptance_criteria\": [\"a\"], \"feature_id\": \"payment\"}"
  dv_run "$(agent_event Agent "$(fenced_prompt "$pkg")" true)"
  expect_pass
}

case_1_11() {
  dv_run "$(agent_event Agent "$(fenced_prompt "$PKG_OK")" absent)"
  expect_deny "run_in_background"
}

case_1_12() {
  dv_run "$(agent_event Agent "$(fenced_prompt "$PKG_OK")" false)"
  expect_deny "run_in_background"
}

# Fail-soft audit probe: structurally broken tool_input payloads must yield
# the pass shape (exit 0, silent) or a clean deny — never a traceback.
case_1_audit_shapes() {
  dv_run "$(printf '%s' '{"tool_name": "Agent", "tool_input": ["not","a","dict"]}')"
  expect_pass
  dv_run "$(printf '%s' '{"tool_name": "Agent", "tool_input": {"prompt": 42, "run_in_background": "true"}}')"
  expect_deny "Every Agent call"  # non-str prompt coerced; still a deny, no crash
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
  # Byte-identity: all three SKILL.md contract segments in the hook payload
  # match the corresponding SKILL.md slices (mirrors tests/hooks.md 3.5).
  # Runs in the repo — session-init is idempotent/read-only there by design.
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
    ("## 5 Invariants (memorize)", "5 Invariants (memorize)"),
    ("## Request Routing", "Request Routing"),
    ("## Dispatch Package (MUST template)", "Dispatch Package (MUST template)"),
):
    h, s = hook_segment(label), skill_slice(lines, prefix)
    hh, sh = hashlib.sha256(h.encode()).hexdigest(), hashlib.sha256(s.encode()).hexdigest()
    if h != s or hh != sh:
        sys.exit(f"{label} not byte-identical (hook {hh[:12]} vs skill {sh[:12]})")
print("all three segments byte-identical")
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
assert ctx.count("(contract section missing in SKILL.md)") == 3, "all three contract sections should fall back"
assert "[orch-lite]" in ctx
PY
}

# --- fail-soft on an unwritable cwd (live SessionStart traceback regression) ---
# A session opened in an unwritable cwd (root-owned 755, e.g. ~/unmanned-store)
# once poisoned its own SessionStart context: the CLI's raw PermissionError
# traceback from ensure_multi_agent_dir reached additionalContext. These cases
# pin the fix: one human fallback line per affected section, observer exit 0,
# explicit init clean non-zero, no traceback word on stdout. Vacuously green
# under root (chmod 555 cannot block root).

unwritable_dir() {  # echo the path of a fresh chmod-555 dir (registered for cleanup)
  local d
  d="$(mktemp -d)" || return 1
  TMP_DIRS+=("$d")
  chmod 555 "$d" || return 1
  printf '%s\n' "$d"
}

case_si_unwritable_cwd() {
  [ "$(id -u)" -eq 0 ] && return 0
  local d out rc=0
  d="$(unwritable_dir)" || return 1
  out="$(cd "$d" && printf '{}' | python3 "$SKILL_DIR/hooks/session-init.py")" || rc=$?
  chmod 755 "$d"
  [ "$rc" -eq 0 ] || { printf 'hook must exit 0 in an unwritable cwd, got %s\n' "$rc"; return 1; }
  [ -z "$(ls -A "$d")" ] || { printf 'nothing may be created in the unwritable cwd, found: %s\n' "$(ls -A "$d")"; return 1; }
  python3 - "$out" <<'PY'
import json, sys
ctx = json.loads(sys.argv[1])["additionalContext"]
assert "--- Bootstrap (skipped: cannot create " in ctx, \
    f"bootstrap fallback header missing; ctx head: {ctx[:200]!r}"
assert "--- Agent Index (skipped: cannot create " in ctx, "index fallback header missing"
assert "Permission denied" in ctx, "permission reason missing from the fallback lines"
for banned in ("Traceback", 'File "', "PermissionError"):
    assert banned not in ctx, f"traceback word leaked into the payload: {banned!r}"
assert "Request Routing" in ctx, "contract sections must still inject"
PY
}

case_cli_unwritable_cwd() {
  [ "$(id -u)" -eq 0 ] && return 0
  local d out rc=0
  d="$(unwritable_dir)" || return 1
  # doctor: one human line, exit 0 (the quality bar the others must match)
  out="$(cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" doctor)"; rc=$?
  [ "$rc" -eq 0 ] || { chmod 755 "$d"; printf 'doctor must exit 0, got %s: %s\n' "$rc" "$out"; return 1; }
  grep -q "(doctor: not a repo)" <<< "$out" || { chmod 755 "$d"; printf 'doctor human line missing: %s\n' "$out"; return 1; }
  # index list (observer): same one line, exit 0
  out="$(cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" index list)"; rc=$?
  [ "$rc" -eq 0 ] || { chmod 755 "$d"; printf 'index list must exit 0, got %s: %s\n' "$rc" "$out"; return 1; }
  grep -q "bootstrap skipped: cannot create .*: Permission denied" <<< "$out" || { chmod 755 "$d"; printf 'index list fail-soft line missing: %s\n' "$out"; return 1; }
  # explicit init: same line, clean non-zero; no traceback on any channel
  out="$(cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" init 2>&1)"; rc=$?
  chmod 755 "$d"
  [ "$rc" -ne 0 ] || { printf 'explicit init must exit non-zero, got 0: %s\n' "$out"; return 1; }
  grep -q "bootstrap skipped: cannot create .*: Permission denied" <<< "$out" || { printf 'init fail-soft line missing: %s\n' "$out"; return 1; }
  if grep -q "Traceback" <<< "$out"; then printf 'traceback leaked:\n%s\n' "$out"; return 1; fi
  [ -z "$(ls -A "$d")" ] || { printf 'cwd must stay empty, found: %s\n' "$(ls -A "$d")"; return 1; }
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

# --- doctor check (4) in a scratch repo: HEAD tracked sources vs an install ---

case_doctor_drift() {
  # Dual-install drift: HEAD's *tracked* sources (never the working tree) are
  # compared by blob hash against --compare-dir. In sync or copy absent -> no
  # finding at all; altered / added / removed files -> one `drift:` line each.
  # Sandboxes are mktemp -d, independent of this repo and of ~/.agents.
  local root dir copy out
  root="$(mktemp -d)" || return 1
  TMP_DIRS+=("$root")
  dir="$root/repo"; copy="$root/copy"
  mkdir -p "$dir"/{hooks,references,scripts,tests} "$copy" "$dir/multi-agent" || return 1
  printf '# skill\n' > "$dir/SKILL.md"
  printf 'multi-agent/\n.worktrees/\n' > "$dir/.gitignore"
  printf 'print("hook")\n' > "$dir/hooks/session-init.py"
  printf '# state\n' > "$dir/references/03-state.md"
  cp "$SKILL_DIR/scripts/multi-agent" "$dir/scripts/multi-agent" || return 1   # the gate wants a skill-shaped HEAD
  printf '# tests\n' > "$dir/tests/scenarios.md"
  printf 'not a source root\n' > "$dir/README.md"                               # must never be compared
  git -C "$dir" init -q -b main || return 1
  git -C "$dir" add -A || return 1
  git -C "$dir" -c user.name=t -c user.email=t@l commit -qm base || return 1
  printf '{"tasks": {}}' > "$dir/multi-agent/index.json" || return 1
  cp -r "$dir/hooks" "$dir/references" "$dir/scripts" "$dir/tests" "$dir/SKILL.md" "$dir/.gitignore" "$copy/" || return 1

  # (a) identical copy -> no drift finding
  out="$(cd "$dir" && python3 "$SKILL_DIR/scripts/multi-agent" doctor --compare-dir "$copy")" || { echo "doctor exited non-zero"; return 1; }
  [ "$out" = "doctor: all clear" ] || { echo "(a) in-sync copy reported: $out"; return 1; }

  # (b) absent copy -> lenient: same output, still exit 0
  out="$(cd "$dir" && python3 "$SKILL_DIR/scripts/multi-agent" doctor --compare-dir "$root/no-such-install")" || { echo "doctor exited non-zero"; return 1; }
  [ "$out" = "doctor: all clear" ] || { echo "(b) absent copy reported: $out"; return 1; }

  # (c) working-tree dirt is not drift: HEAD is the comparison side
  printf 'uncommitted edit\n' >> "$dir/SKILL.md" || return 1
  out="$(cd "$dir" && python3 "$SKILL_DIR/scripts/multi-agent" doctor --compare-dir "$copy")" || { echo "doctor exited non-zero"; return 1; }
  [ "$out" = "doctor: all clear" ] || { echo "(c) working-tree dirt reported as drift: $out"; return 1; }
  git -C "$dir" checkout -q -- SKILL.md || return 1

  # (d) one altered + one added + one removed in the copy -> exactly those 3
  printf '# edited on disk\n' > "$copy/SKILL.md" || return 1
  printf 'extra\n' > "$copy/tests/added-in-copy.md" || return 1
  rm "$copy/references/03-state.md" || return 1
  mkdir -p "$copy/scripts/__pycache__" && printf 'junk\n' > "$copy/scripts/__pycache__/multi-agent.pyc" || return 1
  out="$(cd "$dir" && python3 "$SKILL_DIR/scripts/multi-agent" doctor --compare-dir "$copy")" || { echo "doctor exited non-zero"; return 1; }
  printf '%s\n' "$out"
  [ "$(grep -c '^drift: ' <<< "$out")" -eq 3 ] || { echo "(d) expected exactly 3 drift lines (the planted .pyc must not count)"; return 1; }
  grep -q '^drift: SKILL.md (HEAD [0-9a-f]* != copy [0-9a-f]*)$' <<< "$out" || { echo "(d) altered file not reported"; return 1; }
  grep -q '^drift: references/03-state.md (tracked in HEAD, missing in copy)$' <<< "$out" || { echo "(d) removed file not reported"; return 1; }
  grep -q '^drift: tests/added-in-copy.md (present in copy, not tracked in HEAD)$' <<< "$out" || { echo "(d) added file not reported"; return 1; }

  # (e) a repo that is not the skill source stays silent (no false storm of
  # "extra in copy" lines for every installed file)
  rm "$dir/scripts/multi-agent" && git -C "$dir" add -A >/dev/null || return 1
  git -C "$dir" -c user.name=t -c user.email=t@l commit -qm "stop tracking scripts/multi-agent" || return 1
  out="$(cd "$dir" && python3 "$SKILL_DIR/scripts/multi-agent" doctor --compare-dir "$copy")" || { echo "doctor exited non-zero"; return 1; }
  [ "$out" = "doctor: all clear" ] || { echo "(e) non-skill repo reported: $out"; return 1; }
}

# --- memory_set dotted-path list traversal (regression: traceback on lists) ---

case_mem_set_list() {
  # memory set must traverse lists by integer index (contracts.0.rule),
  # and any type mismatch (non-int segment at a list, out-of-range index,
  # descending into a scalar) must be a CLEAN usage error — one error line,
  # exit 1, never a traceback (the pre-fix CLI crashed with
  # AttributeError: 'list' object has no attribute 'setdefault').
  local d out
  d="$(mktemp -d)" || return 1
  TMP_DIRS+=("$d")
  ( cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" init ) >/dev/null || return 1
  ( cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" memory append --array contracts --entry '{"id": "c1", "rule": "old"}' ) >/dev/null || return 1

  # (a) traverse into a list element and set a key inside it
  ( cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" memory set --key contracts.0.rule --value '"new"' ) >/dev/null || return 1
  out="$(cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" memory get --key contracts.0.rule)" || return 1
  [ "$out" = "new" ] || { printf 'expected contracts.0.rule=new, got %s\n' "$out"; return 1; }

  # (b) int segment on the final part replaces the list element itself
  ( cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" memory set --key contracts.0 --value '{"id": "c1", "rule": "v2"}' ) >/dev/null || return 1
  out="$(cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" memory get --key contracts.0.id)" || return 1
  [ "$out" = "c1" ] || { printf 'expected contracts.0.id=c1 after index set, got %s\n' "$out"; return 1; }

  # (c) non-integer segment at a list -> clean usage error, exit 1
  out="$(cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" memory set --key contracts.bad.rule --value '1' 2>&1)" && { printf 'non-int list segment should fail\n'; return 1; }
  grep -q "Traceback" <<< "$out" && { printf 'traceback leaked:\n%s\n' "$out"; return 1; }
  grep -q "addresses a list" <<< "$out" || { printf 'expected clean usage error, got:\n%s\n' "$out"; return 1; }

  # (d) out-of-range index -> clean usage error, exit 1
  out="$(cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" memory set --key contracts.9.x --value '1' 2>&1)" && { printf 'out-of-range index should fail\n'; return 1; }
  grep -q "Traceback" <<< "$out" && { printf 'traceback leaked:\n%s\n' "$out"; return 1; }
  grep -q "out of range" <<< "$out" || { printf 'expected out-of-range error, got:\n%s\n' "$out"; return 1; }
}

# --- Python >= 3.9 parseability (the version guards' advertised minimum) ---

case_py39_parse() {
  # Every *.py (both hooks included) plus the extensionless scripts/multi-agent
  # must parse under the Python 3.9 grammar — older interpreters must hit the
  # hooks' one-line stderr guard / CLI's non-zero guard, never a SyntaxError
  # traceback. feature_version checks syntax only, which is exactly the guard
  # contract: the guard lines themselves run before any 3.10+ API use.
  python3 - <<'PY'
import ast, pathlib, sys
paths = sorted(set(pathlib.Path(".").glob("*/*.py")))
paths.append(pathlib.Path("scripts/multi-agent"))
names = {p.name for p in paths}
assert {"dispatch-validate.py", "session-init.py"} <= names, f"hooks missing from collection: {names}"
for p in paths:
    try:
        ast.parse(p.read_text(), filename=str(p), feature_version=(3, 9))
    except SyntaxError as e:
        sys.exit(f"{p}: not Python-3.9 parseable: {e}")
print(f"{len(paths)} files parse under the Python 3.9 grammar")
PY
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
run_case "1.8    malformed stdin -> fail-open exit 0"        case_1_8
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
run_case "3.7    session-init unwritable cwd -> fallback, exit 0" case_si_unwritable_cwd
run_case "3.8    CLI unwritable cwd: doctor/list/init human lines" case_cli_unwritable_cwd
run_case "doctor main-violation: direct flagged, merged clean" case_doctor
run_case "doctor4 install drift: sync/absent/dirty/3-diffs/gate" case_doctor_drift
run_case "MEM   memory_set traverses list indices, clean errors" case_mem_set_list
run_case "PY39  every python file parses as 3.9 (hooks + CLI)"  case_py39_parse

printf '%s\n' "${SUMMARY[@]}"
echo
printf '%d/%d cases passed\n' "$PASS_COUNT" "$CASE_COUNT"
if [ "$PASS_COUNT" -eq "$CASE_COUNT" ]; then
  echo "ALL PASS"
  exit 0
fi
echo "FAILURES: $((CASE_COUNT - PASS_COUNT))"
exit 1
