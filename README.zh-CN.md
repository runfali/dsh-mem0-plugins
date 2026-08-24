# dsh-mem0-plugins

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Node](https://img.shields.io/badge/node-%E2%89%A522-green.svg)](package.json)
[![Platform](https://img.shields.io/b/platform/DeepSeek%20Harness-orange)](https://deepseek.com)

[English](README.md) | 简体中文

为 **DeepSeek Harness (dsh)** web profile 提供持久记忆，后端为自托管
[Mem0](https://github.com/mem0ai/mem0) server。插件让智能体零手工获得长期记忆：
回答前自动召回相关记忆，每轮对话结束后自动把内容提炼成事实写回服务端。

> [!IMPORTANT]
> **兼容性——请先阅读。** 本插件对接的是
> [`dlhermes/mem0_falkordb`](https://github.com/dlhermes/mem0_falkordb)
> 项目的自定义 HTTP API（`X-API-Key` 鉴权、`POST /search`、
> `POST/PUT/DELETE /memories`、`POST /evolve/feedback`），**仅适用于**
> 从该项目部署的 server。不支持 Mem0 Cloud，也不兼容 mem0 官方 OSS REST/SDK
> API，不能直接用于其他 Mem0 部署。

以标准 dsh bundle 插件交付：`dsh plugin add` 安装、`dsh plugin remove`
卸载，**不改任何 dsh 源码**。

---

## 目录

- [自动行为](#自动行为)
- [模型工具](#模型工具)
- [环境要求](#环境要求)
- [安装](#安装)
- [配置](#配置)
  - [连接与身份](#连接与身份)
  - [自动召回与查询蒸馏](#自动召回与查询蒸馏)
  - [自动写入（潮浪并忆）](#自动写入潮浪并忆)
  - [可靠性与超时](#可靠性与超时)
- [召回设计](#召回设计)
- [可靠性设计](#可靠性设计)
- [可观测性](#可观测性)
- [开发与测试](#开发与测试)
- [排障](#排障)
- [文档](#文档)
- [许可证](#许可证)

## 自动行为

| 能力 | 触发时机 | 说明 |
|---|---|---|
| **工具驱动召回** | 每次回答前 | 系统提示中的常驻 usage 节引导模型先调 `mem0_search`；UI 工具卡即召回动作的可见呈现；长查询先蒸馏再搜索。 |
| **强制召回步** | 每轮第一步 | 经 `agent/pre-step` 注入 plugin-source 提醒「先搜记忆再作答」。琐碎轮自动跳过；`forceRecallStep` 可关。 |
| **自动写入** | 每轮对话结束 | 把「用户消息 + 助手回复」交给服务端 LLM 抽取事实（`infer: true`）；纯 JSON 的工具输出替换为占位符，键名不会混入「事实」。 |
| **潮浪并忆** | 写入时 | 同一会话短对话按 user 分桶合并：空闲 5 s / 窗口 15 s / 5 轮 / 4000 字符任一达标即合并为一次批量写入，摊薄服务端抽取调用；超长消息（>2000 字符）绕过桶快速直写。 |
| **进化反馈闭环** | update/delete 后 | 尽力而为上报 `POST /evolve/feedback`（`correction` / `useless`），参与服务端 salience 进化。 |

被打断的轮次永不写入：半截流式回复不是持久的对话真相。

## 模型工具

注册四个模型工具：

| 工具 | 用途 |
|---|---|
| `mem0_search` | 语义搜索用户记忆（支持单次 `top_k` / `rerank` 覆盖）。 |
| `mem0_add` | 逐字存储持久事实——不走服务端 LLM 抽取。 |
| `mem0_update` | 按 ID 修正已有记忆（上报 `correction` 反馈）。 |
| `mem0_delete` | 按 ID 遗忘（上报 `useless` 反馈）。 |

## 环境要求

- Node.js ≥ 22 与可用的 [DeepSeek Harness](https://deepseek.com) 安装（web profile）。
- 一台从 [dlhermes/mem0_falkordb](https://github.com/dlhermes/mem0_falkordb)
  部署并可通过 HTTP 访问的 server（如 `http://127.0.0.1:8888`）。
- 服务端开启鉴权时需在其 Dashboard 创建 API Key；`AUTH_DISABLED=true`
  部署留空即可。

## 安装

```bash
# 安装到 web profile（安装后重启 dsh 生效）
dsh plugin --profile web add /path/to/dsh-mem0-plugins

# 卸载
dsh plugin --profile web remove dsh-mem0-plugins
```

插件**默认启用**：指向本机 `AUTH_DISABLED` server 时零配置可用。
设置页改动即时生效，无需重启。要彻底关闭记忆，在设置卡片里关掉
「启用插件」开关即可；卡片头部实时显示启用状态与 host。

## 配置

所有设置位于 dsh 设置页 `mem0` 命名空间下，设置页保存的用户值优先于
profile 层默认值。

### 连接与身份

| 键 | 默认 | 说明 |
|---|---|---|
| `enabled` | `true` | 总开关。关闭后不召回、不写入，工具返回「插件未启用」。 |
| `host` | `http://127.0.0.1:8888` | 自托管 mem0_falkordb server 地址。 |
| `apiKey` | 空 | 以 `X-API-Key` 头发送；`AUTH_DISABLED` 部署留空。 |
| `userId` | `dsh-user` | 记忆归属 user_id，跨会话共享同一份记忆。 |
| `agentId` | `dsh` | 写入附带的 agent_id。 |

![连接与身份设置](docs/screenshot/settings-connection.png)

### 自动召回与查询蒸馏

| 键 | 默认 | 说明 |
|---|---|---|
| `forceRecallStep` | `true` | 强制召回步（方案 B）：每轮注入「必须先调 `mem0_search`」提醒（琐碎轮跳过）。关闭则只靠 usage 引导。 |
| `topK` | `10` | 每次召回最大条数（1–50）。 |
| `rerank` | `false` | 以全深度模式请求重排（服务端需配置 reranker）。 |
| `distillEnabled` | `true` | 查询蒸馏总开关（见下文）。 |
| `distillMinChars` | `500` | 不超过该长度的消息原样直查 `/search`——零损失零开销。 |
| `distillInputMaxChars` | `8000` | 送入蒸馏模型的原文截断上限。 |
| `distillBaseUrl` | 作者私有端点 | 蒸馏长查询用的 OpenAI 兼容端点；留空跳过蒸馏。**出厂默认指向作者内网部署——请改成你自己的端点。** |
| `distillApiKey` | 作者私有 Key | 蒸馏端点 Bearer Token。 |
| `distillModel` | `Qwen3.5-9B` | 蒸馏模型 id（本地小模型足矣）。 |
| `distillTimeoutMs` | `90000` | 蒸馏单次超时。 |
| `distillRetryAfterMs` | `20000` | 双飞触发阈值：首请求超过该时长仍无响应即并发第二请求，先完成者胜出。 |

![召回设置：条数、重排、蒸馏](docs/screenshot/settings-recall-search.png)

![蒸馏模型、超时与双飞](docs/screenshot/settings-recall-distill.png)

### 自动写入（潮浪并忆）

| 键 | 默认 | 说明 |
|---|---|---|
| `syncEnabled` | `true` | 每轮结束写入总开关。 |
| `coalesceEnabled` | `true` | 短对话分桶合并写入；关闭则逐条直写。 |
| `coalesceIdleMs` | `5000` | 桶内空闲冲刷阈值。 |
| `coalesceWindowMs` | `15000` | 桶窗口冲刷阈值。 |
| `coalesceMaxTurns` | `5` | 桶内轮数上限。 |
| `coalesceMaxChars` | `4000` | 桶内字符上限。 |
| `fastpathChars` | `2000` | 单轮超过该长度绕过桶直接落库。 |
| `feedbackEnabled` | `true` | update/delete 成功后上报 evolve 反馈。 |

![写入设置：合并阈值、快速直写、进化反馈](docs/screenshot/settings-write-back.png)

### 可靠性与超时

| 键 | 默认 | 说明 |
|---|---|---|
| `queueMaxLen` | `50` | 待写队列上限，满时丢最旧。 |
| `breakerThreshold` | `5` | 连续失败达该次数熔断。 |
| `breakerCooldownMs` | `120000` | 熔断冷却时长，到期后半开重试。 |
| `requestTimeoutMs` | `300000` | search/add 共用的单请求硬上限（对齐 hermes `httpx timeout=300.0`；服务端 LLM 兜底最坏约 180 s）。有意不设第二层工具级超时。 |

![可靠性设置：队列、熔断、总闸](docs/screenshot/settings-reliability.png)

修改 profile 层默认值（对本机全部用户生效），在
`~/.dsh/profiles/web/cordis.patch.yml` 追加：

```yaml
- id: mem0
  config:
    enabled: true
    host: http://mem0.internal:8888
    apiKey: your-admin-api-key
```

## 召回设计

![强制召回提醒 + 中文关键词多路 mem0_search 召回](docs/screenshot/recall-demo.png)

- **显式工具链路。** 不做后台静默预取——dsh 平台在消息回显后没有内容注入钩子
  （平台时序分析见 [docs/COMPARISON.md](docs/COMPARISON.md)）。模型按 usage
  引导调用 `mem0_search`，工具卡让召回过程可见；蒸馏、双飞、熔断全套在
  工具内部生效。
- **强制召回步（默认开）。** 每轮第一步注入 plugin-source 提醒
  （「必须先调 `mem0_search` 再回答」），UI 中渲染为折叠的上下文注入行。
  它不写记忆、琐碎轮跳过、`forceRecallStep` 可关。
- **琐碎输入守卫**（[src/guards.js](src/guards.js)）。纯问候 / 确认 /
  斜杠命令按词表三分类，只做整串匹配——正常句子永不误伤。
- **查询蒸馏。** 移植自 hermes
  `agent/memory_manager.py::_distill_query`，只作用于**召回查询**，
  从不触碰写入路径：
  1. 查询 ≤ `distillMinChars`：原样直查；
  2. 超长查询（贴日志/代码）：截断到 `distillInputMaxChars`，由小模型提炼成
     2–4 个关键词的检索意图再去检索；
  3. 语言漂移防护：中文输入的蒸馏结果若出现越南语重音字符或其他非拉丁非 CJK
     文字（实测的小模型路由漂移症状），判为污染即拒绝；
  4. 并发双飞：首请求无响应即并发第二请求，先完成者胜出；
  5. 全部失败：回退原始 query——检索永不静默失效。

## 可靠性设计

- **熔断器**：连续失败达 `breakerThreshold` 次暂停所有 mem0 流量，
  `breakerCooldownMs` 冷却后半开恢复。404 / not found 类客户端错误不计入熔断。
- **连接级重试**：连接拒绝/DNS 类失败自动重试一次——此时请求大概率没到达
  服务端，不会造成重复写入。
- **有界队列**：待写队列上限 `queueMaxLen`（满则丢最旧），服务端长时间不可用
  也不会内存膨胀。
- **兜底冲刷**：插件停止时冲刷全部未落库的合并桶——排队中的记忆绝不丢失。

## 可观测性

潮浪并忆与写路径卫生计数落在 **dsh 宿主进程日志**（不打到浏览器）：
插件同时走 `ctx.logger`（内部日志）与 `console.log/warn`（直出宿主 stdout）。
systemd 部署看 `journalctl -u dsh.service -f`；否则看 dsh 进程 stdout。

每次合并冲刷打一条 info 日志，含累计 totals：

```text
[dsh-mem0] mem0 coalesced 3 turn(s) into 1 write (session=<id>, saved 2 call(s), chars=512, trigger=idle; totals: batches=12 savedCalls=34 dropped=0 jsonSanitized=3)
```

| 计数 | 含义 |
|---|---|
| `savedCalls` | 合并为写入省下的服务端抽取调用数（合并 N 轮 = 省 N−1 次）。 |
| `dropped` | 队列满丢最旧的次数（每次另打一条 warn）。 |
| `jsonSanitized` | 写回前被剥除的纯 JSON 消息条数。 |
| `batches` / `direct` | 批量合并写入 / 快速直写次数。 |

队列丢弃打 warn；JSON 剥除与快速直写为 debug 级；熔断开合与直写失败必打 warn。

## 开发与测试

```bash
git clone <本仓库> && cd dsh-mem0-plugins
npm install                # 或 symlink 本机 dsh node_modules 以离线开发
node test/smoke.mjs        # Host 半：apply 链路 + 工具 + 写入路径 + 守卫
node test/client-smoke.mjs # Client 半：bundle 加载 + locale/slot + 设置表单保存真链
```

## 排障

| 现象 | 处置 |
|---|---|
| 工具返回「插件未启用」 | 设置页打开 `enabled` 并确认 `host` 已填。 |
| 「circuit breaker open」 | 服务端连挂多次触发熔断。恢复服务端等冷却结束，或调低 `breakerThreshold`。 |
| HTTP 401 | `apiKey` 缺失或错误——除非服务端 `AUTH_DISABLED=true`，否则必填。 |
| 「server unreachable」 | 先确认可达性：`curl http://<host>/openapi.json`。 |
| 记忆从未被召回 | 该 `userId` 下无相关记忆（查 `GET /memories`），或模型跳过了 `mem0_search`——检查强制召回提醒是否连着工具卡一起被跳过。 |

## 文档

- [docs/COMPARISON.md](docs/COMPARISON.md) —— 与 hermes 原版的设计对比，
  含塑造「工具驱动召回」形态的平台时序约束分析（中文）。

## 许可证

[MIT](LICENSE) © 2026 dsh-mem0 contributors
