# SubagentStart Hook (Codex) — Design Document (rev2, archival)

> **Status**: This hook is implemented in this repo as `hooks/subagent-start.py` (registered in `hooks/hooks.json`). Items 1-2 of the verification checklist (§2.6) — trigger-timestamp confirmation and additionalContext delivery confirmation on a live Codex session — are still pending owner-side live verification. This document is an internal design record kept as-is for reference; it is not user-facing setup guidance (see [codex-setup.md](codex-setup.md) for that).

---

# orch-lite SubagentStart Hook（Codex）设计说明书

> 读者：负责本特性后续开发的智能体。
> 目标：在 orch-lite 插件中实现 `SubagentStart` hook（注册 + 脚本 + 策略文件 + 测试），完成本地实测后回填 orch-lite 仓库。
> 本文所有结论均基于对本机 Codex 安装的实际逆向与日志取证，证据路径全部给出，可复核。
> 撰写日期：2026-09-17。
> **修订版本：rev2（2026-09-17）**——本版应用了六项经所有者确认的修订（复用环约束语义更正、注入通道降级开关、策略默认值保守化、脚本健壮性加固、单向断链事实、schema 版本号）；**所有原始证据路径保持不变**。

---

## 0. 一页速览

- **要做什么**：给 orch-lite 插件新增一个 `SubagentStart` hook（Codex 平台），职责收缩为三件：审计、cwd 级范围策略、additionalContext 兜底注入。
- **为什么不复用旧 hook**：旧 `PreToolUse`（dispatch-validate.py）在 Codex 上对子代理派发**从不触发**（平台缺口），且新事件 schema 里没有消息内容字段，内容门禁在 Codex 目前**没有任何 hook 能做**。
- **不做的事**：不校验派发包内容（无通道）、不修复消息投递（hook 无能为力）、不从 index.json 读策略（写者分离，详见 §1.6）。
- **注入通道风险（命名依赖 + 降级开关）**：additionalContext 注入本身可能走与 `encrypted_content` 相同的已损坏加密管线——若验证清单第 2 条失败（注入未到达子代理），在策略中设 `inject_handbook:false`，hook 降级为**纯审计模式**（详见 §1.3、§2.4）。
- **验证清单**：见 §2.6；**部署路径**：见 §2.7；**未决问题**：见 §2.8。

---

## 1. 设计原因（平台调查结论）

### 1.1 环境事实

| 项 | 值 |
|---|---|
| Codex Desktop | 26.908.9136.0（商店版 MSIX，`C:\Program Files\WindowsApps\OpenAI.Codex_...\app\`） |
| codex 内核 | 0.154.0-alpha.6.2（`C:\Users\LIN YU JIAN\AppData\Local\OpenAI\Codex\bin\12219cbfbcbddde7\codex.exe`） |
| multi-agent v2 | 已启用：`[features] multi_agent_v2 = true`；模型目录 `relay-mu45469g.json` 中 glm-5.3-flash 带 `"multi_agent_version": "v2"` |
| 实测 | spawn → 独立执行 → FINAL_ANSWER 回传，链路完整跑通 |
| 模型链路 | glm-5.3-flash 经 codex-plus-plus 本地中转（`http://127.0.0.1:57321/v1`，wire_api=responses） |

### 1.2 关键发现 A：PreToolUse 对子代理派发从不触发（平台缺口）

四个独立证据：

1. **rollout 无痕**：父线程 rollout（`sessions\2026\09\17\rollout-2026-09-17T00-09-22-01a0aad1-..._01a0aafa-....jsonl`）的 event_msg 类型只有 `item_completed / task_complete / task_started / thread_settings_applied / token_count`，没有任何 hook 运行事件。
2. **日志库零记录**：`~/.codex/logs_2.sqlite` 的 logs 表约 14.9 万行，`LIKE '%hook%'` 命中 0 行。
3. **行为反证**：orch-lite 已注册 PreToolUse（matcher `spawn_agent|Agent|Task`，dispatch-validate.py 会在无 fenced JSON 时 exit 2 拒绝；本机 python 3.11 可用）。实测一次**不带任何 fenced JSON** 的 `spawn_agent` 调用成功放行——若 hook 触发必然被拒。
4. **hook_outputs 时间线**：`D:\TEMP\TMP\hook_outputs\<thread-id>\` 下只有 SessionStart 的输出文件（本线程 0:03:43 / 0:06:42 / 0:09:30 / 0:49:22 四份），spawn 时刻（0:10:01）无任何产出。

内核侧佐证：collab 工具（`spawn_agent / send_input / resume_agent / wait_agent / close_agent / send_message / followup_task / interrupt_agent / list_agents`）走独立的 `codex_collab_agent_tool_call_event` 事件通道，不在普通工具 hook 管线内。

**结论**：旧 hook 的核心价值——fenced JSON 派发包内容校验——在 Codex 上没有挂载点。这不是配置问题，是平台事件覆盖缺口。

### 1.3 关键发现 B：子代理收不到消息 payload（投递缺陷）

实测投递结构（子线程 rollout `rollout-2026-09-17T00-10-01-01a0aafb-742c-7ba1-8fca-73624a36f8dd.jsonl`）：

```json
"content": [
  {"type": "input_text", "text": "Message Type: NEW_TASK\nTask name: /root/v2_smoke_test\nSender: /root\nPayload:\n"},
  {"type": "encrypted_content", "encrypted_content": "This is a multi-agent v2 smoke test. Reply with..."}
]
```

- 真正的任务文本在 `encrypted_content` 内容块里，只有信封头是明文。
- 子代理推理原话：`"task payload only '/root/v2_smoke_test', no content"`、`"Task payload empty"`——模型读不到加密块，只能看工作区瞎猜。
- 用户自己测的两个会话同样中招（`01a0ab06`、`01a0ab0e` 的 rollout 里同款投递）。
- 机理：v2 的 inter-agent 通信（`InterAgentCommunication`，8 字段含 `encrypted_content`）配合 agent identity JWT / OctetKeyPair 加密基建，设计上依赖官方 OpenAI 后端解密；自定义中转链路无人解密 → 模型永远看不到 payload。
- **对 orch-lite 的直接影响**：派发包里的 acceptance_criteria、手册指令等文本，子代理当前根本收不到。
- **对 additionalContext 注入的连带风险（rev2 升级为命名依赖）**：SubagentStart 的 additionalContext 注入同样走父→子的消息投递管线，**可能与 `encrypted_content` 走同一条已损坏的加密通道**——即 hook 正确输出注入 JSON，子代理也未必读得到。因此验证清单第 2 条（注入到达确认）是本设计的**硬性命名依赖**：若该条实测失败，立即在策略文件中设 `inject_handbook: false`，hook 降级为**纯审计模式**（deny 策略 + 日志仍然生效，只是不再注入），降级路径已写入 §0 速览、§1.7 表与 §2.4 策略注释。

### 1.4 Codex hook 事件分类学（新 hook 的能力边界来源）

内核 `HookEventsToml` 的事件枚举（二进制取证）：`PreToolUse / PermissionRequest / PostToolUse / PreCompact / PostCompact / SessionStart / SessionEnd / UserPromptSubmit / SubagentStart / SubagentStop / Stop / Interrupt`。

**派发子代理在事件分类上不是 "tool use"，而是独立的 `SubagentStart` 生命周期事件**（内核内嵌 JSON schema 标题 `subagent-start.command.input` / `subagent-start.command.output`，可从 codex.exe 的 ASCII 流中直接定位提取）。

SubagentStart 输入 schema（9 个必填字段，**没有 prompt / tool_input**）：

```json
{
  "agent_id": "string",
  "agent_type": "string",
  "cwd": "string",
  "hook_event_name": "SubagentStart",
  "model": "string",
  "permission_mode": "default|acceptEdits|plan|dontAsk|bypassPermissions",
  "session_id": "string",
  "transcript_path": "string|null",
  "turn_id": "string  // Codex 扩展：父线程活跃轮次"
}
```

输出 schema（stdout JSON，标题 `subagent-start.command.output`）：

```json
{
  "continue": true,                  // false + stopReason = 否决/中止（注意：线程已创建，见 §2.8-3）
  "stopReason": null,
  "suppressOutput": false,
  "systemMessage": null,
  "hookSpecificOutput": {
    "hookEventName": "SubagentStart",           // 必填常量
    "additionalContext": "string|null"          // 注入给子代理的上下文
  }
}
```

对照：PreToolUse 的输入含 `tool_name / tool_input / tool_use_id`（内容可见），输出走 exit-code 契约（0 过 / 2 拒）。两者的能力差异由此注定。

### 1.5 ZCode 兼容性（共享 hooks.json 的依据）

ZCode 官方文档（`~/.zcode/cli/plugins/cache/zcode-plugins-official/zcode-guide/0.1.0/skills/diagnosing-hooks/SKILL.md`）明确：

- 支持的事件**只有七个**：`SessionStart / UserPromptSubmit / PreToolUse / PermissionRequest / PostToolUse / PostToolUseFailure / Stop`；
- "Events such as `Notification`, `SubagentStop`, and `PreCompact` are **not** supported"，错误事件名的后果是 "the hook never triggers"——**静默忽略，不影响同文件其他条目**。

结论：共享 `hooks.json` 里同时保留 PreToolUse（旧，ZCode 用）与 SubagentStart（新，Codex 用）不是冗余，是能力探测。各平台只执行自己支持的部分。

### 1.6 为什么策略放独立文件而不是 index.json

- **写者分离**：index.json 被 `multi-agent` CLI 和工作流频繁重写；策略若混入，CLI 一次重写/schema 演进就可能冲掉规则，且 index 的合法写者恰是被策略约束的工作流本身。
- **失败语义解耦**：本设计"策略损坏 → 零规则放行"；若策略住在 index，刚 init 无任务时 index 近空，策略会静默失效——策略可用性不能取决于任务历史。
- **数据无用**：收缩后的三个职责（审计、cwd 范围、注入）不需要任务台账；复用环发生在派发前的主代理侧——注意（rev2 更正）：**在 Codex 上复用环没有任何 hook 层面的强制手段**（PreToolUse 对派发从不触发，见 §1.2），SessionStart 注入 agent index 列表只是**让主代理"知道"可复用对象**，属感知提示而非强制；复用约束实际降级为模型自律（SKILL.md 契约 + 自约束）。SubagentStart 输入里连 feature_id/task_id 都没有，读了也没字段可匹配。
- **生命周期**：index 只增不减，策略恒定几行，不该按 spawn 频率反复读大文件。
- 可接受折中：把策略作为 `memory.json` 的独立段（由 `multi-agent init` 写一次、工作流不碰），但**不要放 index.json**。

### 1.7 三个目标在 Codex 上的落点（用户已确认的方向）

| 目标 | 落点 | hook 参与度 |
|---|---|---|
| 派发记录 | Codex 原生（`thread_spawn_edges`、thread_items、rollout、`codex agents` CLI） | 旧 hook 的记录职责废弃；新 hook 审计可选 |
| 验收标准声明 | SessionStart 注入派发契约（session-init.py，**已验证在 Codex 存活**）+ 验收移到合并前（主代理核对 + `multi-agent doctor` 的 main-violation/作者检查） | 无（内容不可见） |
| 正确分支 | 包内 feature_id + 子代理首动作建 `feature/<id>`（SKILL.md 契约）+ 合并时 doctor 兜底 | cwd 级范围检查（唯一能做的真策略） |
| 后台运行 | v2 spawn 原生异步（实测秒回） | 无需 |
| 复用倾向 | SessionStart 注入 agent index 列表（已活）+ `reuses` 字段降级为模型自约束 | 无（派发后才触发，管不了事前倾向） |
| **断链方向（rev2 新增事实）** | **断链仅存在于父→子方向**：父发给子的任务 payload（`encrypted_content`）子代理读不到；**子→父的 FINAL_ANSWER 回传实测完好**（spawn → 执行 → 回传链路完整跑通，见 §1.1） | 据此，验收核实**从"包内容到达子代理"转向父侧事后证据核查**：以合并时验证（merge-time verification）+ `multi-agent doctor`（main-violation/作者检查）作为**指定的补偿性控制**——子代理即使拿不到包内验收标准，其产出仍在父侧合并点被事后核验 |

---

## 2. 设计建议

### 2.1 设计原则

1. **fail-open 铁律**：任何内部错误（stdin 坏、策略文件坏、日志写失败、git 不可用）一律静默放行；只有策略文件中**明确存在的规则**被违反才拒绝。
2. **策略外置**：规则放项目 `.orch-lite/hook-policy.json`（无文件 = 零规则）；脚本保持通用、可原样进 orch-lite 仓库。
3. **stdout 纪律**：要么一个合法 JSON，要么什么都不输出（Codex/ZCode 均按 schema 严格校验输出，多余键会毁掉注入）。
4. **日志最小化**：记决策相关字段（决策、原因、agent 元数据），不倒灌整个 stdin。
5. **python >= 3.9、零第三方依赖、Windows/POSIX 可移植**（沿用 orch-lite 两个既有 hook 的先例）。

### 2.2 hooks.json 增量（与现有 SessionStart 条目同款式）

```json
"SubagentStart": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/hooks/subagent-start.py\"",
        "commandWindows": "python \"${CLAUDE_PLUGIN_ROOT}/hooks/subagent-start.py\"",
        "async": false
      }
    ]
  }
]
```

注：保留现有 `SessionStart` 与 `PreToolUse` 条目不动；`async` 字段在 ZCode 无运行时效果，仅作声明。

### 2.3 脚本全文（hooks/subagent-start.py）

```python
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
```

### 2.4 策略文件（`<项目>/.orch-lite/hook-policy.json`，可选）

```json
{
  "v": 1,
  "subagent_start": {
    "require_git_repo": false,
    "inject_handbook": true,
    "allowed_roots": [],
    "blocked_roots": []
  }
}
```

语义：文件不存在或损坏 = 零规则（放行+注入）；`inject_handbook` 缺省 true。

**rev2 策略注释（默认值保守化）**：

- `"v": 1` 为策略文件 schema 版本号，供后续演进时识别格式。
- `require_git_repo` 出厂**保守地保持 `false`**：deny 的确切语义尚未钉死（线程已创建后 `continue:false` 究竟阻止首轮 turn 还是回收线程，见 §2.8-3），在 §2.8-3 经真实测试钉死之前不应默认启用拒绝类规则，避免在语义不明时阻断正常派发。实测确认 deny 语义安全后，方可由各项目自行置 `true`。
- `inject_handbook` 是注入通道的**降级开关**：additionalContext 可能与 `encrypted_content` 走同一条已损坏加密管线（§1.3 rev2 条目）。若验证清单第 2 条实测失败（注入未到达子代理 rollout），将此项设为 `false`——hook 降级为**纯审计模式**（deny 策略与日志照常，只是不再注入），避免空转注入。

### 2.5 行为矩阵

| 场景 | 结果 |
|---|---|
| 无策略文件 / 策略损坏 | 放行 + 注入手册 |
| require_git_repo 且 cwd 非仓库 | deny（stopReason 指明规则）——注意：出厂默认 `require_git_repo:false`（见 §2.4 rev2 策略注释），在 §2.8-3 deny 语义钉死前该行仅在项目显式开启时生效 |
| git 命令不可用 | 跳过该检查，放行（沿用 v6 惯例） |
| allowed/blocked_roots 命中 | deny |
| stdin 损坏 / 非对象 / 无 cwd | 静默放行，零输出（脚本显式判空 `if not cwd: return`，不依赖 assert） |
| 日志写失败 | 不影响决策 |
| 验证清单第 2 条失败（注入未到达） | 设 `inject_handbook:false`，hook 降级为纯审计模式（deny + 日志保留，无注入） |

### 2.6 验证清单（实现后必做）

1. **触发确认**：spawn 一个探针子代理；两份日志（`<cwd>/.orch-lite/subagent-start.log` 与 `~/.orch-lite/hook-observe/subagent-start.log`）各新增一行，时间戳与 spawn 工具调用毫秒级对齐。若日志无行：先检查 Desktop 是否需要重启才加载 hooks.json 变更、是否弹出 hook 信任确认（内核有 trusted_hash 机制）。
2. **注入到达确认（命名依赖——失败即触发降级）**：在子代理 rollout（`~/.codex/sessions/.../rollout-*.jsonl`）中搜索 `[orch-lite SubagentStart]`，确认 additionalContext 真实进入子代理输入；同时观察子代理推理是否出现"先读 handbook"倾向。**若本条失败，说明注入走了与 `encrypted_content` 相同的损坏管线：在策略中设 `inject_handbook:false`，hook 降级为纯审计模式，其余功能不受影响。**
3. **策略拒绝确认**：手工构造 stdin（`cwd` 指向非仓库临时目录 + 策略 `require_git_repo: true`）跑脚本，验证输出 deny JSON 且 `continue: false`。
4. **fail-open 确认**：喂损坏 stdin 与损坏的 hook-policy.json，验证静默放行/零规则放行。
5. **回归**：确认 SessionStart（session-init.py 注入）与 PreToolUse（ZCode 侧）不受影响。

### 2.7 部署与信任

- 路径：本机插件 cache（`~/.codex/plugins/cache/orch-lite/orch-lite/<ver>/hooks/`）先改先测 → 行为符合预期后把 `hooks/hooks.json` 增量与 `hooks/subagent-start.py` 落回 orch-lite 仓库 → bump 版本重装。**cache 会被插件更新覆盖，仓库才是真身。**
- 改 hooks.json 后大概率需要重启 Desktop 并重新确认 hook 信任（内核 `trusted_hash` 机制；CLI 有 `--dangerously-bypass-hook-trust` 旗标可佐证其存在）。
- 建议同步在 `tests/hooks.md` / `tests/run.sh` 增加用例：合法输入 → allow 注入 JSON；策略 deny；损坏 stdin → 静默；损坏策略 → 零规则放行。

### 2.8 未决问题（实现时需实测钉死）

1. **触发瞬间准确定义**：输入带父线程 `turn_id`，推断是"子线程创建即触发、早于子代理首次模型调用"，但未逐帧验证；实现后用日志时间戳对齐 rollout 即可钉死。
2. **additionalContext 的落点形态**：SessionStart 的注入实测表现为输入侧 `hooks.additional_context` 内容项；SubagentStart 是否同款需按验证清单第 2 条确认。**且落点形态确认之外还需确认其是否被加密管线吞掉（§1.3 rev2 条目）——落点正确但内容不可达时同样触发 `inject_handbook:false` 降级。**
3. **deny 的确切语义**：线程已创建后 `continue:false` 究竟是阻止首轮 turn 还是回收线程，schema 未说明，需实测（探针 + 检查 `codex agents` 与 rollout 终态）。**本条是 `require_git_repo` 出厂默认 `false`（§2.4）的直接原因；钉死并确认安全后才能建议项目开启。**
4. **trust_hash 行为**：修改 hooks.json 后是否强制重新信任、信任状态存于何处（疑似 state_5.sqlite / global state），需观察。

### 2.9 升级路径（何时内容门禁复活）

- 上游给 `SubagentStart` 输入加 prompt/消息字段，或让 collab 工具接入 PreToolUse → 届时把 dispatch-validate 的包校验逻辑移植到新事件，内容门禁在 Codex 复活。
- 中转层修复（codex-plus-plus `user_scripts` 或外挂改写代理：`{"type":"encrypted_content","encrypted_content":X}` → `{"type":"input_text","text":X}`）→ 子代理能读到 payload，验收标准与手册指令随包到达。**这是"验收标准到达子代理"的前置条件，与 hook 无关但必须列入依赖。**
- 上游正修方向（值得报给 OpenAI）：非官方 provider 下 inter-agent payload 应直接投成 input_text；0.154.0-alpha.6.2 仍为 alpha。

---

## 附：关键证据文件索引

| 证据 | 路径 |
|---|---|
| 父线程 rollout（spawn 调用记录） | `C:\Users\LIN YU JIAN\.codex\sessions\2026\09\17\rollout-2026-09-17T00-09-22-01a0aad1-5b8f-7f41-a37b-ce1097f2ee15_01a0aafa-deac-7622-b75f-78b040d4bec7.jsonl` |
| 子线程 rollout（投递缺陷现场） | `C:\Users\LIN YU JIAN\.codex\sessions\2026\09\17\rollout-2026-09-17T00-10-01-01a0aafb-742c-7ba1-8fca-73624a36f8dd.jsonl` |
| codex 内核二进制（schema/事件取证） | `C:\Users\LIN YU JIAN\AppData\Local\OpenAI\Codex\bin\12219cbfbcbddde7\codex.exe` |
| hook 输出临时目录（SessionStart 证据） | `D:\TEMP\TMP\hook_outputs\01a0aad1-5b8f-7f41-a37b-ce1097f2ee15\` |
| 日志库（0 条 hook 记录） | `C:\Users\LIN YU JIAN\.codex\logs_2.sqlite`（logs 表） |
| ZCode hook 官方文档 | `C:\Users\LIN YU JIAN\.zcode\cli\plugins\cache\zcode-plugins-official\zcode-guide\0.1.0\skills\diagnosing-hooks\SKILL.md` |
| orch-lite 插件 hooks | `C:\Users\LIN YU JIAN\.codex\plugins\cache\orch-lite\orch-lite\1.1.2\hooks\`（hooks.json / dispatch-validate.py / session-init.py） |
| 已交付的开启指南（前置上下文） | `C:\Users\LIN YU JIAN\Desktop\Codex-multi-agent-v2-开启指南.md` |
