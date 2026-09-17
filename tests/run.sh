#!/usr/bin/env bash
# tests/run.sh — executable counterpart of the manual matrix in tests/hooks.md.
#
# Self-contained: no network, no writes outside mktemp -d sandboxes (negative
# paths never touch the real .orch-lite/ runtime state; running session-init
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

# SKILL.md lives at skills/orch-lite/SKILL.md (plugin layout, Phase 1); the
# hooks resolve it via _SKILL_MD_CANDIDATES. Temp-copy builders keep the
# deployed flat shape (SKILL.md at the copy root).
SKILL_MD="skills/orch-lite/SKILL.md"

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
  cp -r "$SKILL_DIR/hooks" "$SKILL_DIR/scripts" "$SKILL_DIR/$SKILL_MD" "$d/skill/" || return 1
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

# Handbook-first line every dispatch prompt must carry (v5 gate).
HANDBOOK_LINE='MANDATORY FIRST ACTION: read skills/orch-lite-executor/SKILL.md (your handbook).'

fenced_prompt() {  # $1=fenced payload content; appends the handbook-first line
  printf 'context line\n\n```json\n%s\n```\n\n%s\n' "$1" "$HANDBOOK_LINE"
}

fenced_prompt_nohb() {  # same, WITHOUT the handbook-first line (gate-negative)
  printf 'context line\n\n```json\n%s\n```\n' "$1"
}

# Run dispatch-validate from a different cwd (the gate resolves the
# .orch-lite index from the process cwd = project root, as in a live session).
dv_run_in() {  # $1=cwd, $2=event json
  ( cd "$1" && printf '%s' "$2" | python3 "$SKILL_DIR/hooks/dispatch-validate.py" 2>"$DV_ERR_FILE" )
  DV_RC=$?
  DV_STDOUT=""
  DV_STDERR="$(cat "$DV_ERR_FILE")"
}

# --- frontmatter ---

case_fm_parse() {
  python3 - "$SKILL_MD" <<'PY'
import sys, yaml
src = open(sys.argv[1]).read()
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
  local pkg='{"task_id": "probe-1", "role": "impl", "objective": "o", "acceptance_criteria": ["a"], "instance_id": "retired-ignorer"}'
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
  # branch-safe feature_id + existing feature branch -> allow (v6 binding:
  # run in a sandbox repo where refs/heads/feature/payment exists)
  local d pkg
  d="$(fresh_git_repo feature/payment)" || return 1
  pkg='{"task_id": "probe-1", "role": "impl", "objective": "o", "acceptance_criteria": ["a"], "feature_id": "payment"}'
  dv_run_in "$d" "$(agent_event Agent "$(fenced_prompt "$pkg")" true)"
  expect_pass
}

# fresh_git_repo <branch> — sandbox git repo on main with one commit and
# <branch> (refs/heads/<branch>) created; echoes the repo path.
fresh_git_repo() {
  local d
  d="$(mktemp -d)" || return 1
  TMP_DIRS+=("$d")
  git -C "$d" init -q -b main || return 1
  git -C "$d" -c user.name=t -c user.email=t@l commit -q --allow-empty -m base || return 1
  git -C "$d" branch -q "$1" || return 1
  printf '%s\n' "$d"
}

# reuse_repo <branch> <index-tasks-json> — sandbox git repo with branch and a
# .orch-lite/index.json carrying the given tasks map; echoes the repo path.
reuse_repo() {
  local d
  d="$(fresh_git_repo "$1")" || return 1
  mkdir -p "$d/.orch-lite"
  printf '{"tasks": %s}' "$2" > "$d/.orch-lite/index.json"
  printf '%s\n' "$d"
}

case_1_11() {
  dv_run "$(agent_event Agent "$(fenced_prompt "$PKG_OK")" absent)"
  expect_deny "run_in_background"
}

case_1_12() {
  dv_run "$(agent_event Agent "$(fenced_prompt "$PKG_OK")" false)"
  expect_deny "run_in_background"
}

# --- v7 reuse loop: reuses required when the feature has index history ---

case_1_13() {
  # feature_id whose feature has index history, no reuses field -> deny ONCE
  # with a digest of the prior entries (task ids + statuses + summaries)
  local d pkg
  d="$(reuse_repo feature/hist-line '{"hist-01": {"feature_id": "hist-line", "status": "completed", "objective": "first pass", "output": "did the first pass"}, "other-01": {"feature_id": "other", "status": "assigned"}}')" || return 1
  pkg='{"task_id": "probe-1", "role": "impl", "objective": "o", "acceptance_criteria": ["a"], "feature_id": "hist-line"}'
  dv_run_in "$d" "$(agent_event Agent "$(fenced_prompt "$pkg")" true)"
  expect_deny "already has tasks in the index"
  case "$DV_STDERR" in
    *hist-01*completed*"did the first pass"*) : ;;
    *) printf 'deny must carry the digest (id/status/summary), got:\n%s\n' "$DV_STDERR"; return 1 ;;
  esac
  case "$DV_STDERR" in
    *other-01*) printf 'digest must only cover the feature own entries\n'; return 1 ;;
  esac
  case "$DV_STDERR" in
    *"reuses"*"task_ids"*) : ;; *) printf 'deny must instruct re-sending with reuses\n'; return 1 ;;
  esac
}

case_1_14() {
  # reuses naming an unknown task_id -> deny listing the valid index ids
  local d pkg
  d="$(reuse_repo feature/hist-line '{"hist-01": {"feature_id": "hist-line", "status": "completed"}}')" || return 1
  pkg='{"task_id": "probe-1", "role": "impl", "objective": "o", "acceptance_criteria": ["a"], "feature_id": "hist-line", "reuses": ["ghost-id"]}'
  dv_run_in "$d" "$(agent_event Agent "$(fenced_prompt "$pkg")" true)"
  expect_deny "unknown task_id"
  case "$DV_STDERR" in *"hist-01"*) : ;; *) printf 'deny must name the valid ids\n'; return 1 ;; esac
}

case_1_15() {
  # no handbook-first instruction -> deny
  dv_run "$(agent_event Agent "$(fenced_prompt_nohb "$PKG_OK")" true)"
  expect_deny "handbook-first instruction"
  case "$DV_STDERR" in *skills/orch-lite-executor/SKILL.md*) : ;; *) printf 'deny must name the handbook path\n'; return 1 ;; esac
}

case_1_16() {
  # reuses of the wrong shape (empty list / non-list) -> deny
  local d pkg
  d="$(reuse_repo feature/hist-line '{"hist-01": {"feature_id": "hist-line", "status": "completed"}}')" || return 1
  for body in '[]' '"hist-01"' '[42]'; do
    pkg="{\"task_id\": \"probe-1\", \"role\": \"impl\", \"objective\": \"o\", \"acceptance_criteria\": [\"a\"], \"feature_id\": \"hist-line\", \"reuses\": $body}"
    dv_run_in "$d" "$(agent_event Agent "$(fenced_prompt "$pkg")" true)"
    expect_deny "non-empty list"
  done
}

case_1_17() {
  # feature_id with NO index history -> passes WITHOUT reuses (loop only fires
  # when the feature already has entries); index exists but has no such feature
  local d pkg
  d="$(reuse_repo feature/fresh-line '{"hist-01": {"feature_id": "other-feature", "status": "completed"}}')" || return 1
  pkg='{"task_id": "probe-1", "role": "impl", "objective": "o", "acceptance_criteria": ["a"], "feature_id": "fresh-line"}'
  dv_run_in "$d" "$(agent_event Agent "$(fenced_prompt "$pkg")" true)"
  expect_pass
}

case_1_18() {
  # valid reuses ids -> allow
  local d pkg
  d="$(reuse_repo feature/hist-line '{"hist-01": {"feature_id": "hist-line", "status": "completed"}, "hist-02": {"feature_id": "hist-line", "status": "failed"}}')" || return 1
  pkg='{"task_id": "probe-1", "role": "impl", "objective": "o", "acceptance_criteria": ["a"], "feature_id": "hist-line", "reuses": ["hist-01", "hist-02"]}'
  dv_run_in "$d" "$(agent_event Agent "$(fenced_prompt "$pkg")" true)"
  expect_pass
}

case_1_19() {
  # package WITHOUT feature_id is unaffected by the reuse loop, even when the
  # index is full of history
  local d
  d="$(reuse_repo feature/hist-line '{"hist-01": {"feature_id": "hist-line", "status": "completed"}}')" || return 1
  dv_run_in "$d" "$(agent_event Agent "$(fenced_prompt "$PKG_OK")" true)"
  expect_pass
}

# --- v6 feature-branch binding (packages WITH a feature_id only) ---

case_1_20() {
  # A1: feature branch exists -> pass silently
  local d pkg
  d="$(fresh_git_repo feature/existing-line)" || return 1
  pkg='{"task_id": "probe-1", "role": "impl", "objective": "o", "acceptance_criteria": ["a"], "feature_id": "existing-line"}'
  dv_run_in "$d" "$(agent_event Agent "$(fenced_prompt "$pkg")" true)"
  expect_pass
}

case_1_21() {
  # A1: feature branch absent -> deny naming BOTH fixes (create-branch
  # instruction for a new feature; fix the feature_id otherwise)
  local d pkg
  d="$(fresh_git_repo feature/other-line)" || return 1
  pkg='{"task_id": "probe-1", "role": "impl", "objective": "o", "acceptance_criteria": ["a"], "feature_id": "missing-line"}'
  dv_run_in "$d" "$(agent_event Agent "$(fenced_prompt "$pkg")" true)"
  expect_deny "Branch feature/missing-line does not exist"
  case "$DV_STDERR" in
    *"create branch feature/missing-line from the current mainline HEAD"*) : ;;
    *) printf 'deny lacks the NEW-feature create-branch fix\n'; return 1 ;;
  esac
  case "$DV_STDERR" in
    *"fix the feature_id"*) : ;;
    *) printf 'deny lacks the fix-the-feature_id fix\n'; return 1 ;;
  esac
}

case_1_22() {
  # A1: package WITHOUT feature_id is unaffected by the binding gate, even
  # outside any git repo (fail-open for git, no deny)
  local d pkg
  d="$(mktemp -d)" || return 1
  TMP_DIRS+=("$d")
  pkg="$PKG_OK"
  dv_run_in "$d" "$(agent_event Agent "$(fenced_prompt "$pkg")" true)"
  expect_pass
}

case_1_23() {
  # v6 binding: branch absent + prompt carries the create-branch instruction
  # for THIS feature_id -> pass (new-feature dispatch is no longer a deadlock)
  local d pkg prompt
  d="$(fresh_git_repo feature/other-line)" || return 1
  pkg='{"task_id": "probe-1", "role": "impl", "objective": "o", "acceptance_criteria": ["a"], "feature_id": "fresh-line"}'
  prompt="context line: create branch with \`git checkout -b feature/fresh-line\` from mainline HEAD.
$(fenced_prompt "$pkg")"
  dv_run_in "$d" "$(agent_event Agent "$prompt" true)"
  expect_pass
}

case_1_24() {
  # v6 binding: branch absent + instruction names a DIFFERENT feature_id
  # -> still deny with the two-fix message (exact-id scoping)
  local d pkg prompt
  d="$(fresh_git_repo feature/other-line)" || return 1
  pkg='{"task_id": "probe-1", "role": "impl", "objective": "o", "acceptance_criteria": ["a"], "feature_id": "missing-line"}'
  prompt="context: run \`git checkout -b feature/some-other-line\` before writing.
$(fenced_prompt "$pkg")"
  dv_run_in "$d" "$(agent_event Agent "$prompt" true)"
  expect_deny "Branch feature/missing-line does not exist"
}

case_route_must() {
  # B: Step 0 routing line is a hard MUST; self-repair clause and the three
  # routing states stay in the Request Routing section.
  python3 - "$SKILL_MD" <<'PY'
import sys
src = open(sys.argv[1]).read()
start = src.index("## Request Routing")
end = src.index("## ", start + 5)
section = src[start:end].replace("**", "")
assert "MUST output exactly one `[routing] ...` line as the first line of every reply" in section, \
    "routing MUST line missing"
assert "Self-repair." in section, "self-repair clause missing"
for state in ("[routing] chat → handle directly",
              "[routing] task → single dispatch",
              "[routing] orchestration → enable index+worktrees"):
    assert state in section, f"routing state missing: {state}"
PY
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
ma = d / ".orch-lite"
for p in ("index.json", "memory.json"):
    if not (ma / p).is_file():
        sys.exit(f"missing {p}")
if not (d / ".git").exists():
    sys.exit("git not bootstrapped")
mem = json.loads((ma / "memory.json").read_text())
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
  python3 - "$json" "$SKILL_MD" <<'PY'
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

lines = open(sys.argv[2]).read().splitlines()
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
  # independent of this repo's history and .orch-lite/ state.
  local dir out

  # (a) direct task commit on main -> violation
  dir="$(mktemp -d)" || return 1
  TMP_DIRS+=("$dir")
  git -C "$dir" init -q -b main || return 1
  git -C "$dir" -c user.name=baseline -c user.email=baseline@local commit -q --allow-empty -m baseline || return 1
  mkdir -p "$dir/.orch-lite" && printf '{"tasks": {}}' > "$dir/.orch-lite/index.json" || return 1
  git -C "$dir" -c user.name=ops-20260912-99 -c user.email=child@local commit -q --allow-empty -m "child work committed on main" || return 1
  out="$(cd "$dir" && python3 "$SKILL_DIR/scripts/multi-agent" doctor)" || { echo "doctor exited non-zero"; return 1; }
  printf '%s\n' "$out"
  grep -q "main-violation: ops-20260912-99" <<< "$out" || { echo "(a) expected main-violation for a direct commit on main"; return 1; }

  # (b) task commit on a feature branch, merged into main -> no violation
  dir="$(mktemp -d)" || return 1
  TMP_DIRS+=("$dir")
  git -C "$dir" init -q -b main || return 1
  git -C "$dir" -c user.name=baseline -c user.email=baseline@local commit -q --allow-empty -m baseline || return 1
  mkdir -p "$dir/.orch-lite" && printf '{"tasks": {}}' > "$dir/.orch-lite/index.json" || return 1
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
  mkdir -p "$dir"/{hooks,references,scripts,tests} "$copy" "$dir/.orch-lite" || return 1
  printf '# skill\n' > "$dir/SKILL.md"
  printf '.orch-lite/\n.worktrees/\n' > "$dir/.gitignore"
  printf 'print("hook")\n' > "$dir/hooks/session-init.py"
  printf '# state\n' > "$dir/references/03-state.md"
  cp "$SKILL_DIR/scripts/multi-agent" "$dir/scripts/multi-agent" || return 1   # the gate wants a skill-shaped HEAD
  printf '# tests\n' > "$dir/tests/scenarios.md"
  printf 'not a source root\n' > "$dir/README.md"                               # must never be compared
  git -C "$dir" init -q -b main || return 1
  git -C "$dir" add -A || return 1
  git -C "$dir" -c user.name=t -c user.email=t@l commit -qm base || return 1
  printf '{"tasks": {}}' > "$dir/.orch-lite/index.json" || return 1
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

  # (f)-(h) cross-layout: a plugin-layout HEAD (SKILL.md at
  # skills/orch-lite/SKILL.md, the Phase 1 repo shape) vs a flat copy must
  # compare by the SKILL.md ROLE — never a false "missing" storm for every
  # path; a plugin-form copy matches the same way.
  local prepo pcopy2
  prepo="$root/prepo"; pcopy2="$root/pcopy"
  mkdir -p "$prepo"/{hooks,references,scripts,tests,skills/orch-lite} "$prepo/.orch-lite" "$pcopy2" || return 1
  printf '# skill\n' > "$prepo/skills/orch-lite/SKILL.md"
  printf '.orch-lite/\n.worktrees/\n' > "$prepo/.gitignore"
  printf 'print("hook")\n' > "$prepo/hooks/session-init.py"
  printf '# state\n' > "$prepo/references/03-state.md"
  cp "$SKILL_DIR/scripts/multi-agent" "$prepo/scripts/multi-agent" || return 1
  printf '# tests\n' > "$prepo/tests/scenarios.md"
  git -C "$prepo" init -q -b main || return 1
  git -C "$prepo" add -A || return 1
  git -C "$prepo" -c user.name=t -c user.email=t@l commit -qm base || return 1
  printf '{"tasks": {}}' > "$prepo/.orch-lite/index.json" || return 1
  cp -r "$prepo/hooks" "$prepo/references" "$prepo/scripts" "$prepo/tests" "$prepo/.gitignore" "$pcopy2/" || return 1
  cp "$prepo/skills/orch-lite/SKILL.md" "$pcopy2/SKILL.md" || return 1

  # (f) plugin HEAD vs in-sync flat copy -> role-matched, no drift at all
  out="$(cd "$prepo" && python3 "$SKILL_DIR/scripts/multi-agent" doctor --compare-dir "$pcopy2")" || { echo "doctor exited non-zero"; return 1; }
  [ "$out" = "doctor: all clear" ] || { echo "(f) plugin HEAD vs flat copy reported: $out"; return 1; }

  # (g) altered flat-copy SKILL.md -> exactly 1 drift line, named by the role path
  printf '# edited on disk\n' > "$pcopy2/SKILL.md" || return 1
  out="$(cd "$prepo" && python3 "$SKILL_DIR/scripts/multi-agent" doctor --compare-dir "$pcopy2")" || { echo "doctor exited non-zero"; return 1; }
  [ "$(grep -c '^drift: ' <<< "$out")" -eq 1 ] || { echo "(g) expected exactly 1 drift line: $out"; return 1; }
  grep -q '^drift: SKILL.md (HEAD [0-9a-f]* != copy [0-9a-f]*)$' <<< "$out" || { echo "(g) role-named SKILL.md drift line missing: $out"; return 1; }

  # (h) plugin-form copy (SKILL.md under skills/orch-lite/) -> all clear again
  rm "$pcopy2/SKILL.md" || return 1
  mkdir -p "$pcopy2/skills/orch-lite" || return 1
  cp "$prepo/skills/orch-lite/SKILL.md" "$pcopy2/skills/orch-lite/SKILL.md" || return 1
  out="$(cd "$prepo" && python3 "$SKILL_DIR/scripts/multi-agent" doctor --compare-dir "$pcopy2")" || { echo "doctor exited non-zero"; return 1; }
  [ "$out" = "doctor: all clear" ] || { echo "(h) plugin HEAD vs plugin copy reported: $out"; return 1; }
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

case_index_agent_id() {
  # --agent-id on index create/update is plain per-task metadata: stored,
  # surfaced by index list (extra column) and index show (JSON dump), and
  # influencing nothing else. Enables the continuation/reuse check (SKILL.md
  # NEW_TASK step 2.5) to find a completed task's resumable agent.
  local d out
  d="$(mktemp -d)" || return 1
  TMP_DIRS+=("$d")
  ( cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" init ) >/dev/null || return 1
  ( cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" index create --task-id impl-aid-01 --role impl --feature-id fid --agent-id agent_set_at_create ) >/dev/null || return 1

  # list shows the agent column
  out="$(cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" index list)" || return 1
  grep -q "impl-aid-01 | impl | fid | assigned | agent_set_at_create" <<< "$out" || { printf 'list missing agent column:\n%s\n' "$out"; return 1; }

  # update overwrites the agent id
  ( cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" index update --task-id impl-aid-01 --status running --agent-id agent_after_update ) >/dev/null || return 1
  out="$(cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" index show --task-id impl-aid-01)" || return 1
  grep -q '"agent_id": "agent_after_update"' <<< "$out" || { printf 'show missing updated agent_id:\n%s\n' "$out"; return 1; }
}

case_index_agent_binding() {
  # The agents.json layer is REMOVED: index create/update carry --agent-id
  # (plain metadata) only; entries never bind an agents.json registry id.
  local d out
  d="$(mktemp -d)" || return 1
  TMP_DIRS+=("$d")
  ( cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" init ) >/dev/null || return 1

  # --agent-id still recorded at create and update (plain metadata)
  ( cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" index create --task-id impl-bind-01 --role impl --feature-id fid --agent-id agent_at_create ) >/dev/null || return 1
  out="$(cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" index show --task-id impl-bind-01)" || return 1
  grep -q '"agent_id": "agent_at_create"' <<< "$out" || { printf 'show missing agent_id:\n%s\n' "$out"; return 1; }
  grep -q '"agent"' <<< "$out" && { printf 'registry agent field must be gone:\n%s\n' "$out"; return 1; }

  # the agents.json validation is gone: any id (even unregistered) is accepted
  # without a warning and lands as plain agent_id metadata
  out="$(cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" index create --task-id impl-bind-02 --role impl --agent-id ghost 2>&1)" || { printf '%s\n' "unregistered id must not fail create"; return 1; }
  grep -q "Warning: cannot validate" <<< "$out" && { printf '%s\n' "registry validation must be gone"; return 1; }
  out="$(cd "$d" && python3 "$SKILL_DIR/scripts/multi-agent" index show --task-id impl-bind-02)" || return 1
  grep -q '"agent_id": "ghost"' <<< "$out" || { printf '%s\n' "agent_id metadata missing"; return 1; }
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

# --- Hook 4: subagent-start (Codex SubagentStart event, rev2 design) ---
# Codex-only event (ZCode silently ignores it). Output is a stdout-JSON
# contract: allow -> hookSpecificOutput.hookEventName=SubagentStart with
# additionalContext; deny -> continue:false + stopReason; any internal error
# -> silent zero-output fail-open. Policy lives at <cwd>/.orch-lite/
# hook-policy.json (runtime-only, NOT shipped); missing/broken = zero rules.
# The sandbox mktemp dirs are non-repos (GIT_CEILING_DIRECTORIES above), which
# 4.2 exploits directly. HOME is pointed at a temp dir so the audit mirror
# (~/.orch-lite/hook-observe/subagent-start.log) never touches the real home.

ss_home_dir() {  # echo a temp HOME dir (registered for cleanup)
  local d
  d="$(mktemp -d)" || return 1
  TMP_DIRS+=("$d")
  printf '%s\n' "$d"
}
SS_HOME="$(ss_home_dir)"

ss_run() {  # $1=stdin text — run the SubagentStart hook, capture stdout
  SS_STDOUT="$(printf '%s' "$1" | HOME="$SS_HOME" python3 hooks/subagent-start.py)"
  SS_RC=$?
}

case_4_1() {  # no policy file -> allow + handbook injection, exact JSON shape
  local d
  d="$(mktemp -d)" || return 1
  TMP_DIRS+=("$d")
  ss_run "{\"cwd\": \"$d\", \"agent_id\": \"a1\", \"agent_type\": \"impl\", \"model\": \"m\", \"session_id\": \"s1\", \"turn_id\": \"t1\"}"
  [ "$SS_RC" -eq 0 ] || { echo "exit $SS_RC"; return 1; }
  python3 - "$SS_STDOUT" "$d" <<'PY'
import json, sys, pathlib
d = json.loads(sys.argv[1])
assert d["hookSpecificOutput"]["hookEventName"] == "SubagentStart"
assert "skills/orch-lite-executor/SKILL.md" in d["hookSpecificOutput"]["additionalContext"]
log = pathlib.Path(sys.argv[2], ".orch-lite", "subagent-start.log")
rec = json.loads(log.read_text().splitlines()[-1])
assert rec["decision"] == "allow" and rec["reason"] is None and rec["v"] == 1
assert rec["agent_id"] == "a1" and rec["turn_id"] == "t1"
PY
}

case_4_2() {  # require_git_repo + non-repo cwd -> deny {continue:false}
  local d
  d="$(mktemp -d)" || return 1
  TMP_DIRS+=("$d")
  mkdir -p "$d/.orch-lite"
  printf '{"v":1,"subagent_start":{"require_git_repo":true}}' > "$d/.orch-lite/hook-policy.json"
  ss_run "{\"cwd\": \"$d\"}"
  [ "$SS_RC" -eq 0 ] || { echo "exit $SS_RC"; return 1; }
  python3 - "$SS_STDOUT" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["continue"] is False and "require_git_repo" in d["stopReason"]
assert d["hookSpecificOutput"]["hookEventName"] == "SubagentStart"
assert d["hookSpecificOutput"].get("additionalContext") is None
PY
}

case_4_3() {  # corrupt stdin -> silent zero-output, exit 0
  ss_run 'not json {{{ %%% <<<>>>'
  [ "$SS_RC" -eq 0 ] || { echo "exit $SS_RC"; return 1; }
  [ -z "$SS_STDOUT" ] || { echo "expected empty stdout, got: $SS_STDOUT"; return 1; }
}

case_4_4() {  # corrupt policy file -> zero rules, allow + injection
  local d
  d="$(mktemp -d)" || return 1
  TMP_DIRS+=("$d")
  mkdir -p "$d/.orch-lite"
  printf '%s' 'not json {{{' > "$d/.orch-lite/hook-policy.json"
  ss_run "{\"cwd\": \"$d\"}"
  [ "$SS_RC" -eq 0 ] || { echo "exit $SS_RC"; return 1; }
  python3 - "$SS_STDOUT" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["hookSpecificOutput"]["hookEventName"] == "SubagentStart"
assert "SKILL.md" in d["hookSpecificOutput"]["additionalContext"]
PY
}

case_4_5() {  # blocked_roots hit -> deny (policy is read from the cwd itself)
  local d
  d="$(mktemp -d)" || return 1
  TMP_DIRS+=("$d")
  mkdir -p "$d/.orch-lite"
  printf '{"v":1,"subagent_start":{"blocked_roots":["%s"]}}' "$d" > "$d/.orch-lite/hook-policy.json"
  ss_run "{\"cwd\": \"$d\"}"
  [ "$SS_RC" -eq 0 ] || { echo "exit $SS_RC"; return 1; }
  python3 - "$SS_STDOUT" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["continue"] is False and "blocked_roots" in d["stopReason"]
PY
}

case_4_6() {  # inject_handbook:false -> allow, silent (pure audit mode)
  local d
  d="$(mktemp -d)" || return 1
  TMP_DIRS+=("$d")
  mkdir -p "$d/.orch-lite"
  printf '{"v":1,"subagent_start":{"inject_handbook":false}}' > "$d/.orch-lite/hook-policy.json"
  ss_run "{\"cwd\": \"$d\"}"
  [ "$SS_RC" -eq 0 ] || { echo "exit $SS_RC"; return 1; }
  [ -z "$SS_STDOUT" ] || { echo "expected empty stdout, got: $SS_STDOUT"; return 1; }
  python3 - "$d" <<'PY'
import json, sys, pathlib
rec = json.loads(pathlib.Path(sys.argv[1], ".orch-lite", "subagent-start.log").read_text().splitlines()[-1])
assert rec["decision"] == "allow"
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
run_case "1.13   feature with index history, no reuses -> digest deny" case_1_13
run_case "1.14   unknown reuses id -> deny naming valid ids"    case_1_14
run_case "1.15   handbook-first missing -> deny"          case_1_15
run_case "1.16   reuses wrong shape -> deny"                   case_1_16
run_case "1.17   feature with no index history -> pass w/o reuses" case_1_17
run_case "1.18   valid reuses ids -> allow"                    case_1_18
run_case "1.19   no feature_id -> reuse loop unaffected"      case_1_19
run_case "1.20   v6 binding: branch exists -> pass"       case_1_20
run_case "1.21   v6 binding: branch absent -> deny, both fixes" case_1_21
run_case "1.22   v6 binding: no feature_id unaffected"    case_1_22
run_case "1.23   v6 binding: branch absent + create-branch instruction -> pass" case_1_23
run_case "1.24   v6 binding: instruction for a DIFFERENT id -> deny" case_1_24
run_case "ROUTE  Step 0 routing line is a MUST (B)"       case_route_must
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
run_case "3.9    index --agent-id metadata kept, --agent flag gone" case_index_agent_binding
run_case "doctor main-violation: direct flagged, merged clean" case_doctor
run_case "doctor4 install drift: sync/absent/dirty/3-diffs/gate/cross-layout" case_doctor_drift
run_case "MEM   memory_set traverses list indices, clean errors" case_mem_set_list
run_case "IDX   index --agent-id: set + read via list/show"     case_index_agent_id
run_case "PY39  every python file parses as 3.9 (hooks + CLI)"  case_py39_parse
run_case "4.1    subagent-start: no policy -> allow + injection + audit" case_4_1
run_case "4.2    subagent-start: require_git_repo non-repo -> deny" case_4_2
run_case "4.3    subagent-start: corrupt stdin -> silent zero-output" case_4_3
run_case "4.4    subagent-start: corrupt policy -> zero rules, allow" case_4_4
run_case "4.5    subagent-start: blocked_roots hit -> deny"      case_4_5
run_case "4.6    subagent-start: inject_handbook:false -> audit-only" case_4_6

printf '%s\n' "${SUMMARY[@]}"
echo
printf '%d/%d cases passed\n' "$PASS_COUNT" "$CASE_COUNT"
if [ "$PASS_COUNT" -eq "$CASE_COUNT" ]; then
  echo "ALL PASS"
  exit 0
fi
echo "FAILURES: $((CASE_COUNT - PASS_COUNT))"
exit 1
