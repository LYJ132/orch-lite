# Orch-lite

[English](#english) · [中文](#中文)

<a id="english"></a>

## English

**Let agents work. Keep the human workflow moving.**

Orch-lite is a lightweight background-execution skill for Coding Agents.

Its core is a single idea: **decouple agent execution from human conversation and decision-making.**

When an agent takes on time-consuming work — modifying code, running tests, debugging, generating documentation — the work no longer occupies the current session while it runs. It is dispatched to a background agent instead. Meanwhile, the human can keep thinking, asking questions, adding requirements, adjusting direction, or starting the next task.

The agent keeps working, and the human workflow is never interrupted.

---

## The Problem: Two-Way Blocking in a Serial Interaction

A traditional Coding Agent interaction is a serial process:

```
Human makes a request
        ↓
Agent starts executing
        ↓
Human waits for the agent
        ↓
Agent finishes
        ↓
Human reviews the result
        ↓
Human makes the next request
```

Natural as it looks, this flow blocks in both directions.

### The human waits for the agent

While the agent modifies code, runs tests, or debugs, the human can usually only wait — but thinking does not stop. During the wait, the human may already have:

- formed a new requirement;
- spotted a flaw in the current approach;
- needed to ask about a concept;
- needed to schedule another independent piece of work;
- been ready to start the next task.

Yet the agent is still executing. **The agent's execution time becomes the human's waiting time.**

### The agent also waits for the human

The blocking runs the other way too. During execution, agents regularly need a human to:

- provide direction;
- answer a question;
- confirm a plan;
- decide the next step;
- review a result.

The traditional flow is therefore a chain of alternating waits:

```
Human → Agent → Human → Agent → Human → Agent
```

**Human decisions and agent execution are bound to one timeline.** The human must wait for the agent, and the agent must wait for the human. Most of this waiting is not required by the work itself — it is an artifact of the interaction model.

---

## Long Sessions Are Polluted by Execution Content

A typical coding-agent session grows continuously:

```
Request → Analysis → Tool calls → Edits → Terminal output
   → Tests → Errors → Debugging → Re-edits → Re-tests → ...
```

This content is indispensable for finishing the current task, but it is not the most important information for an ongoing conversation. As work progresses, the main session accumulates:

- code and diffs;
- logs and test results;
- debugging traces and tool calls;
- transient errors and large amounts of execution detail.

The result: **a session meant to carry requirements, ideas, and decisions gradually degenerates into the agent's execution log.** It hurts readability and inflates the context.

---

## Decoupling: Two Independent Timelines

The point of Orch-lite is not more agents, but **giving the human workflow and agent execution two independent timelines.**

![Orch-lite: two decoupled timelines](docs/orch-lite.png)

The diagram compares the two interactions:

- **Top (traditional):** the agent's Task A/B/C and the human's Read & Send blocks are serially staggered — the human waits while a task runs, and the agent starts the next task only after the human sends a message. Both sides wait on each other.
- **Bottom (Orch-lite):** Task A/B/C form a continuous pipeline, with the human's Send and Read & Send blocks interleaved with task execution. The agent keeps advancing, and the human keeps working.

The two timelines are no longer synchronized: the human's decision flow stays continuous while agent execution proceeds in parallel in the background.

---

## Three Levels of Decoupling

### Workflow decoupling

While an agent executes a task, the human does not need to stop working.

```
Human workflow:  ─────────────────────────────→
Agent A:         ──────────→
Agent B:              ─────────────→
Agent C:                   ───────────→
```

Agent execution time is no longer equivalent to human waiting time.

Waiting does not disappear entirely: live searches, complex discussions, and pending human decisions still require the main session. What Orch-lite does is **move unnecessary waiting out of the human workflow.**

### Context decoupling

The details needed to execute a task no longer pile up in the main session:

```
Main session                 Background agent
├── Requirements             ├── File edits
├── Ideas                    ├── Tool calls
├── Direction                ├── Tests
├── Questions                ├── Logs
├── Decisions                ├── Debugging
└── Review results           └── Execution detail
```

The main session stays clean. Execution detail still exists and is tracked by the task system, but it no longer occupies the center of the conversation. This yields a cleaner main-session context, less redundant execution content, longer-lived sessions, and — in suitable cases — lower token consumption. Token savings are a consequence of context decoupling, not the design goal.

### Attention and cognitive decoupling

The main session should carry questions like:

- What is the goal?
- Why do it this way?
- Where is the direction?
- What are the open problems?
- What are the trade-offs?
- What is the next step?

Not:

- What did the agent just execute?
- What did that command print?
- Why did that test fail?
- What happened on a specific line of a specific file?

The latter is essential for execution, but it should not occupy the center of the conversation. **The main session is a space for thinking, not an execution log.** When it is focused on requirements, direction, and decisions, the agent can devote its attention to understanding real intent rather than burning context on execution detail.

---

## Decisions Stay with the Human

Decoupling execution from interaction does not mean removing the human from the workflow.

Orch-lite's goal is not agents deciding everything on their own, but: **machines work in parallel; key decisions remain with the human.**

```
Agent executes → needs direction → hands back → human decides → agent continues
```

```
Agent A and Agent B executing
   → A completes → human reviews A → human decides continue / revise / integrate
```

The human decision flow is fully preserved. What changes is only this: **the human no longer pauses their own work waiting for an agent to finish.**

What is reduced is waiting, not the human.

---

## Multi-Agent Is a Means, Not the Goal

Background agents, task state, Git, and worktrees exist to serve the goals above. Orch-lite does not attempt to:

- build an agent swarm;
- make large numbers of agents collaborate autonomously;
- build a general-purpose distributed scheduler;
- maximize agent count;
- support agents running unattended for long periods.

The question it answers is: **why must a human stop working while an agent works?**

Multi-agent is an implementation means, not a product goal.

---

## How It Works

### Main session and child agents: roles defined by two skills

Orch-lite does not rely on a platform-provided role system. Responsibilities are split across two skill documents:

| Skill | Audience | Responsibility |
|---|---|---|
| orch-lite | Main session | Understand intent, route every request, dispatch tasks, coordinate state, integrate results; handles conversation and read-only actions directly, dispatches every write |
| orch-lite-executor | Child agent | The dispatched executor's handbook: workspace boundaries, incremental-commit discipline, completion and failure reporting |

A child agent's first action after dispatch is to read the executor handbook — the rules in the dispatch package are only a summary; the handbook is canonical. The main session never executes work itself, and a child agent never spawns further agents.

### Task tracking: index.json

Background tasks do not live inside any session. Their state is recorded in `.orch-lite/index.json` at the project root:

```json
{
  "tasks": {
    "impl-20260911-01": {
      "role": "impl",
      "feature_id": "login-api-fix",
      "status": "assigned",
      "objective": "Fix the 500 error of the login API",
      "acceptance_criteria": ["login API returns 200"],
      "output": null,
      "products": [],
      "agent_id": null,
      "created_at": "2026-09-11T10:00:00+08:00",
      "completed_at": null
    }
  }
}
```

It is a flat structure keyed solely by task_id, recording role, feature, status, objective, acceptance criteria, products, and the agent actually executing the task. The main session is the exclusive writer: creating an entry at dispatch, updating results when a child reports. Sessions may end and agents may change; task state is always on disk — queryable and resumable.

### Isolation and parallelism: feature branches and worktrees

- Each feature maps to one long-lived branch, `feature/<feature_id>`; all of the feature's tasks progress on that line.
- Isolation is lazy: with a single task, the child works directly on the feature branch in the primary working tree, with zero extra overhead; when a task is already running and a new one arrives, the newcomer gets its own git worktree (`.worktrees/<task_id>/`).
- Children never commit to main; main only receives integration merges performed by the main session. A pre-merge conflict check stops and hands the decision to the human when conflicts exist.

```
          Repository
   ┌──────────┼──────────┐
   ↓          ↓          ↓
 Task A     Task B     Task C
 worktree   worktree   worktree
   │          │          │
   ↓          ↓          ↓
 Agent A    Agent B    Agent C
```

### Child-agent reuse

Before dispatching a new task, the main session reads the feature's history in the index and avoids duplicate work through two layers of reuse:

1. **Session reuse (continuation):** if the agent of a completed task covering the same scope is still resumable, the main session prefers sending it a continuation package (new objective + delta context) over creating a fresh agent. A fresh child is created only when a parallel slot is needed or the old context has become a liability.
2. **Conclusion reuse (reuse loop):** when the feature already has tasks in the index, the dispatch package must carry a `reuses` field listing the historical task_ids the main session actually read. The dispatch-validation hook enforces this: omission is denied with a digest of the history, and unknown ids are denied as well. The child builds on prior conclusions instead of re-deriving them.

The dispatch package itself (objective + acceptance criteria) is the complete definition of an agent — there is no registry and no predefined roles; the agent is whatever the task requires. Experiences and contracts that survive across tasks are stored separately in `.orch-lite/memory/shared.json` for the main session and child agents to read and reuse.

---

## Closing

Orch-lite does not try to replace human work with agents. It changes the time structure of how humans and agents work together:

```
Traditional:
Human ──→ Agent
  ↑          │
  └──────────┘
   mutual waiting

Orch-lite:
Human workflow ──────────────────────────→
Agent A   ─────────────→
Agent B        ─────────────→
Agent C             ────────────→
```

The goal is not to remove the human from the workflow, but **to remove unnecessary waiting from the workflow.**

Let agents work. Keep the human workflow moving.

---

<a id="中文"></a>

## 中文

**让 Agent 去工作，让人的工作流继续。**

Orch-lite 是一个面向 Coding Agent 的轻量级后台执行 Skill。

其核心只有一点：**将 Agent 的执行与人的对话和决策解耦。**

当 Agent 承担修改代码、运行测试、调试、生成文档等耗时工作时，不再占住当前会话等待执行结束，而是将具体工作派发给后台 Agent。与此同时，人可以继续思考、提问、补充需求、调整方向，或启动下一个任务。

Agent 持续工作，人的工作流也不中断。

---

## 问题：串行交互中的双向阻塞

传统 Coding Agent 的交互是一个串行过程：

```
人提出需求
    ↓
Agent 开始执行
    ↓
人等待 Agent
    ↓
Agent 执行完成
    ↓
人查看结果
    ↓
人提出下一个需求
```

这一流程看似自然，实际上在两个方向上都存在阻塞。

### 人在等待 Agent

Agent 修改代码、运行测试、调试问题期间，人通常只能等待其完成，但人的思考并不会因此停止。等待期间可能已经：

- 产生了新的需求；
- 发现了既有方案的问题；
- 需要追问某个概念；
- 需要安排另一件独立工作；
- 准备启动下一个任务。

而此时 Agent 仍处于执行状态。**Agent 的执行时间，直接成为人的等待时间。**

### Agent 也在等待人

另一个方向的阻塞恰好相反。Agent 在执行过程中经常需要等待人：

- 提供方向；
- 回答问题；
- 确认方案；
- 决定下一步；
- 审核结果。

传统流程因此成为一条交替等待的链：

```
人 → Agent → 人 → Agent → 人 → Agent
```

**人的决策与 Agent 的执行被绑定在同一条时间线上。** 人必须等待 Agent，Agent 也必须等待人。多数情况下，这种等待并非工作本身的要求，而是当前交互方式造成的结果。

---

## 长会话被执行内容污染

Coding Agent 的典型会话会不断变长：

```
用户需求 → Agent 分析 → 工具调用 → 代码修改 → 终端输出
   → 测试 → 报错 → 调试 → 再次修改 → 再次测试 → ...
```

这些内容对完成当前任务不可或缺，但并非长期交流中最重要的信息。随着任务推进，主会话会持续堆积：

- 代码与 diff；
- 日志与测试结果；
- 调试过程与工具调用；
- 临时错误与大量执行细节。

其结果是：**原本用于承载需求、想法和决策的会话，逐渐退化为 Agent 的执行日志。** 这既影响阅读，也使上下文不断膨胀。

---

## 解耦：两条独立的时间线

Orch-lite 的关键不在于增加 Agent 的数量，而在于**让人的工作流与 Agent 的执行各自拥有独立的时间线。**

![Orch-lite：两条时间线解耦](docs/orch-lite.png)

图中对比了两种交互：

- **上半部分（传统模式）**：Agent 的 Task A/B/C 与人的 Read & Send（阅读并发送）串行错开——任务执行时人等待，人发出消息后 Agent 才开始下一项工作，双方相互等待。
- **下半部分（Orch-lite）**：Task A/B/C 紧密衔接为连续流水线，人的 Send 与 Read & Send 穿插于任务执行期间。Agent 持续推进，人也持续工作。

两条时间线不再同步：人的决策流程保持连续，Agent 的执行在后台并行推进。

---

## 三个层面的解耦

### 工作流解耦

Agent 执行任务时，人无需停止自己的工作。

```
人的工作流：  ─────────────────────────────→
Agent A：     ──────────→
Agent B：          ─────────────→
Agent C：                 ───────────→
```

Agent 的执行时间不再等价于人的等待时间。

等待不会完全消失：即时搜索、复杂讨论、等待人做决定等工作仍需主会话亲自完成。Orch-lite 的作用是**将原本不必要的等待移出人的工作流。**

### 上下文解耦

执行任务所需的大量细节不再堆积于主会话：

```
主会话                      后台 Agent
├── 用户需求                ├── 文件修改
├── 想法                    ├── 工具调用
├── 方向                    ├── 测试
├── 问题                    ├── 日志
├── 决策                    ├── Debug
└── 审核结果                └── 执行细节
```

主会话因此保持整洁。执行细节依然存在、可被任务系统追踪，但不持续占据交流的主要空间。这带来更干净的主会话上下文、更少的冗余执行内容、更易维持的长会话，并在适当场景下降低 Token 消耗——Token 节省是上下文解耦的结果，而非设计目标。

### 注意力与认知解耦

主会话承载的核心内容应是：

- 目标是什么；
- 为什么这样做；
- 方向在哪里；
- 存在哪些问题；
- 如何取舍；
- 下一步做什么。

而非：

- Agent 刚刚执行了什么；
- 某条命令的输出是什么；
- 某个测试为何失败；
- 某个文件的某一行发生了什么。

后者对执行至关重要，却不应持续占据交流的中心。**主会话应是人与 Agent 思考的空间，而非执行日志。** 当主会话聚焦于需求、方向与决策时，Agent 也能将更多注意力用于理解真实意图，而不是在执行细节中消耗上下文。

---

## 决策权始终在人手中

执行与交互的解耦，并不意味着将人移出工作流。

Orch-lite 的目标不是让 Agent 自行决定一切，而是：**机器并行工作，关键决策仍由人掌握。**

```
Agent 执行 → 需要方向判断 → 交还给人 → 人做决定 → Agent 继续执行
```

```
Agent A、Agent B 执行中
   → A 完成 → 人审核 A → 人决定继续 / 修改 / 整合
```

人的决策流程完整保留，改变的只是：**人不再为等待 Agent 完成而暂停自己的工作。**

减少的是等待，不是人。

---

## Multi-Agent 是手段，不是目的

后台 Agent、任务状态、Git、worktree 等机制，服务于上述目标而存在。Orch-lite 并不试图：

- 构建 Agent swarm；
- 让大量 Agent 自主协作；
- 建立通用分布式调度系统；
- 追求 Agent 数量；
- 支持 Agent 长时间无人自主运行。

它要回答的问题是：**Agent 工作时，人为什么必须停止工作？**

Multi-Agent 是实现手段，而非产品目标。

---

## 实现机制

### 主会话与子 Agent：两份 Skill 定义的分工

Orch-lite 不依赖平台预置的角色体系，而是通过两份 Skill 文档划分职责：

| Skill | 面向 | 职责 |
|---|---|---|
| orch-lite | 主会话 | 理解意图、对每个请求做路由判断、派发任务、协调状态、整合成果；只直接处理对话与只读操作，一切写操作都派发 |
| orch-lite-executor | 子 Agent | 被派发者的执行手册：工作区边界、增量提交纪律、完成与失败的报告格式 |

子 Agent 收到派发后的第一个动作是读取 executor 手册——派发包中的规则只是摘要，手册才是准绳。主会话不亲自执行，子 Agent 也不再派生新的 Agent。

### 任务追踪：index.json

后台任务不依附于任何会话存在，其状态记录在项目根目录的 `.orch-lite/index.json`：

```json
{
  "tasks": {
    "impl-20260911-01": {
      "role": "impl",
      "feature_id": "login-api-fix",
      "status": "assigned",
      "objective": "Fix the 500 error of the login API",
      "acceptance_criteria": ["login API returns 200"],
      "output": null,
      "products": [],
      "agent_id": null,
      "created_at": "2026-09-11T10:00:00+08:00",
      "completed_at": null
    }
  }
}
```

这是以 task_id 为唯一主键的扁平结构，记录角色、所属特性、状态、目标、验收标准、产物与实际执行该任务的 Agent。主会话独占写入：派发时创建条目，子 Agent 报告后更新结果。会话可以结束、Agent 可以更替，任务状态始终落盘、可查、可恢复。

### 隔离与并行：feature 分支与 worktree

- 每个特性对应一条长生命周期分支 `feature/<feature_id>`，该特性的任务都在这条线上推进；
- 隔离按需启用：只有一个任务时，子 Agent 直接在主工作树的 feature 分支上工作，零额外开销；已有任务在执行、新任务到来时，新任务获得独立的 git worktree（`.worktrees/<task_id>/`）；
- 子 Agent 永不提交到 main，main 只接收主会话执行的整合合并；合并前进行冲突预检，存在冲突时停下，交由人决定。

```
          Repository
   ┌──────────┼──────────┐
   ↓          ↓          ↓
 Task A     Task B     Task C
 worktree   worktree   worktree
   │          │          │
   ↓          ↓          ↓
 Agent A    Agent B    Agent C
```

### 子 Agent 的复用

派发新任务前，主会话先查阅 index 中该特性的历史，通过两层复用避免重复劳动：

1. **会话复用（continuation）**：若已完成的同范围任务对应的 Agent 仍可恢复，优先向其发送续作包（新目标 + 增量上下文），而非新建 Agent；仅在需要并行槽位、或旧上下文已成为负担时才新派。
2. **结论复用（reuse loop）**：该特性在 index 中已有任务时，派发包必须携带 `reuses` 字段，列出主会话实际读过的历史 task_id。派发校验 hook 强制执行该约束：遗漏会被拒绝并返回历史摘要，填写未知 id 同样会被拒绝。子 Agent 据此在前序结论上继续，而非重新推导。

派发包本身（目标 + 验收标准）即 Agent 的全部定义——没有注册表，没有预设角色，任务需要什么，Agent 就是什么。跨任务沉淀下来的经验与契约另存于 `.orch-lite/memory/shared.json`，供主会话与子 Agent 读取复用。

---

## 结语

Orch-lite 不试图让 Agent 取代人的工作，而是改变人与 Agent 共同工作的时间结构：

```
传统模式：
人 ──→ Agent
↑        │
└────────┘
   相互等待

Orch-lite：
人的工作流 ─────────────────────────────→
Agent A   ─────────────→
Agent B        ─────────────→
Agent C             ────────────→
```

目标不是让人退出工作流，而是**让不必要的等待退出工作流。**

让 Agent 去工作，让人的工作流继续。
