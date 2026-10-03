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

---

## Design rationale (migrated 2026-10-03 from references/01-judgment.md §1-6; 1.3.0 wording)

> Migrated as part of the 1.3.0 references consolidation: rationale lives in
> DEVLOG, rules live in SKILL.md. Text below is adapted to the 1.3.0
> zero-state design (feature_id keying, no index.json/memory.json); the
> original wording is in git history.

### 1.1 The User Is Never Blocked
A running task ≠ the user must wait. After dispatching, the main agent ends its turn; the user may submit new tasks / check status / ask questions at any time.

### 1.2 The Main Agent Coordinates, It Does Not Keep Waiting
- Receives requests → analyzes type & split strategy → dispatches child executors
- Creates the worktree scope at assign time (T1, concurrent only) → coordinates → handles HELP_REQUEST → receives reports → reports to the user
- The main agent does **not**: wait long for a child, do concrete work, keep agents alive between dispatches.

### 1.3 Recover System State, Not Full Context
On any event, read only the minimal state relevant to it (unreturned dispatches + `git worktree list` + the feature branch history), process, end the turn. Do not reload past conversations / all tasks / full agent context. The same minimalism governs file reads, gated by footprint per Step 0 (SKILL.md): narrow reads the main session takes itself; wide sweeps go to one read-only explore child — it writes nothing, so no worktree, branch, or commit.

### 1.4 Agents Are Limited to Two Layers
Level 0 main / Level 1 child executor. A child never derives further agents (executor rule 1). Level-2 workers were retired (see below) — on zcode the Agent tool is unavailable inside subagents, and the flat shape keeps the protocol portable.

### 1.5 Homogeneous Tasks Split by the Main Agent, Not Downward
Where a platform supports nesting, same-type work may shard — but the portable rule is: the MAIN agent dispatches homogeneous shards directly (flat parallelism), one agent per feature. Same type splits, different type coordinates laterally (HELP_REQUEST to main).

### 1.6 Heterogeneous Tasks Coordinate Laterally
Different-function need → check existing products (git / the feature branch); yes → reference directly, no → HELP_REQUEST to the main agent, which coordinates/dispatches.

### 1.7 Report Completed Tasks in Order
Independent: whoever finishes first is reported first. Dependent: judge per dependency whether it can be reported independently.

### 1.8 Direct Communication First
Normal: child reports directly to the main session. There is no fallback channel: task notifications and the platform's message delivery make one unnecessary — re-add one only if a real failure occurs.

### 1.9 Git Carries Task State, Not Live Chit-Chat
The feature branch + `git worktree list` provide only: what exists, what is running, what was produced. Not for real-time messaging / full history narration.

### 1.10 Isolation Is by Construction — But Gated by Concurrency
- When a worktree is used, it gives isolation by construction: `.worktrees/<feature_id>/`, created at T1, removed at T2; one long-lived branch per feature
- Whether a worktree is used at all is decided lazily, per §1.11
- Concurrent same-file edits cannot collide by construction: each executor writes only in its own write area, never on main

### 1.11 Isolation Is Gated on Observed Concurrency (Lazy) — the one-sentence rule
**Dispatch into the primary tree (solo) only when you can confirm nothing else is running — no unreturned dispatch this session and a clean `git worktree list`; otherwise create a worktree.** Misjudging costs one extra worktree, which the flow already pays for. A "blunt" gate it cannot see *which file* another child is writing, so concurrent-but-disjoint tasks are still worktreed — that over-isolation is one cheap `git worktree add`; the alternative (per-file occupancy tracking) is precisely the mechanism we retired. Zero new mechanism.

### 1.12 Shared Resources Are Protected by Construction
No shared mutable state exists to lock: git owns all facts, worktrees own all writes. (1.2.x serialized shared-memory writes with a CLI-internal flock — the file is gone.)

### 1.13 Experiences Are Cast Directly Into Rules
No separate SOP layer. A recurring lesson becomes a rule in SKILL.md (or a DEVLOG contract while developing); one-off lessons stay experiences in DEVLOG. **Unsure → ask the user.**

### 1.14 Do Not Add Complexity for Problems That Have Not Occurred
Build a minimal skeleton → run → discover real problems → analyze → design → user confirms → write a rule. Do not pre-suppose distributed scheduling, unlimited autonomy, complex state machines, or a full exception framework. (Codified as the 1.3.0 plan §0 decision filter.)

### 1.15 Errors: Minimize Post-Hoc Rework, Do Not Over-Confirm Up Front
Errors are low-probability and never fully preventable, so the response is not to repeatedly ask the user / thin-slice tasks for stepwise confirmation. Keep the cost of any single mistake minimal — the incremental-commit discipline (SKILL.md invariant 4) carries this.

### Level-2 workers (retired — platform constraint, grandchild probe 2026-09-11)
Worker spawning is conditional on platform support for nested agent spawning. On zcode the Agent tool is unavailable inside subagents (`Tool not found: Agent`), so level-2 workers cannot exist here; the main agent dispatches homogeneous shards directly (flat parallelism). The 1.3.0 protocol assumes the flat two-layer model everywhere.

---

## dsh provenance chain (1.3.0 back-ports)

The mechanisms below were validated in `dsh-orch-lite` (the Node
implementation of the same protocol,
`/mnt/d/Documents/deepseek-harness/default-workspace/dsh-orch-lite`) and
back-ported into this plugin in 1.3.0:

| Mechanism | dsh origin |
|---|---|
| Four-line resume template (SUPERSEDES / STILL VALID / ACCEPTANCE / READ FIRST) | `skills/orch-lite/SKILL.md:94-97` (dsh tree) |
| DONE/STUCK report states | dsh executor report contract |
| Idempotent `worktree create` (reuse + note) | dsh `worktree create` returns `reused` + note |
| Gate contract single-sourcing | dsh: the enforcer owns the constants; the notice renders from them |
| Lazy isolation (worktree only on observed concurrency) | dsh prose gate; dsh can half-enforce it because its host counts live workers — zcode carries it in prose |
| Parallelism default (decomposition check: unsure → parallel) | dsh `lib/index.js:96` |
