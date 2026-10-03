# DEVLOG — orch-lite

> Development rationale and memory. **Not authority** — `SKILL.md` is the only
> authority for rules. This file starts as the migration of the development
> memory previously stored in `.orch-lite/memory.json` (folder removed
> 2026-10-03, ahead of the 1.3.0 zero-state release). The 1.3.0 plan adds
> design rationale (from `references/01-judgment.md` §1-6) here in batch 4.

## Contracts (development discipline — dev-time only, not child-facing)

### contract-20260912-index-registration (active 2026-09-12)

**Rule**: Child agents register their task_id in `.orch-lite/index.json`
(index create at start). Commits go on a feature branch or in a worktree,
NEVER on main — branch discipline (invariants #2/#3), not index registration,
is what keeps doctor main-violation-free. Status->completed is written by the
main agent from the primary tree after integration.

**Rationale**: v2 (2026-09-12, supersedes v1): v1 wrongly claimed registration
silences doctor noise. Truth: doctor check (3) flags ANY task_id-authored
first-parent commit on main regardless of registration (now --first-parent
scan, scripts/multi-agent). Registration exists for stale-worktree cross-read
and observability only.

**1.3.0 note**: obsolete — `index.json` is deleted in 1.3.0; branch
discipline alone is the load-bearing rule.

### contract-20260912-push-verify-gh-api (active 2026-09-12)

**Rule**: After any push, verify the remote ref actually moved via gh api:
`gh api repos/<owner>/<repo>/git/ref/heads/<branch> --jq .object.sha` and
compare against local `git rev-parse HEAD`. Never treat git success output as
evidence on this box.

**Rationale**: Promoted by review-20260912-13 from recurring 2026-09-12
incidents: git success output has lied twice here — "Everything up-to-date"
printed despite curl 56/TLS errors during the orch-lite publish
(ops-20260912-01), and git ls-remote fakes success while network-flaky. Only
the gh api ref read is trustworthy.

### contract-20260912-integration-checkout-main (active 2026-09-12)

**Rule**: Integration merge by the main agent always starts with
`git checkout main` before any `git merge feature/<fid>` (confirm with
`git branch --show-current` first). Children legitimately stay on their
feature branches per invariant #2; merging without checkout = branch into
itself, double false success ("Already up to date" + "Everything up-to-date",
nothing lands).

**Rationale**: Promoted by review-20260912-13 from the 2026-09-12 integration
trap: single-dispatch children stay on their feature branch in the primary
tree, so a bare merge merges a branch into itself. Verified pattern:
`git checkout main` -> `git merge --no-ff feature/<fid>` -> suite -> push ->
gh api ref check. Related advisory: the worktree merge pre-check over-reports
conflicts (flagged SKILL.md "changed in both" on merges that completed
cleanly) — treat pre-check output as advisory and confirm with the real merge.

### contract-20260917-lightweight-core (active 2026-09-17)

**Rule**: No new mechanism (hook check, config file, mandatory field, or
ceremony step) may be added unless it prevents a failure that git history
cannot already prevent or record; default to convention over enforcement.

**1.3.0 note**: this law is codified as the 1.3.0 plan §0 decision filter
(the original text referenced memory.json as a recorder; that file is gone).

## Experiences

### 2026-09-12 · SKILL.md frontmatter fragility (ops-20260912-02)

SKILL.md frontmatter must stay a single-line scalar with no `": "` inside, or
yaml.safe_load fails (ScannerError mapping values are not allowed here);
hooks/session-init.py extracts the two "## " contract headings from the BODY
only, so frontmatter edits never change hook output. Verified by
byte-comparing hook stdout before/after. .gitattributes now pins eol=lf for
*.py/*.sh/*.md/*.json + extensionless scripts/multi-agent; all files were
already LF so no blob rewrites and 100755 bits intact. Push verified via gh
api (ls-remote still flaky here).

### 2026-09-12 · ZCode hook contract (impl-20260912-07)

ZCode hook contract (verified in the runner source, zcode.cjs): hook stdout is
parsed with a NON-strict object schema accepting top-level additionalContext /
additional_context / continue / decision (enum approve|block ONLY) / reason /
stopReason / suppressOutput / systemMessage / hookSpecificOutput; empty or
non-JSON stdout is fine (exit-code path: 0 pass, 2 deny for PreToolUse, other
non-zero error), and hookSpecificOutput.hookEventName must match the event.
Our legacy `{"decision": "allow"/"deny"}` failed the enum, so EVERY Agent
dispatch since hook registration was marked hook.run.failed and failed open
silently. Fixed in dispatch-validate v4 (empty stdout; exit 2 + stderr
reason). The 4 SessionStart hook.run.failed at 2026-09-12T07:14:49-54Z were
NOT an output-shape problem: `{"additionalContext": ...}` validates. All four
sessions had resumed with cwd
/home/linyujian/PROGRAMS/.agents/skills/lightweight-orchestrator, a directory
renamed away at 14:16 local — a process hook is spawned with the session cwd,
so the script never launched. Environment cause, unfixable inside the hook;
session-init output stays as-is.

### 2026-09-12 · tests/run.sh 3.1 regression root cause (impl-20260912-07)

A stray multi-agent init whose cwd was /tmp (agent cwds RESET between bash
calls — bare relative CLI invocations can silently run anywhere) created
/tmp/.git (branch main, commit chore: orchestrator baseline, 2026-09-12 16:01
local). Every mktemp -d sandbox then counted as already inside a git
repository, so session-init skipped the per-project bootstrap and case 3.1
failed with git not bootstrapped. Fix: run.sh exports
GIT_CEILING_DIRECTORIES=${TMPDIR:-/tmp} so git discovery cannot leave the
sandbox (verified: ceiling stops the upward walk before the ancestor repo).
Lesson: always cd into the target project before CLI calls; never trust
inherited cwd. /tmp/.git itself was left untouched (outside the worktree
boundary).

### 2026-09-12 · Live-session supremacy violations, pointer only (impl-20260912-10)

The supremacy fix is codified in SKILL.md ("even when the user explicitly
asks" clause, landed main@8c5d184); sudo-in-noninteractive-shell and
unwritable-cwd were intentionally NOT codified as SKILL.md invariants
(harness-enforced platform mechanisms; unwritable-cwd fail-soft handled in
CLI/hook, see the traceback entry); ambiguous-request handling was already
codified (Step-0 unsure-ask / N1).

### 2026-09-12 · Traceback finding: unwritable cwd poisoning (impl-20260912-10)

A session opened in an unwritable cwd (~/unmanned-store, root-owned 755)
poisoned its own SessionStart context — PermissionError errno 13 on
/home/linyujian/unmanned-store/multi-agent, raised from ensure_multi_agent_dir
(scripts/multi-agent:78) via init_command (:1051) and _load_index (:237)
during index_list (:298), then folded into additionalContext by the hook
(run_cli falls back to CLI stderr when stdout is empty).
Bootstrap-where-opened stays DESIGNED behavior for writable locations; only
the failure path changed: init/index/memory paths catch PermissionError/OSError
and emit one line — bootstrap skipped: cannot create <path>: <reason> —
observers (index list/show, memory get/list, doctor) exit 0, writers (init,
index create/update, memory set/append) exit 1 clean; session-init renders
per-section fallback headers (--- Section (skipped: ...) ---) and the words
Traceback, File-quote, PermissionError can never reach additionalContext;
doctor already matched the bar. Pinned by suite cases 3.7/3.8; commits
281fe40/8f9d0dc on feature/orch-lite-failsoft.

### 2026-09-12 · Two durable findings (impl-20260912-12)

(1) The shared primary tree is a serialization point — on start, re-verify
HEAD/branch/cleanliness instead of trusting the dispatch premise:
ops-20260912-11 held feature/orch-lite-iron-markers mid-flight with dirty
SKILL.md/tests/hooks.md, then committed and was merged into main WHILE
impl-20260912-12 was reading the tree; a naive branch switch during the dirty
window would have redirected the siblings commit. (2) When adding a SKILL.md
contract section, three suite spots encode the section set: run.sh case_3_5
byte-identity loop (enumerates sections explicitly), the missing-SKILL.md
audit fallback count (was == 2, now == 3), and tests/hooks.md section list —
update all together. Note: session-init fallback lines share the (contract
section missing in SKILL.md) text, so the count equals len(CONTRACT_SECTIONS).

### 2026-09-13 · Content allocation law (impl-20260912-28)

Every new rule goes to exactly ONE audience — main skill = main-agent
decisions + injected contracts; executor skill = child mechanics;
platform-enforced behaviors are never written. When the owner requests a
change, ask which audience it targets BEFORE writing.

## Pain log

### OPEN · 2026-09-17 · hooks.json `_sections` rejected by Codex strict validation

**Scenario**: 1.2.0 hooks.json 的 `_sections` 元数据键被 Codex 严格校验拒绝
（unknown field `_sections`），整个 hooks 配置解析失败——赌平台忽略未知键但未
真机验证。

**Lesson**: 任何新 manifest 字段/格式假设必须先在目标平台真机验证；分区映射放
文档不放清单；修复分支 feature/hotfix-hooks-json。

### RESOLVED · 2026-09-24 · same scenario

**Resolution**: 1.2.1 (ad031cf) 移除多余键并守住 schema；分区映射移入
tests/hooks.md。
