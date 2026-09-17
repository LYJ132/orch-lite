# Codex Desktop 开启 multi-agent v2 记录

> Sanitized copy; personal paths and environment fingerprints generalized.

> 环境：Windows 商店版 Codex Desktop `<Codex Desktop version>`（MSIX）
> 后端 codex CLI 版本：`<codex CLI version>`
> 自定义模型：`<model>`（本地中转，目录文件 `<model-catalog>`）
> 日期：2026-09-17

## 一句话结论

multi-agent v2 由两个开关共同控制：

1. 后端 feature flag：`features.multi_agent_v2 = true`（写在 `~/.codex/config.toml`）
2. 模型目录里的模型参数：给模型条目加 `"multi_agent_version": "v2"`

两个都改完、重启 Desktop 后，主对话就能 spawn / send_message / wait 子代理并行干活了。

---

## 排查过程（源码逆向逻辑）

### 1. 定位安装位置

Desktop 进程是商店版 MSIX：

- 外壳：系统 MSIX 应用目录下 Codex 安装目录里的 Electron/Chromium 壳（UI 逻辑在其打包的 UI 资源文件内）
- 后端 CLI：`%LOCALAPPDATA%\OpenAI\Codex\bin\<hash>\codex.exe`（真正的 agent 内核）

### 2. 二进制字符串搜索

对 `codex.exe` 做纯文本搜索（`rg -a`，不解码直接扫字符串），命中了关键证据：

```
features.multi_agent_v2.min_wait_timeout_ms
features.multi_agent_v2.max_wait_timeout_ms
features.multi_agent_v2.default_wait_timeout_ms
features.multi_agent_v2.max_concurrent_threads_per_session
multi_agent_version: "v1" / "v2" / null
一个包含 16 个字段的多代理 v2 配置结构体
core\src\tools\handlers\multi_agents_v2\spawn.rs
```

由此确认：multi-agent v2 是一组带独立调参的结构化 feature flag，v2 工具实现在 `core\src\tools\handlers\multi_agents_v2\`（spawn / send_message / wait / list_agents / interrupt_agent / followup_task）。

### 3. `codex features` 子命令一锤定音

CLI 自带 `features` 子命令，`codex features list` 直接输出所有 flag 的 stage 和生效状态：

| flag | stage | 当时状态 |
|---|---|---|
| `multi_agent`（v1） | stable | **true**（默认开） |
| `multi_agent_v2` | stable | **false**（默认关，这就是要开的） |
| `enable_fanout` | removed | false |
| `multi_agent_mode` | removed | false |

### 4. UI 侧的门控（打包 UI 资源）

在压缩的 JS 包里搜到：

- composer 顶部"Delegate work to subagents"横幅，"Try now"按钮写入的 feature 名是 **`multi_agent`（v1）**，不是 v2；
- 设置页 Experimental Features 的开关通过 `config/batchWrite` 写 `features.<name>`，与手动改 config.toml 等价；
- 每轮对话请求带 `multiAgentMode` 参数，枚举值为 `explicitRequestOnly`（默认）/ `proactive` / `custom` / `none`。

### 5. 模型参数从哪来

后端 `models-manager` 的 ModelInfo 里有序列化字段 `multi_agent_version`（取值 `v1` / `v2` / null）和 `multi_agent_reasoning_effort`。内建目录里标了 v2 的模型只有少数几个官方内建模型（此处不列出具体模型名，避免指纹化）。

自定义中转模型走的是用户自己的目录 JSON（`~/.codex/model-catalogs/<model-catalog>.json`），`<model>` 条目里原本没有 `multi_agent_version` —— 这就是"要配置模型参数"的出处。

---

## 实际改动

### 改动 1：`~/.codex/config.toml`

文件末尾追加：

```toml
[features]
multi_agent_v2 = true
```

> 标准做法其实是一条命令：`codex features enable multi_agent_v2`。
> 当天在 Codex 沙箱里跑这条命令时，它写临时文件被沙箱拦截（os error 5），
> 所以改为直接补丁写文件，结果等价。在自己终端里跑命令即可。

### 改动 2：`~/.codex/model-catalogs/<model-catalog>.json`

给 `<model>` 模型条目（`"experimental_supported_tools": []` 那行之后）插入：

```json
"multi_agent_version": "v2",
"multi_agent_reasoning_effort": "xhigh",
```

`multi_agent_version` 是关键字段；`multi_agent_reasoning_effort` 可选，控制子代理线程的推理力度（内建 v2 模型用 `xhigh`，嫌慢可改 `low`/`medium` 或删掉）。

---

## 验证

1. `codex features list` → `multi_agent_v2  stable  true`
2. PowerShell `ConvertFrom-Json` 解析目录 JSON 正常，字段读取正确
3. 重启 Desktop 后实际拉了一个子代理 `/root/v2_smoke_test` 做冒烟测试：
   spawn 创建成功 → 子代理独立执行并正确报告工作区状态 → 结果回传主会话。

链路完整跑通，v2 在 `<model>` 中转模型上生效。

---

## v2 还能怎么调（可选）

`[features] multi_agent_v2` 支持布尔值，也支持结构化表格（一个包含 16 个字段的 v2 配置结构体）：

```toml
[features.multi_agent_v2]
max_concurrent_threads_per_session = 8   # 并发子代理上限（最小 1，Desktop 校验 ≥8）
min_wait_timeout_ms = ...                # wait 等待超时三件套
max_wait_timeout_ms = ...
default_wait_timeout_ms = ...
tool_namespace = "..."                   # 工具命名空间
wait_agent_enabled = true                # 是否允许 wait 工具
expose_spawn_agent_model_overrides = ... # spawn 时可否指定模型
non_code_mode_only = ...
usage_hint_enabled = ...                 # 各种提示文案字段
```

不配置就全部走默认值，一般不需要动。

## 回滚

```bash
codex features disable multi_agent_v2
```

再把模型目录 JSON 里那两行删掉，重启 Desktop。
