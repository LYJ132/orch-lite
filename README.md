# Orch-lite

[English](#english) · [中文](#中文)

<a id="english"></a>

## English

**Your Agent is working. Why should you stop?**

**Let agents work. Keep the human workflow moving.**

Orch-lite is a lightweight background-execution skill for Coding Agents.

It solves a simple problem: **when an Agent is working, the human should not have to stop working too.**

You can send a task, let it run in the background, and keep thinking, asking questions, refining requirements, making decisions, or starting another task. When the Agent reaches a meaningful checkpoint, you review the result and decide what happens next.

> **What Orch-lite decouples is not task dependency. It decouples Agent execution time from human waiting time.**

---

## The Problem

Coding Agents are good at doing work.

But while they work, you often have to wait.

A typical interaction looks like this:

```text
Human → request A → Agent executes A → Human waits → review → next request
```

The problem is not that A takes time. The problem is that the human workflow is forced to follow the Agent's execution time.

That creates two unnecessary constraints:

- **Your time is coupled to the Agent's execution time.** A long test, build, debugging session, or documentation task can block your next thought.
- **Your conversation becomes an execution log.** Requirements and decisions get mixed with shell output, diffs, test results, and debugging details.

Orch-lite changes the time structure instead:

```text
Human workflow ─────────────────────────────────→
Agent A       ───────────────→
Agent B             ───────────────→
Agent C                    ───────────────→
```

The Agent keeps working. The human keeps moving.

![Orch-lite: two decoupled timelines](docs/orch-lite.png)

---

## The Idea

Orch-lite gives the human workflow and Agent execution **independent timelines**.

A typical workflow becomes:

1. You send task A.
2. Orch-lite dispatches A to background execution.
3. You continue the conversation or start thinking about B.
4. A finishes and waits at a meaningful checkpoint.
5. You review A and decide whether to continue, revise, or integrate.
6. Meanwhile, other independent work can keep moving.

The important distinction is:

```text
Not this:
    decouple task A from task B

But this:
    decouple Agent execution time
                 from
          human waiting time
```

**Logical dependencies remain. Human decisions remain. Waiting is what changes.**

---

## Why Orch-lite?

### Keep working

An Agent can spend minutes running tests or debugging without occupying your entire interaction loop. You can continue with another thought instead of watching the Agent work.

### Keep deciding

Background execution does not mean autonomous decision-making. When a result requires review, revision, integration, or a direction choice, the decision comes back to the human.

**What changes is waiting. What does not change is human control.**

### Keep conversations clean

The main conversation is for requirements, ideas, questions, decisions, and review — not a continuous stream of execution logs. Background Agents carry the operational detail while the main session stays focused on intent and direction.

---

## Quick Start

### ZCode

Open **Settings → Plugins → Personal**, click **Create → Add marketplace**, enter `LYJ132/orch-lite` as the GitHub repo source, and click **Create**. Refresh the marketplace, then click **Install** on the Orch-lite plugin card.

### Codex

Add the marketplace and install from CLI:

```bash
codex plugin marketplace add LYJ132/orch-lite
codex plugin add orch-lite
```

Or open Codex and run `/plugins` to browse and install. After installation, run `/hooks` to review and trust the bundled hooks.

> Plugin version 1.2.0+ bundles the Codex hooks (`sessionStart`, `preToolUse`, `subagentStart`). See [docs/codex-setup.md](docs/codex-setup.md) for enabling multi-agent v2 and trusting the hooks, and [docs/codex-subagent-start.md](docs/codex-subagent-start.md) for the SubagentStart hook design notes.

> **Codex support is experimental.** What works: sessionStart context injection; the SubagentStart hooks (audit, cwd-policy, handbook injection — pending live verification); and native multi-agent v2 dispatch. What does not work yet: `preToolUse` never fires for subagent dispatches on Codex, so the dispatch-package gate has no hook enforcement on that path; and inter-agent message payloads are encrypted and unreadable by the model, so `acceptance_criteria` and handbook instructions inside a dispatch do not reach children — acceptance verification therefore moves to parent-side post-hoc checks. Both limitations need upstream platform fixes. Details: [docs/codex-setup.md](docs/codex-setup.md), [docs/codex-subagent-start.md](docs/codex-subagent-start.md).

### Claude Code

The repo ships Claude Code plugin manifests from the start (`.claude-plugin/plugin.json` + `marketplace.json`, tracking the mainline version 1.2.0), so plugin install and skill loading are expected to work. Whether the bundled hooks load and work on Claude Code is unverified: they may load and work as-is, or they may not — no testing has been done yet; verification is pending.

---

## Orch-lite vs. Multi-Agent

Orch-lite uses multiple agents where background execution benefits from them, but **Multi-Agent is a means, not the product goal.**

| | Multi-Agent systems | Orch-lite |
|---|---|---|
| Primary concern | Agent collaboration | Human-Agent workflow |
| Main question | How should agents work together? | Why must humans wait while an Agent works? |
| Main mechanism | Multiple agents and coordination | Background execution and task continuity |
| Human role | Depends on the system | Remains responsible for meaningful decisions |

Orch-lite is not trying to maximize agent count, build an agent swarm, or create a general-purpose distributed scheduler.

Its question is much simpler:

> **Why should your work stop because your Agent is busy?**

---

## Design Principles

### 1. Decoupling

**The human and the Agent do not have to work on the same clock.**

The goal is not to remove task dependencies. If B depends on A, B still depends on A's result. The goal is to prevent that dependency from unnecessarily turning into human waiting time.

### 2. Decisions Stay with the Human

Machines can execute work in parallel; meaningful decisions remain with the human.

```text
Agent executes
      ↓
needs direction / review
      ↓
human decides
      ↓
Agent continues
```

Background execution does not mean handing over control. It means the Agent can work while the human continues their own workflow.

### 3. Multi-Agent Is a Means, Not the Goal

Background agents, task state, Git, and worktrees exist to support the workflow above. They are implementation mechanisms, not the reason Orch-lite exists.

---

## How It Works

At a high level, Orch-lite does four things:

1. **Dispatches execution** — the main session handles intent, conversation, routing, and decisions; concrete write/execution work is dispatched to background Agents.
2. **Persists task state** — `.orch-lite/index.json` tracks background tasks independently of any single session.
3. **Isolates concurrent work when needed** — Git branches and worktrees keep concurrent tasks from unnecessarily interfering with each other.
4. **Reuses work and conclusions** — existing Agent sessions and historical task conclusions can be reused instead of repeatedly starting from zero.

<details>
<summary>Technical architecture</summary>

### Main session and child Agents

Orch-lite defines responsibilities through two skills:

| Skill | Audience | Responsibility |
|---|---|---|
| `orch-lite` | Main session | Understand intent, route requests, dispatch tasks, coordinate state, and integrate results |
| `orch-lite-executor` | Child Agent | Execute the dispatched task within workspace, commit, and reporting boundaries |

The main session focuses on the human-facing workflow. The child Agent handles the concrete execution.

### Task tracking: `.orch-lite/index.json`

Background task state lives on disk rather than inside one conversation. This makes task status queryable and resumable even when a session ends or an Agent changes.

The task record contains information such as the objective, acceptance criteria, status, products, and executing Agent.

### Isolation and parallelism

Git isolation is applied when concurrent work makes it useful:

- A single task can work directly on the relevant feature branch.
- When another task needs to run concurrently, it can receive its own Git worktree.
- Child Agents do not integrate directly into `main`; integration remains a controlled step.
- If integration encounters a conflict, the decision can be handed back to the human.

```text
          Repository
   ┌──────────┼──────────┐
   ↓          ↓          ↓
 Task A     Task B     Task C
 worktree   worktree   worktree
   │          │          │
   ↓          ↓          ↓
 Agent A    Agent B    Agent C
```

### Reuse

Before dispatching new work, Orch-lite can inspect relevant task history and reuse prior conclusions. When an existing Agent context is still useful, continuation can avoid rebuilding context from scratch.

Experiences and durable contracts can also be stored separately in `.orch-lite/memory/shared.json` for later reuse.

</details>

---

## What Orch-lite Does Not Do

Orch-lite is deliberately not trying to solve everything:

- It does **not** remove logical task dependencies.
- It does **not** make every task parallelizable.
- It does **not** make Agents fully autonomous.
- It does **not** eliminate human review or decision-making.
- It does **not** exist to maximize the number of Agents.
- It does **not** replace the human workflow with an autonomous swarm.

It changes **when the human has to wait**, not **what the work depends on**.

---

## FAQ

### Is Orch-lite another Multi-Agent framework?

Not primarily. Multi-Agent execution is one mechanism Orch-lite can use. The product problem is the coupling between Agent execution time and human waiting time.

### Does background execution mean Agents become autonomous?

No. Background execution separates execution from waiting; it does not remove human decision points.

### Can dependent tasks run in parallel?

Only when their logical dependencies allow it. Orch-lite does not pretend that background execution removes dependencies. If B needs A's result, B still needs A's result.

### Where do execution details go?

Execution happens in the background task's context and workspace. The main conversation can stay focused on requirements, decisions, and review instead of carrying every execution detail.

---

## Closing

Orch-lite does not try to make humans unnecessary.

It makes waiting unnecessary **when waiting isn't required by the work itself.**

```text
Agent works.
Human keeps moving.
```

**Let agents work. Keep the human workflow moving.**

---

<a id="中文"></a>

## 中文

**Agent 在工作，为什么你也必须停下来？**

**让 Agent 去工作，让人的工作流继续。**

Orch-lite 是一个面向 Coding Agent 的轻量级后台执行 Skill。

它解决的是一个很简单的问题：**Agent 在执行任务时，人不应该也被迫停下来等待。**

你可以提出任务，让它在后台执行；与此同时，你继续思考、提问、补充需求、调整方向，甚至开始另一个任务。Agent 到达需要关注的检查点后，再由你审核结果并决定下一步。

> **Orch-lite 解耦的不是任务依赖，而是 Agent 的执行时间与人的等待时间。**

---

## 问题是什么？

Coding Agent 很擅长做事情。

但 Agent 工作的时候，人往往必须等。

传统交互通常是：

```text
人 → 提出 A → Agent 执行 A → 人等待 → 审核 → 下一个需求
```

问题并不是 A 需要时间，而是**人的工作流被迫跟着 Agent 的执行时间走。**

于是产生两个不必要的限制：

- **人的时间与 Agent 的执行时间绑定。** 测试、构建、调试、文档生成等耗时工作，都可能阻塞人的下一个想法。
- **对话逐渐变成执行日志。** 需求和决策与命令输出、diff、测试结果、调试细节混在一起。

Orch-lite 改变的是时间结构：

```text
人的工作流 ─────────────────────────────────→
Agent A       ───────────────→
Agent B             ───────────────→
Agent C                    ───────────────→
```

Agent 持续工作，人也持续前进。

![Orch-lite：两条时间线解耦](docs/orch-lite.png)

---

## 核心思路

Orch-lite 让**人的工作流与 Agent 的执行拥有独立的时间线。**

典型流程变成：

1. 你提出任务 A。
2. Orch-lite 将 A 派发到后台执行。
3. 你继续聊天、思考，或者开始考虑 B。
4. A 完成后停在需要关注的检查点。
5. 你审核 A，并决定继续、修改还是整合。
6. 与此同时，其他不存在逻辑依赖的工作可以继续推进。

最重要的区别是：

```text
不是：
    解耦任务 A 与任务 B

而是：
    解耦 Agent 的执行时间
              与
          人的等待时间
```

**逻辑依赖仍然存在，人的决策权仍然存在，改变的是等待。**

---

## 为什么是 Orch-lite？

### 人可以继续工作

Agent 可以花几分钟运行测试、调试，而不必占住整个交互循环。你不需要盯着 Agent 工作，可以继续思考自己的事情。

### 人仍然掌握决策权

后台执行不等于自主决策。当结果需要审核、修改、整合或方向判断时，决策仍然回到人手中。

**改变的是等待，不是人的决策权。**

### 对话保持干净

主会话应该承载需求、想法、问题、决策与审核，而不是持续堆积执行日志。后台 Agent 负责操作细节，主会话保持对目标与方向的关注。

---

## 快速开始

### ZCode

打开 **设置 → 插件 → 个人**，点击 **Create → Add marketplace**，输入 GitHub 仓库 `LYJ132/orch-lite` 作为来源，点击 **Create**。刷新 marketplace 后，在 Orch-lite 插件卡片上点击 **Install**。

### Codex

从 CLI 添加 marketplace 并安装：

```bash
codex plugin marketplace add LYJ132/orch-lite
codex plugin add orch-lite
```

或打开 Codex 运行 `/plugins` 浏览安装。安装后运行 `/hooks` 审核并信任内置 hooks。

> 插件版本 1.2.0+ 内置了 Codex hooks（`sessionStart`、`preToolUse`、`subagentStart`）。启用 multi-agent v2 与信任 hooks 见 [docs/codex-setup.md](docs/codex-setup.md)，SubagentStart hook 设计说明见 [docs/codex-subagent-start.md](docs/codex-subagent-start.md)。

> **Codex 支持目前是实验性的。** 已可用的部分：sessionStart 上下文注入；SubagentStart hooks（审计、cwd 策略、handbook 注入——尚待实际运行验证）；原生 multi-agent v2 派发。尚不可用的部分：`preToolUse` 在 Codex 上不会对子 agent 派发触发，因此派发包门禁在该路径上没有 hook 强制；且 agent 间消息载荷是加密的、模型无法读取，派发中的 `acceptance_criteria` 与 handbook 指令不会到达子 agent——验收核验因此改为父侧事后检查。这两项限制都需要上游平台修复。详见 [docs/codex-setup.md](docs/codex-setup.md)、[docs/codex-subagent-start.md](docs/codex-subagent-start.md)。

### Claude Code

仓库从最初就带有 Claude Code 插件清单（`.claude-plugin/plugin.json` + `marketplace.json`，版本随主线为 1.2.0），因此插件安装与 skill 加载预期可用。内置 hooks 在 Claude Code 上能否加载并生效尚未验证：可能原样可用，也可能不可用——目前尚未做任何测试，验证待完成。

---

## Orch-lite 与 Multi-Agent

Orch-lite 会在后台执行适合的场景中使用多个 Agent，但 **Multi-Agent 是手段，不是产品目标。**

| | Multi-Agent 系统 | Orch-lite |
|---|---|---|
| 主要关注 | Agent 之间如何协作 | 人与 Agent 如何共同工作 |
| 核心问题 | Agent 应该如何一起工作？ | Agent 工作时，人为什么必须等待？ |
| 主要机制 | 多 Agent 与协作机制 | 后台执行与任务连续性 |
| 人的角色 | 因系统而异 | 仍然负责重要决策 |

Orch-lite 不追求 Agent 数量，不以 Agent swarm 为目标，也不是一个通用的分布式调度系统。

它真正想问的是：

> **Agent 在工作，为什么你的工作也必须停下来？**

---

## 设计原则

### 1. 解耦

**人和 Agent 不必按照同一只时钟工作。**

这里解耦的不是任务依赖。如果 B 依赖 A，那么 B 仍然依赖 A 的结果。我们要做的是防止这种依赖不必要地变成人的等待时间。

### 2. 决策权始终在人手中

机器可以并行执行，人仍然掌握重要决策：

```text
Agent 执行
    ↓
需要方向 / 审核
    ↓
人做决定
    ↓
Agent 继续
```

后台执行并不意味着把控制权交出去，而是让 Agent 工作时，人也可以继续自己的工作流。

### 3. Multi-Agent 是手段，不是目的

后台 Agent、任务状态、Git、worktree 等机制，都是为了支持上述工作方式而存在的实现手段，而不是 Orch-lite 本身的最终目标。

---

## 它是怎么工作的？

从用户视角看，Orch-lite 主要做四件事：

1. **派发执行** — 主会话负责理解意图、对话、路由与决策；具体写入和执行工作交给后台 Agent。
2. **任务状态落盘** — `.orch-lite/index.json` 独立记录后台任务，不依赖某一次会话。
3. **需要时隔离并行工作** — 通过 Git 分支和 worktree，在并发任务真正需要时隔离工作区。
4. **复用已有工作与结论** — 优先利用已有 Agent 上下文和历史任务结论，减少重复劳动。

<details>
<summary>技术架构</summary>

### 主会话与子 Agent

Orch-lite 通过两份 Skill 划分职责：

| Skill | 面向 | 职责 |
|---|---|---|
| `orch-lite` | 主会话 | 理解意图、路由请求、派发任务、协调状态、整合成果 |
| `orch-lite-executor` | 子 Agent | 在工作区、提交和报告边界内执行被派发的任务 |

主会话聚焦人与 Agent 的交互工作流，子 Agent 负责具体执行。

### 任务追踪：`.orch-lite/index.json`

后台任务状态落在磁盘上，而不是某一次对话里。因此即使会话结束或 Agent 发生变化，任务仍然可以被查询和恢复。

任务记录包括目标、验收标准、状态、产物以及实际执行 Agent 等信息。

### 隔离与并行

Git 隔离按实际并发需求启用：

- 单个任务可以直接在对应 feature 分支上工作；
- 当另一个任务需要并行执行时，可以为它建立独立的 Git worktree；
- 子 Agent 不直接把结果整合进 `main`，整合保持为受控步骤；
- 如果整合发生冲突，可以把决策交还给人。

```text
          Repository
   ┌──────────┼──────────┐
   ↓          ↓          ↓
 Task A     Task B     Task C
 worktree   worktree   worktree
   │          │          │
   ↓          ↓          ↓
 Agent A    Agent B    Agent C
```

### 复用

派发新任务前，Orch-lite 可以检查相关任务历史并复用已有结论。如果已有 Agent 上下文仍然有价值，也可以继续使用，而不是重新建立上下文。

跨任务沉淀的经验与契约可以另存于 `.orch-lite/memory/shared.json`，供后续任务读取复用。

</details>

---

## Orch-lite 不做什么

Orch-lite 有意不试图解决所有问题：

- **不会**消除逻辑任务依赖；
- **不会**让所有任务都可以并行；
- **不会**让 Agent 完全自主；
- **不会**取消人的审核与决策；
- **不会**以增加 Agent 数量为目标；
- **不会**用自主 Agent swarm 取代人的工作流。

它改变的是**人在什么时候需要等待**，而不是**工作本身依赖什么**。

---

## 常见问题

### Orch-lite 是另一个 Multi-Agent 框架吗？

不是以此为主要目标。Multi-Agent 是 Orch-lite 可以使用的一种实现机制，真正要解决的是 Agent 执行时间与人的等待时间之间的绑定。

### 后台执行是不是意味着 Agent 更加自主？

不是。后台执行只是把执行与等待分离，并没有取消人的决策节点。

### 有依赖关系的任务也可以并行吗？

只有在逻辑依赖允许的情况下才可以。如果 B 必须依赖 A 的结果，那么 B 仍然需要等待 A 的结果。Orch-lite 不会因为后台执行而消除真实的任务依赖。

### 执行细节去哪了？

执行发生在后台任务自己的上下文和工作区中。主会话可以主要承载需求、决策与审核，而不必承载全部执行细节。

---

## 结语

Orch-lite 不试图让人变得不再重要。

它只是让**那些并非工作本身所要求的等待，不再阻塞人的工作流。**

```text
Agent 去工作。
人继续前进。
```

**让 Agent 去工作，让人的工作流继续。**
