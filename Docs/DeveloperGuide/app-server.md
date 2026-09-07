# app-server 数据链路

简体中文 | [English](../en/DeveloperGuide/app-server.md)

## 职责

app-server 链路负责读取 Codex 账户和服务端状态：

- 当前账户和套餐
- Codex 返回的额度分组和窗口
- token 用量与用量历史
- Reset Credits 状态
- Hook 功能开关、handler 列表和配置写入能力

这条链路不负责 Hook 历史统计，也不负责实时任务状态。

### 输入与输出边界

```text
CodexCLIResolver
  -> AppServerCommand
  -> CodexStatusService actor
      -> AppServerSession
          -> Process + stdin/stdout/stderr
      -> CodexQuotaSnapshot
  -> CodexStatusViewModel
  -> 菜单栏与主面板
```

`CodexStatusService` 拥有连接和同账户缓存。`CodexStatusViewModel` 只拥有 UI 级加载状态、自动刷新节奏和最后一次连接信息。

这个分工让设置页可以复用同一个 app-server session 读写 Hook 与 TUI 配置，同时不让 View 直接持有 `Process` 或 pipe。

## Codex CLI 定位

[`CodexCLIResolver.swift`](../../CodexBar/Services/CodexCLI/CodexCLIResolver.swift) 先从进程 `PATH` 查找全局 `codex`，再检查 App 内置路径：

```text
/Applications/ChatGPT.app/Contents/Resources/codex
/Applications/Codex.app/Contents/Resources/codex
```

菜单栏 App 从 Finder 启动时可能没有交互式 shell 的完整 `PATH`，因此 resolver 还会补充常见安装目录：

```text
/opt/homebrew/bin
/usr/local/bin
~/.npm-global/bin
~/.local/bin
~/.volta/bin
/usr/bin
/bin
/usr/sbin
/sbin
```

数据目录优先使用 `CODEX_HOME`，未设置时使用真实用户主目录下的 `~/.codex`

### 进程环境归一化

从 Finder 或登录项启动的 `LSUIElement` App 通常没有用户交互式 shell 注入的完整 `PATH`。如果只调用 `/usr/bin/env codex`，Homebrew, Volta 或 npm 全局安装会在 Terminal 中可用，在 CodexBar 中却不可见。

resolver 会做 3 层归一化：

1. 使用 `getpwuid(getuid())` 解析真实登录用户主目录，避免继承 Xcode 或容器环境的错误 `HOME`
2. 保留现有 `PATH`，再按顺序补充常见目录并去重
3. 对候选路径解析 symlink 和 standardized URL，避免同一内置 binary 同时被识别成 global 与 bundled

`CodexCLISourceSelection.automatic` 优先使用全局 CLI，找不到时使用 App 内置 CLI。手动选择 `global` 或 `bundled` 后只使用指定来源，缺失时返回 `sourceUnavailable`。来源选择由 `CodexStatusService` 保存，重建连接时沿用。

### 磁盘版本与运行版本

设置页可以读取磁盘上两个候选 CLI 的版本，但全局和 Hook 最低版本检查只使用 `initialize` 返回的 app-server `userAgent`

原因是连接最长复用 1 小时。用户在连接存活期间升级磁盘 binary 后，当前进程仍然是旧版本。用磁盘版本判断会让 UI 声称能力可用，实际调用的旧 app-server 却不支持对应方法。

## App 内代理

代理由以下类型协作完成：

| 类型 | 职责 |
| --- | --- |
| [`CodexProxyConfiguration`](../../CodexBar/Models/CodexProxyConfiguration.swift) | HTTP/HTTPS 配置、输入校验和子进程环境变量 |
| [`CodexProxyStore`](../../CodexBar/Services/Settings/CodexProxyStore.swift) | 在 UserDefaults 的 `CodexProxy.configuration` 中保存配置和密码 |
| [`CodexProxySettings`](../../CodexBar/Services/Settings/CodexProxySettings.swift) | 已保存配置、编辑草稿、开关提交和测试状态 |
| [`CodexProxyConnectionTester`](../../CodexBar/Services/CodexStatus/CodexProxyConnectionTester.swift) | 使用草稿启动独立测试进程 |

未配置或未启用时，正式连接沿用 `CodexCLIResolver.environment`。启用后写入 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`WS_PROXY`、`WSS_PROXY` 及其小写形式，`NO_PROXY` 和 `no_proxy` 设为 `localhost,127.0.0.1,::1`。只有自定义代理进程追加 `-c features.respect_system_proxy=false`，配置不写入 Codex 全局文件。

读取存储时保留可解码的原始输入。启用代理和保存编辑表单时校验地址、端口和认证用户名；停用时允许保存无效字段。无法解码的记录仍保留清除入口。

开关在创建异步任务前更新显示状态并设置 `isSaving`，处理期间重复切换被忽略。`CodexStatusService.applyProxy` 串行保存设置、关闭旧连接并清空补充缓存，完成后恢复交互并触发刷新；失败时恢复原开关状态。配置对话框使用独立草稿，只有保存或清除才提交。

### 连接测试

测试将草稿临时视为启用，解析所选 Codex 来源，并通过 `AppServerSession.initializeAccount()` 执行与正式连接相同的握手和账户检查，随后调用 `account/rateLimits/read`。正式连接在握手之后继续读取额度和用量。

测试请求共享 8 秒截止时间，不重试服务端业务错误，不记录交互日志。退出时关闭临时进程；进程清理仍使用 session 的关闭等待预算。编辑字段、取消测试或关闭窗口会取消外层任务和 worker，已取消任务返回的结果不会更新 UI。

## 进程与协议

CodexBar 启动以下命令并通过 stdio 通信：

```bash
codex app-server --listen stdio://
```

协议是逐行 JSON-RPC。建立连接后先发送 `initialize`，再发送 `initialized`，然后读取账户：

```text
启动子进程
  -> initialize(clientInfo)
  -> 校验实际版本 >= 0.143.0
  -> initialized
  -> account/read
  -> account/rateLimits/read
  -> account/usage/read
```

stdout 可能包含非 JSON 输出。pipe reader 会持续读取完整行，只把能够解码且 response id 匹配的消息交给等待中的请求。stderr 独立排空，防止子进程因管道写满而阻塞。

### 一次建连的完整事务

```text
解析 executable
  -> 创建 stdin/stdout/stderr pipe
  -> 启动 Process
  -> initialize(clientInfo)
  -> 从 userAgent 保存实际版本
  -> 校验实际版本 >= 0.143.0
  -> initialized notification
  -> account/read(refreshToken: false)
  -> account 存在: 提交 connection
  -> account 缺失: 关闭进程并返回 notLoggedIn
```

只有实际版本满足全局门槛，并且 handshake 与首次账户读取都成功，connection 才进入 service 状态。版本低于 `0.143.0` 或无法解析时按不支持处理，关闭半初始化 session，不继续发送账户请求。

### Stdout 分行与响应匹配

app-server 的 framing 是一行一个 JSON message。pipe 回调收到的 `Data` 块可能：

- 只包含半行
- 同时包含多行
- 在 JSON 行之间混有普通日志
- 在进程结束时留下没有换行的最后一行

`PipeReadBuffer` 维护 byte buffer，读取期间按换行发布非空行，在 EOF 或停止读取时也会发布末尾尚未换行的非空内容。会话层先轻量解码 response ID，只有 ID 匹配才完整解码 result 或 error。

这既避免把日志误判成协议错误，也让大响应只进行一次完整泛型解码。

### Stderr 排空

即使 CodexBar 不展示 stderr 正文，也必须 drain pipe。子进程 pipe buffer 有上限，如果父进程从不读取 stderr，app-server 写满后会阻塞，随后的 stdout response 也不会到达。

`PipeDrain` 不解析内容，只负责持续排空 stderr。

### 关闭策略

session 关闭时按以下顺序收口：

1. 停止 stdout 和 stderr reader
2. 关闭 stdin 写端
3. 向仍在运行的进程发送 `SIGTERM`，最多等待 1 秒
4. 仍未退出时发送 `SIGKILL`，再等待 0.5 秒
5. 仍存活则记录诊断错误

进程提前退出后继续写 pipe 可能触发 `SIGPIPE`。service 在初始化时忽略该 signal，让写入以 Swift error 返回并进入 transport failure 重建路径，而不是杀死整个菜单栏 App。

## API 使用范围

| 方法 | 用途 |
| --- | --- |
| `account/read` | 读取账户、套餐和认证状态 |
| `account/rateLimits/read` | 读取额度窗口 |
| `account/rateLimitResetCredit/consume` | 使用指定的 Reset Credit |
| `account/usage/read` | 读取 token 和历史用量 |
| `config/read` | 读取 Codex 配置 |
| `hooks/list` | 校验 Hook 来源和事件能力 |
| `config/batchWrite` | 修改 Hook 或 TUI 通知相关配置 |

每个 session 会缓存不支持的方法。一旦 app-server 明确返回 method unsupported，当前连接后续不会重复请求该方法。

### Session 能力缓存

method unsupported 通常代表当前 app-server 版本缺少能力。每分钟重复调用只会制造日志和延迟。

但这个结论不能永久保存到 UserDefaults。新连接可能来自升级后的 binary，因此 unsupported 集合只属于 `AppServerSession`，连接重建后重新探测。

## 会话生命周期

[`CodexStatusService.swift`](../../CodexBar/Services/CodexStatus/CodexStatusService.swift) 是 actor，持有连接和刷新状态：

- 单次请求超时为 20 秒
- 请求时检查连接年龄，达到 1 小时则重建
- 业务错误在 session 内最多重试 1 次
- transport 失败最多重建连接 1 次
- 认证需要刷新时，`account/read` 最多使用 `refreshToken = true` 再试 1 次
- 连接关闭或释放时执行子进程终止流程；请求读取遇到关闭时按连接错误处理

业务错误与 transport 错误分开处理。前者可能是某个方法暂时失败，后者代表当前 stdio 会话已经不可信。

### 连接状态机

```text
no connection
  -> resolve CLI
  -> open and initialize
  -> ready

ready
  -> age < 1h and process alive: reuse
  -> process exited: close and rebuild
  -> age >= 1h: close and rebuild
  -> transport failure: close and rebuild once
  -> account missing after refresh: close and notLoggedIn
```

1 小时是请求时检查的连接复用上限。达到上限后的下一次请求会重建连接并使用当时磁盘上的 Codex binary，没有独立的定时销毁任务。

手动重连、切换来源和连接到期重建都先关闭旧连接；新连接失败时保持断开。来源选择只在手动重连成功后保存。自动刷新和手动重连的错误都会更新 `CodexStatusViewModel.connectionErrorMessage`，关于页面直接展示该状态。

### 错误分类矩阵

| 错误 | 当前请求 | 当前连接 | 整轮刷新 |
| --- | --- | --- | --- |
| retriable server error | 同一方法再试 1 次 | 保留 | 根据第二次结果继续 |
| method unsupported | 标记当前 session 不支持 | 保留 | 对应字段为 missing |
| 普通业务失败 | 不再重试 | 保留 | 同账户缓存可降级 |
| authentication required | 本轮统一刷新 token 后再试 | 保留或转未登录 | 全程最多刷新 1 次 |
| timeout, pipe close, invalid transport | 失败 | 立即丢弃 | 仅复用连接时重建 1 次 |

限制重建次数是为了避免故障状态下反复拉起子进程。一轮刷新结束后，下一次正常定时刷新仍有新的尝试机会。

### 认证刷新预算

一次刷新会读取 account、rate limits 和 usage，Reset Credits 明细包含在 rate limits 响应中。多个接口可能同时发现 token 过期。

`fetchData` 内部用同一个 `didRefresh` 锁存本轮刷新资格。第一个认证失败触发 `account/read(refreshToken: true)`，后续接口复用刷新结果。再次需要认证时直接归类为未登录。

这避免一轮 UI 刷新对同一凭据连续触发多次 token refresh。

## 刷新模型

状态 ViewModel 默认每 60 秒刷新。用户也可以在主面板双击账户图标立即触发。

一次刷新先解析账户，再读取额度和用量。补充数据缓存严格绑定到账户身份：

- 账户不变且补充请求失败时可以继续展示缓存值
- 账户变化时立即清空旧账户缓存
- 服务端明确不支持的方法显示为来源缺失
- 来源缺失不能转换为业务值 `0`

刷新或重连进行中会忽略普通刷新触发。需要补刷的操作通过 `refreshAfterCurrent` 保留一个待执行触发，待当前请求结束后执行；协调器负责取消和校验过期结果。

### 一次刷新如何组装快照

```text
确认或新建 connection
  -> 复用连接时 account/read
  -> 确认 account identity
  -> account/rateLimits/read（包含 Reset Credits 明细）
  -> account/usage/read
  -> 组合 CodexQuotaSnapshot
  -> MainActor 提交 loadState 与连接信息
```

rate limits 与 usage 是补充数据。只要账户有效，即使两个接口都没有数据，仍然生成快照让 UI 展示账户和明确的“暂无数据”。

如果因为补充接口缺失就把整轮标成未登录，用户会看到身份状态在真实登录和错误之间抖动，也无法区分认证问题与单个新接口不支持。

### 缓存决策表

| 当前结果 | 同账户有缓存 | 输出 | stale |
| --- | --- | --- | --- |
| 成功 | 任意 | 新值并更新缓存 | `false` |
| 普通请求失败 | 是 | 缓存值 | `true` |
| 普通请求失败 | 否 | `nil` | 不适用 |
| method unsupported | 任意 | `nil` | 不适用 |
| 账户变化 | 旧账户缓存 | 先整体清空 | 不适用 |

method unsupported 不使用旧缓存，因为它是明确能力结论。普通请求失败使用缓存，因为来源可能只是一轮暂时故障。

### stale 如何影响消费者

- UI 可以展示旧值，但降低菜单栏和进度条透明度
- `hasTrustedData` 只把非 stale 的额度或用量算作可信
- 额度通知完全跳过 stale rate limits
- 系统日志只记录 step 为 `cached`，不记录实际额度数值

stale 是数据可信度的一部分，新增展示时不能只复制数值而丢掉标记。

### 刷新结果的代际校验

`isRefreshing` guard 可以阻止普通重复触发，但 cancellation 和对象生命周期仍可能让旧 Task 返回。

`RefreshTaskCoordinator` 每次开始先推进 generation，取消旧 Task，最终只有 `canCommit(generation)` 成立的结果可以写回 UI。这让“最后发起的刷新获胜”成为显式规则。

自动刷新每轮按距离上次完成的剩余时间等待。手动刷新完成后倒计时自然重新对齐，不会在几秒后又被原来的 timer 立刻刷新一次。

### 数据模型与展示投影

`CodexUsageSnapshot` 构造时把可能重复的 daily bucket 聚合成 `tokensByDate`

热力图在一次渲染中会反复查询日期。提前构造可选索引避免每个方块都线性扫描原始 bucket，并让快照相等比较只关注汇总指标、每日数据可用性和聚合后的每日 Token。原始 bucket 的顺序或拆分方式不影响展示结果，也不单独触发动画。

`account/usage/read` 的 `summary` 必须存在，但汇总指标和 `dailyUsageBuckets` 均可为空。模型保留空值语义：汇总指标缺失时显示 `--`；`dailyUsageBuckets == nil` 表示每日数据不可用，空数组才表示已成功读取但没有记录。合法的部分响应不使用旧值填充；业务 payload 解码失败则按补充接口失败处理，不重建 app-server 会话或清空额度数据。

额度 limit 的展示顺序也在模型层统一：

- app-server 顶层 `rateLimits` 指向的主 limit 优先
- 其余按本地化名称和 limit id 稳定排序
- primary 与 secondary 使用稳定枚举，View 不根据标签字符串猜测窗口类型

## Reset Credits

界面将可用数量显示为“留存重置”或“Banked Resets”，本地化键为 `banked-reset.count`。协议字段仍使用 `rateLimitResetCredits`

`account/rateLimits/read` 的 `rateLimitResetCredits` 同时返回可用数量和可选明细：

- `availableCount` 是权威总数
- `credits == nil` 表示只知道数量
- 空数组表示服务端已获取明细，但没有返回可用凭证
- 明细列表可能被服务端截断，长度可以小于 `availableCount`
- 每条明细包含 opaque `id`、`status` 和可空的 Unix 秒级 `expiresAt`
- 每条明细还包含 `resetType`，自动重置只接受 `codexRateLimits`

模型层只保留 `status == available` 且晚于快照生成时间的过期日，并按时间排序。数量仍独立使用 `availableCount`，不能从过滤后的日期数量反推。

过期明细属于增强信息。`credits == nil` 时主面板仍展示可用数量，详情显示未知过期时间，不影响额度和用量。额度响应来自同账户缓存时，UI 可以继续展示旧明细，但通知服务不会用 stale 数据触发新的临期通知。

### 自动重置

用户主动开启自动重置后，[`AutoResetController.swift`](../../CodexBar/Services/CodexStatus/AutoResetController.swift) 只处理最新 `account/rateLimits/read` 明确返回的凭证明细：

- 快照为 stale、`credits == nil`、缺少 `expiresAt`、状态不是 `available` 或 `resetType` 不是 `codexRateLimits` 时不调用消费接口
- 明细可能被截断，只处理实际返回的凭证，不从 `availableCount` 猜测未列出的 `creditId`
- 同一时间只处理返回明细中最早到期的一条，完成或消失后再选择下一条
- 进入用户设置的临期时间窗口后，消费前再次强制读取账户和凭证明细
- 请求始终显式传入 `creditId`，不会让后端代选
- 消费结果返回后立即再读一次 rate limits
- `reset`、`alreadyRedeemed` 和 `noCredit` 会请求完整额度刷新；`nothingToReset` 在目标仍存在时只安排下一次重试，目标已经变化时再请求完整刷新

调用形状如下：

```text
account/rateLimitResetCredit/consume
  creditId: <exact opaque id>
  idempotencyKey: <deterministic UUIDv5>
```

结果按以下语义处理：

| `outcome` | 结论 | 后续动作 |
| --- | --- | --- |
| `reset` | 本次调用完成消费 | 成功通知、刷新额度、停止该凭证重试 |
| `alreadyRedeemed` | 相同幂等键此前已经完成消费 | 与 `reset` 相同，按成功处理 |
| `nothingToReset` | 当前没有可重置的额度窗口 | 凭证未消费，继续使用同一幂等键重试 |
| `noCredit` | 当前账户没有可用凭证 | 强制刷新；目标消失时静默停止，否则按暂时不一致重试 |

`alreadyRedeemed` 确认同一逻辑请求此前已成功；收到后停止重试，并按通知设置发送本机成功通知。

### 跨设备幂等契约

同一个 Codex 账户可能同时在多台 Mac 上运行 CodexBar。设备之间不依赖 CloudKit 协调，而是对相同 `creditId` 计算完全相同的 UUIDv5：

```text
namespace = c2904ab3-0a87-5648-997d-bd8515edd401
name      = creditId 的原始 UTF-8 字节
output    = lowercase UUID string
```

namespace 来自 URL namespace 对 `https://codexbar.zabrian.app/idempotency/auto-reset/v1` 执行 UUIDv5。这个 URL 只用于确定 namespace，不代表运行时网络请求。

固定测试向量为：

```text
creditId       = RateLimitResetCredit_123
idempotencyKey = 4035685d-9ca4-524f-8193-6e0ae2a7b3b9
```

namespace、UUID 版本、原始 UTF-8 输入和小写输出共同构成跨版本兼容协议，不能在普通重构中修改。最先成功的设备完成消费，其他设备用同一个 key 调用时会得到 `alreadyRedeemed`，或者在前置刷新时发现凭证已经消失。

凭证消失无法区分手动使用、其他设备使用和服务端过期，因此只停止本机任务，不发送自动重置成功通知。只有明确收到 `reset` 或 `alreadyRedeemed` 的设备才发送成功通知。

### 调度与重试

自动重置状态机和网络请求仍位于普通 App 进程，CodexBarHelper 只负责受限的系统唤醒计划：

- 开启功能时复用现有 CodexBarHelper 注册与批准流程，不依赖“防止系统睡眠”主开关
- App 只把最近一次阈值或重试时间交给 helper；helper 使用固定 owner 和固定 `wake` 类型替换 CodexBar 自己的事件，不接受任意事件类型
- helper 设置或取消后必须回读系统事件；只有恰好存在一个目标时间事件或确认事件已经清零时才回复成功
- 定时或唤醒触发后，App 仅在新鲜读取和消费请求期间持有 `PreventUserIdleSystemSleep` assertion，不保持显示器唤醒，也不修改 `SleepDisabled`
- 任务变化、功能关闭、App 退出或对应 XPC 连接关闭时取消 CodexBar 自己的唤醒事件
- helper 启动时先清除固定 owner 的遗留事件再接受连接；取消失败会放弃失效的连接所有者并在 helper 内重试
- App 正常退出会等待取消回读；App 强制终止或 XPC 连接中断时由 helper 立即取消，突然断电留下的事件由 helper 下次启动收敛，之后 App 按新鲜明细重新调度
- App 启动、用户开启功能或系统唤醒时先做新鲜读取；已经进入临期窗口且尚未过期时立即补试，否则按临期时间重新调度
- App 退出后不持久化原始 `creditId`；下次启动通过新鲜明细重建任务和同一确定性幂等键
- 同一 `creditId` 的 `expiresAt` 变化时保留幂等身份，但取消当前阈值或重试任务并按新时间重排；新临期点已经过去时立即补检
- 只有已经掌握 `creditId + expiresAt` 的目标才能注册重试唤醒事件；只知道数量或读取失败时不为查询重试唤醒 Mac
- 网络、超时、连接断开或暂时服务错误按 `15s, 30s, 1m, 2m, 5m` 序列计算退避，但不安排落在本轮 5 分钟截止点及之后的重试
- 单轮超时后取消本地任务和系统唤醒事件，但不标记目标失败；后续普通额度刷新仍可为同一目标开启新一轮重试
- `nothingToReset` 在距过期不足 10 分钟且本轮重试窗口尚未结束时固定等待 60 秒，其他时间沿用通用退避
- 认证失败先沿用 service 的单次 token refresh；仍失败时暂停当前凭证并按通知设置告知用户，后续可信快照证明认证恢复后再继续
- 参数、协议或方法错误停止当前凭证，不进行无意义重试

自动重置触发完整额度刷新时，如果普通额度刷新正在执行，新刷新会排队到当前刷新结束后运行，不能被 `isRefreshing` guard 丢弃。

## Hook 版本与配置校验

Hook 设置也复用 app-server 链路，但采用独立的可用性状态：

- `isEnabled` 表示目标 handler 已安装
- `isVerified` 表示最近一次 app-server 显式校验通过
- `isOperable` 只有在两者都为 `true` 时成立
- 短暂 RPC 失败保留上一次明确校验结果

启用或校验 Hook 时必须确认实际 app-server 版本不低于 `0.145.0`

详细配置流程见 [Hook 采集与历史聚合](hook-and-aggregation.md)

### 实际版本检查的时序

启用或校验 Hook 时调用 `readyConnectionInfo()`

- 没有连接时先建立连接
- 有连接时复用当前真实进程
- 从 handshake user agent 解析运行版本
- 无法解析版本时按不支持处理，不乐观放行

这是能力安全边界。如果未来新增依赖某个 app-server 方法的功能，应把最低版本判断放在实际连接能力入口，不能只在“关于”页面展示磁盘版本。

## 请求日志

[`RequestLog.swift`](../../CodexBar/Services/CodexStatus/RequestLog.swift) 在内存中保留最近 500 条请求日志，用于 App 内日志窗口诊断。

日志用于观察进程启动、JSON-RPC 方法、重试和错误分类。不应写入 access token 或 Hook prompt 内容。

`CodexProxyError` 的配置错误只写入系统日志 `settings` 分类，不创建 app-server 请求日志。RPC 响应及错误写入交互日志前，先解析 JSON 转义并遍历字符串值，对 HTTP/HTTPS URL 的认证信息脱敏；非 JSON 文本使用文本脱敏。

### 请求日志与系统日志

系统统一日志只保存控制流分类，适合长期排查 App 是否在刷新，失败在哪个阶段。

App 内 `RequestLog` 保存最多 500 条请求交互预览，只存在进程内存，适合用户主动检查协议细节。

Reset Credits 明细包含 opaque credit ID。系统日志不能记录 ID 或原始响应，App 内请求日志仍只按既有规则保存在当前进程内存。对新 RPC 增加日志时，需要检查 payload 是否可能包含凭据或内容字段。

## 建议验证的故障场景

- Finder 启动时仍能找到 Homebrew, npm 或 Volta 安装的 Codex
- 全局 CLI 缺失时正确回退到 ChatGPT App 或 Codex App 内置 binary
- stdout 混有普通文本时仍能匹配正确 response id
- stderr 持续输出时请求不会因 pipe 背压卡住
- 复用连接的 transport failure 只重建一次
- 磁盘 CLI 升级后，当前连接版本与磁盘版本能被区分
- app-server 低于 `0.143.0` 时阻断账户主链路并提示升级
- app-server 为 `0.143.x` 或 `0.144.x` 时账户主链路可用，但 Hook 仍提示需要 `0.145.0`
- app-server 不低于 `0.145.0` 时账户主链路和 Hook 校验均可用
- rate limits 失败但同账户有缓存时展示 stale，通知不误触发
- 账户切换后旧额度和用量立即清空
- unsupported method 不会每分钟重复请求
- Reset Credits `credits == nil` 时保留权威数量并显示未知过期时间
- Reset Credits 明细为空或被截断时不从明细长度反推可用数量
- 过期、非 available 的 Reset Credits 不进入详情或通知
- stale rate limits 可以展示旧明细，但不触发临期通知
- 自动重置关闭时不会调用消费接口，缺失设置默认关闭且提前量默认 30 分钟
- 自动重置不会消费 stale、缺少明细、缺少过期时间或未列出的凭证
- 两台设备对固定 `creditId` 生成相同幂等键，并与固定测试向量一致
- 同一 `creditId` 的过期时间提前或推迟时都重新调度，幂等键保持不变
- `reset` 和 `alreadyRedeemed` 均停止重试并发送成功通知
- `nothingToReset` 保留凭证并按退避策略重试
- 防睡眠关闭时仍可注册并批准 helper，未来阈值会写入固定 owner 的 `wake` 事件
- 计划时间处于系统睡眠期间时唤醒 Mac，触发后重新读取；自然唤醒和 App 启动仍执行相同补检
- 功能关闭、目标变化和 App 退出时取消已有唤醒事件，且不影响其他应用的计划事件
- 只有数量或读取失败、没有具体目标时不注册查询重试唤醒事件
- 已知目标的单轮连续重试在临期触发 5 分钟后停止，后续普通额度刷新仍可重新开启一轮
- 消费成功后的完整额度刷新不会被并发普通刷新丢弃
- 手动刷新后 60 秒倒计时重新对齐

代理相关验证还包括：停用无效配置、清除损坏记录、测试取消后旧结果隔离、快速连续切换只提交一次、提交失败回滚，以及普通 URL 和 JSON 转义 URL 的日志脱敏。

## 关键源码

- [`CodexCLIResolver.swift`](../../CodexBar/Services/CodexCLI/CodexCLIResolver.swift)
- [`AppServerSession.swift`](../../CodexBar/Services/CodexStatus/AppServerSession.swift)
- [`AppServerPipeReaders.swift`](../../CodexBar/Services/CodexStatus/AppServerPipeReaders.swift)
- [`CodexStatusService.swift`](../../CodexBar/Services/CodexStatus/CodexStatusService.swift)
- [`CodexStatusViewModel.swift`](../../CodexBar/Services/CodexStatus/CodexStatusViewModel.swift)
- [`AutoResetController.swift`](../../CodexBar/Services/CodexStatus/AutoResetController.swift)
- [`AutoResetIdentity.swift`](../../CodexBar/Services/CodexStatus/AutoResetIdentity.swift)
- [`AutoResetWakeScheduler.swift`](../../CodexBar/Services/KeepAlive/AutoResetWakeScheduler.swift)
- [`CodexBarHelperXPC.swift`](../../Shared/CodexBarHelperXPC.swift)
