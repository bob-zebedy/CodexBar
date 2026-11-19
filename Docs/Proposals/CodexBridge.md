# Codex Bridge 设计方案

**状态：待评审。** Codex Bridge 拟让支持本地 MCP 的 AI 工具把工作交给这台 Mac 上的 Codex，并在发起任务的对话中查看进度、处理审批、调整指令和取得结果。文中的工具名、参数和默认值都是拟议接口。

## 1. 用户怎么用

用户在任意已接入的 AI 工具里说“让 Codex 审查当前项目的并发问题”。该工具调用 `codex_start`，拿到任务 ID 后调用 `codex_wait`。如果 Codex 需要额外权限，用户在原客户端查看具体请求并确认，Codex 在原轮次继续。审查结束后，用户可以追问“修一下第二个问题”，继续使用同一个会话。重新打开客户端后，也能找回自己发起的任务。

第一版面向**本机、用户已授权的客户端、用户选定的项目、由 Bridge 创建的会话**。通用体验以普通 MCP 工具调用为基础。能否在调用方继续其他工作时主动通知它，取决于客户端是否支持后台跟踪。普通客户端只要有一个等待调用在途，Bridge 收到事件后就能返回。

## 2. 谁负责什么

```text
外部 AI 工具
  │ MCP（stdio，每个客户端独立连接）
  ▼
随 CodexBar 分发的本地 MCP 入口
  │ 已认证的本机 IPC
  ▼
CodexBar 主 App 内的 Bridge ── 任务归属、事件游标、待处理请求
  │ 独立控制连接（本机 Unix socket 上的 app-server 协议）
  ▼
Codex app-server ── 会话、轮次、工具执行、历史和实际权限判断
```

- **MCP 入口**由外部客户端启动，负责工具发现、参数校验、结构化结果和客户端表单。建议使用随 App 签名分发的普通用户态可执行文件。选择 `stdio` 可省去本机 HTTP 端口、端口发现和远程访问配置
- **CodexBar 主 App** 持有任务和控制连接。客户端退出只释放该客户端的等待调用，其他客户端及正在运行的 Codex 任务可继续。App 未运行时，入口返回 `bridge_unavailable` 并提示用户打开 CodexBar
- **控制连接**在独立 actor 中完成 `initialize`、校验实际服务端版本并发送 `initialized`。单一读取循环分发出站请求的响应、入站通知和带 ID 的服务端请求，按消息方向与 ID 匹配。普通模式的启动入口负责装配，电源 Helper 不参与
- **现有活动连接**继续承担观察职责。Bridge 可复用 socket、握手、帧编解码和历史分页逻辑，但需要专门的响应写入路径。账户、活动统计和 Bridge 各自管理自己的连接与恢复

现有代码提供了握手、请求与事件分流，以及活动订阅和历史读取。同步请求路径也可以记录完整载荷，控制连接应采用独立的日志策略。[连接实现](../../CodexBar/Services/AppServer/AppServerSession.swift) · [历史读取](../../CodexBar/Services/AppServer/AppServerRequests.swift) · [活动事件](../../CodexBar/Services/Activity/AppServerActivityModels.swift)

## 3. 六个工具的约定

**一项 Bridge 任务对应一个 Codex thread，一次执行对应一个 turn。** 对外的 `taskId` 可直接沿用 `thread.id`，每次操作仍需验证调用方归属。`turnId` 指向具体轮次。`requestId` 是 Bridge 为一条待处理请求分配的标识。`after` 是 Bridge 返回的事件游标。后三者各有用途，不能互换。

| MCP 工具 | 何时调用 / 主要参数 | 对内映射与返回 |
| --- | --- | --- |
| `codex_start` | 开始独立委托。传 `project`、`prompt`、`operationId` | 将授权项目解析为 `cwd`，调用 `thread/start`，登记归属，再调用 `turn/start`。返回 `taskId`、`turnId` 和可从本轮起点读取的 `cursor` |
| `codex_wait` | 看状态或等进展。传 `taskId`，可选 `turnId`、`after`、`timeoutSeconds` | 从 Bridge 事件记录读取，必要时用 `thread/read`、`thread/turns/list`、`thread/items/list` 核对。返回轮次快照、一批有序事件、`nextCursor`、待处理请求和已就绪的结果 |
| `codex_reply` | 追加工作或修改运行中指令。传 `taskId`、`message`、`operationId`，可选 `turnId` | 带 `turnId` 时调用 `turn/steer`，作为 `expectedTurnId` 校验。省略时只在当前无活动轮次时调用 `turn/start`。返回实际接收输入的 `turnId`。轮次不符时返回当前状态，由调用方重新决定 |
| `codex_respond` | 处理 `wait` 指出的审批或结构化提问。传 `taskId`、`requestId` | 找到原服务端请求，收集决定或答案，在对应控制连接上以原 RPC `id` 回复。工具返回此次答复的处理状态，实际执行结果继续从 `wait` 获取 |
| `codex_interrupt` | 停止指定轮次。传 `taskId`、`turnId` | 调用 `turn/interrupt`。RPC 成功表示中断请求已提交，轮次结局取自 `turn/completed` 或历史。已结束时直接返回实际终态。中断不会撤销已经完成的文件修改 |
| `codex_list` | 找回自己发起的任务。可按 `project`、`status` 筛选，以 `cursor` 分页 | 按调用方查询 Bridge 本地索引，以更新时间和任务 ID 稳定排序。返回任务 ID、项目、标题摘要、最近轮次、状态和更新时间。需要校准时读取已知线程，避免开放整个 Codex 历史 |

外部工具通过 `tools/list` 发现这六个工具。每个工具的说明给出适用场景、输入约束和结束条件。优先返回 `structuredContent`，并附等价文本供普通客户端使用。`nextAction` 是 Bridge 提供的可选建议，客户端决定是否调用。下面是一次 `codex_wait` 返回的关键字段。[MCP 工具规范](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)

```json
{
  "taskId": "t1",
  "turnId": "u1",
  "status": "waiting",
  "events": [{"type": "approval_requested", "requestId": "r7"}],
  "pendingRequests": [{"requestId": "r7", "kind": "approval", "summary": "请求为当前测试命令开放网络访问"}],
  "nextCursor": "c14",
  "nextAction": {"tool": "codex_respond", "arguments": {"taskId": "t1", "requestId": "r7"}}
}
```

## 4. 进度、结果与后台跟踪

**轮次状态**为 `running`、`waiting`、`completed`、`failed`、`interrupted`。`waiting` 表示存在阻塞审批或提问；非阻塞提问可以列在 `pendingRequests` 中，同时保留 `running`。当连接中断、状态尚待核对时，标记快照新鲜度为 `reconciling`，保留最后确认的状态及时间。一个 thread 可以先后有多个已结束轮次，任务列表显示最近一轮。

| app-server 输入 | Bridge 对调用方的行为 |
| --- | --- |
| `turn/started`、`item/started`、`item/completed`、`turn/plan/updated` | 报告实际发生的阶段，例如开始运行测试、完成某一步。只有上游提供可用分母时才展示计划步数 |
| `item/agentMessage/delta`、`item/commandExecution/outputDelta` | 按执行项合并并限制摘要大小。命令输出属于任务数据，避免将每一行都变成单独的模型调用 |
| 审批、结构化提问、`serverRequest/resolved` | 立即更新待办并唤醒等待者。待办独立列在快照中，读取一次事件后仍可找回尚未处理的请求 |
| `turn/completed` | 按 `turn.status` 返回实际终态及错误信息。优先读取本轮 `phase: final_answer` 的已完成助手消息，通知缺少正文时分页补读本轮执行项。仅有过程消息时标记最终答复缺失，保留真实执行状态 |

**等待语义。** `timeoutSeconds: 0` 立即查，建议默认及单次上限为 30 秒。有新事件就提前返回，超时只结束本次等待。首次省略 `after` 时返回当前快照和游标。从 `start` 返回的游标读可以取得首批事件。检查已有事件与登记等待者必须作为同一项原子操作执行，避免在两者之间漏掉事件。每个调用方独立推进游标，取消一个等待不会中断 Codex。首次省略 `turnId` 时选中最近一轮，后续用该游标继续读取同一轮。游标不能跨任务或轮次使用。

**批量返回。** 单次响应受事件条数和编码后字节数双重限制。积压时返回 `hasMore: true`，下一次携带 `nextCursor` 立即取下一页。超过单页大小的最终答复按顺序分段，分段游标记录轮次、执行项和偏移；快照可以已经显示执行完成，调用方应读到 `hasMore: false` 才算收齐结果。

**选择传递方式。** 普通客户端以 `wait` 的工具结果取得进展；请求带 `progressToken` 时，可以额外发送 `notifications/progress` 给客户端展示。若未来接入 MCP Tasks，按实际协商的扩展支持为单一轮次提供后台跟踪、`input_required` 和终态结果，区分 MCP 跟踪句柄、Bridge 会话 ID 和 Codex 轮次 ID。后台跟踪取消与显式中断执行的产品语义须在扩展接入时对齐。首版验收以普通 MCP 为准。[MCP 进度通知](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/progress) · [MCP Tasks 扩展](https://tasks.extensions.modelcontextprotocol.io/specification/2026-07-28/tasks)

## 5. 审批如何回到原任务

1. 控制连接收到带 `id` 和 `method` 的服务端请求。Bridge 核对任务归属，为该请求生成 `requestId`，关联连接代次、原 RPC ID、具体类型和载荷。同一执行项可能发起多次审批，每条分别处理
2. `wait` 返回待办。调用 `respond` 时，支持 MCP elicitation 的客户端可向用户显示具体命令、目录、原因或权限范围。Bridge 提供“允许一次／拒绝”等与原请求相符的选项，并以用户提交的实际选项为准。普通工具参数不提供可让模型自行填入的批准值
3. 客户端不支持表单时，返回 `local_confirmation_required`，由用户在 CodexBar 主动打开待办处理。客户端表单可能由客户端自动化作答，**必须由本人确认**的事项走本机入口。该入口、客户端与项目授权界面属于拟议的界面范围，实施前需确认交互
4. 两处同时答复时，只有第一次有效提交能够写回。其他调用读回当前状态。区分“已提交答复”“上游已关闭请求”和“动作已执行”；后两者分别由 `serverRequest/resolved`、后续执行项或轮次终态核对

| 收到的服务端请求 | 回传内容 |
| --- | --- |
| `item/commandExecution/requestApproval`、`item/fileChange/requestApproval` | 按原类型回传 `decision`。首版仅提供本次允许、拒绝等受限选项 |
| `item/permissions/requestApproval` | 回传实际批准的 `permissions` 和 `scope`，限制在原请求和本地授权上限内 |
| `item/tool/requestUserInput` | 按问题 ID 回传 `answers`，尊重 `isBlocking`。此类型在本机导出协议中标为实验性，列入单独的兼容性验证 |
| `mcpServer/elicitation/request` | 按已支持的上游模式回传 `action`、`content` 和需要的元数据。未知模式或涉及秘密、身份验证的交互使用协议允许的取消或拒绝路径 |

没有待处理 RPC 的普通文字追问通过 `codex_reply` 回答。等待标志只说明上游正在等输入，单凭它无法重建可答复的 RPC。旧控制连接失效后，旧 `requestId` 随之失效；只有收到上游在新连接发来的有效请求，才重新开放答复。MCP 客户端自身断开时，仍有效的控制连接可以继续持有待办。[MCP elicitation 规范](https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation)

## 6. 访问、存储与恢复

**授权的单位是客户端和项目。** 建议默认关闭 Bridge。用户为每个接入配置发放独立的随机凭据和允许的项目根目录，通过客户端的本地配置向 MCP 入口提供凭据。主 App 在用户私有的本机 IPC 上验证凭据，用稳定的授权记录识别调用方。客户端名称、项目名和任务 ID 都不能证明身份。同一配置下的新对话可以找回旧任务，使用不同凭据的客户端分别授权；共享凭据意味着共享该授权范围。凭据不放在模型工具参数或日志中。

项目先解析真实路径再校验目录边界。接入时向用户提供可用项目名，`start` 收到不明确的项目时只向该客户端列出它已获授权的选项。每次读写都核对归属和当前授权。工具只接受业务参数，沙箱、审批策略及工作根目录由 Bridge 和上游有效策略共同约束。只读项目要求有效沙箱为只读，可写项目的工作目录限定在授权项目内。需要人工审批时，线程须以支持人工审批的策略创建并核对返回的实际配置。如果当前配置无法满足授权约束，在发送首轮输入前返回错误。用户撤销授权后拒绝后续调用和待处理的客户端答复，释放该客户端的等待者。已在执行的轮次仍按真实状态跟踪，可由用户从本机中断。Debug 与 Release 的授权、IPC 端点和任务数据建议分别保存。

**本机持久化**保存任务归属、项目、已知轮次、更新时间、最近状态和幂等操作记录。最终答复优先从 Codex 历史读取。高频输出、表单内容和活跃 RPC 映射仅在内存中有界保留。重启或事件窗口被裁剪时，`wait` 返回 `cursor_expired`、当前快照及新游标，明确标出无法重放的区间。控制连接的诊断日志只记录方法、耗时、状态和错误类别。活动观察连接可能同时看见这些线程，因此隐私验收要覆盖两条连接。Bridge 正文、待办和授权凭据不进入 CloudKit，现有按天活动与用量聚合仍遵循用户的同步设置。返回给外部 AI 的项目内容由该客户端接收，用户授权时应能看到这项数据流向。

**写操作按任务串行，同一任务的多个等待调用可并行。** `start`、`reply` 使用调用方生成的 `operationId`。Bridge 在发送前原子登记调用方、工具、操作标识和参数指纹；同键同参复用已有结果，同键异参返回冲突。已拿到 `thread.id` 时先持久化再开第一轮。如果发出 RPC 后断线，只能用可靠的上游标识核对；无法确认执行与否时返回 `outcome_unknown`，保留线索供查询，禁止盲目重发。重连后先核对调用方归属、轮次及待办，再接受相关控制操作。

| 异常 | 调用方得到什么 / 如何恢复 |
| --- | --- |
| 外部客户端或 MCP 入口退出 | 主 App 继续跟踪。用原授权连接后，以 `list` 找任务、`wait` 补读 |
| Mac 睡眠、主 App 重启或控制连接丢失 | 取消旧读取和旧请求映射。有界退避重连，按已登记线程 `thread/resume`，再用轮次和执行项历史核对。允许上游工作已结束、仍运行或无法恢复三种结果 |
| 用户停止与自然结束竞态 | 精确匹配目标 `turnId`，返回上游实际终态；下一轮不受上一轮迟到的指令影响 |
| 待办由另一入口解决、超时或失效 | 返回 `request_closed` 或提交结果未知，重新读取待办，避免向新连接或新请求重放旧决定 |
| 授权失效、目标属于其他客户端 | 返回不披露其他任务是否存在的错误。已获授权的客户端仅能分页读取自身任务 |
| 请求、输出和等待者达到上限 | 高频输出可合并、截断并标记。待办和终态保留独立快照。超过安全容量时显式报错或重新核对，不静默丢审批 |

## 7. 验证与交付

本机 Codex CLI `0.170.0` 的协议导出已核对，仓库当前公共握手版本下限为 `0.162.0`，默认关闭 `experimentalApi`。这两个数字分别说明**已检查的协议版本**和**现有功能的要求**。Bridge 的最低版本和实验接口策略应在隔离环境完成实测后单独确定。设计阶段尚未实测写入、审批、客户端后台跟踪或重连后的请求重发。[版本配置](../../CodexBar/Services/Codex/CodexVersionService.swift) · [握手配置](../../CodexBar/Services/AppServer/AppServerSession.swift)

| 验收场景 | 可观察的通过条件 |
| --- | --- |
| 两种客户端完成委托 | 至少一种普通 MCP 客户端和一种支持表单的客户端可发现工具，发起任务、收到真实进展与结果，并在同一 thread 发起第二轮 |
| 进度及时且可续读 | 同时等待的两个读者都能收到同一事件。建议在预热后的本机隔离测试中采集至少 100 次，记录 Bridge 收到关键事件到唤醒在途 `wait` 的 p95，初始目标低于 500 毫秒；客户端调度和模型响应另行计时 |
| 审批往返 | 在隔离项目触发真实审批。允许后原轮次继续，拒绝后相应动作没有获批。再覆盖无表单客户端、本机答复、重复点击和连接失效 |
| 调整与中断 | 对运行中轮次追加指令能命中原轮次，过期轮次明确报错，中断和自然完成竞态返回实际终态 |
| 重试、重启与权限 | 模拟建线程后首轮失败、RPC 发出后丢响应、客户端退出、主 App 重启。重试不会静默开第二份任务，跨客户端访问被拒，过期游标能恢复到当前快照 |
| 隐私与资源 | 用带标记的提示、命令输出和表单值确认诊断日志及 CloudKit 均未包含正文。大输出、慢读者和长期无人审批时，内存、落盘记录和等待数均受限 |

**实施顺序。** 先在临时项目验证一条完整链路：普通 MCP 发起任务 → 在途等待收到事件 → 客户端表单审批 → 原轮次继续 → 取回最终答复。再接入六个工具、项目授权、重试与恢复。最后用第二种客户端验收通用行为，并单独评估 MCP Tasks 后台跟踪。自动化验证使用模拟连接、临时数据和离屏状态断言；真实客户端表单、菜单焦点和系统睡眠恢复留作手动验证。

**评审时需要定下的取舍**

- **兼容范围**：独立提高 Bridge 下限能缩小测试矩阵；为旧版逐能力降级能覆盖更多用户，但须明确每种受限行为。两种选择均可与当前活动采集独立演进
- **授权与交互**：建议每个客户端独立授权，普通审批优先在调用方展示，必须本人确认或客户端无法交互时由用户在本机处理。需确认启用、项目授权和本机待办入口
- **保留与上限**：需确定任务索引与幂等记录的保留期、事件缓冲和输出上限。保留越久，越容易找回旧任务，也会存留更久的项目关联。建议根据隔离测试的事件量和恢复需求定值，并让任务去重窗口与公布的重试窗口一致
