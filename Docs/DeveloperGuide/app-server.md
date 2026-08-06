# app-server 数据链路

## 设计出发点

CodexBar 不重新实现 Codex 登录、token 刷新和账户协议，而是把本机 `codex app-server` 作为账户能力边界。

这样做的原因是：

- 认证和服务端协议由 Codex 自己维护，CodexBar 不复制一套容易漂移的客户端
- App 通过 stdio 与本机子进程通信，账户主链路不需要直接暴露额外网络实现
- 当前真正运行的 Codex 版本可以从 handshake 获得，能用于 Hook 能力判断
- 全局 CLI 与 App 内置 CLI 可以共享同一套上层数据模型

代价是菜单栏 App 必须自己解决 shell 环境缺失、子进程生命周期、pipe 背压、混杂 stdout、超时和升级后的连接换代。

## 职责

app-server 链路负责读取 Codex 账户和服务端状态：

- 当前账户和套餐
- 5 小时额度和周额度
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

### 为什么不能直接信任进程环境

从 Finder 或登录项启动的 `LSUIElement` App 通常没有用户交互式 shell 注入的完整 `PATH`。如果只调用 `/usr/bin/env codex`，Homebrew, Volta 或 npm 全局安装会在 Terminal 中可用，在 CodexBar 中却不可见。

resolver 会做 3 层归一化：

1. 使用 `getpwuid(getuid())` 解析真实登录用户主目录，避免继承 Xcode 或容器环境的错误 `HOME`
2. 保留现有 `PATH`，再按顺序补充常见目录并去重
3. 对候选路径解析 symlink 和 standardized URL，避免同一内置 binary 同时被识别成 global 与 bundled

全局 CLI 优先是一个明确的产品选择。开发者主动安装的 CLI 通常代表其期望版本，内置 CLI 只是找不到全局版本时的可用回退。

### 磁盘版本和运行版本为什么分开

设置页可以读取磁盘上两个候选 CLI 的版本，但 Hook 能力检查只使用 `initialize` 返回的 app-server `userAgent`

原因是连接最长复用 1 小时。用户在连接存活期间升级磁盘 binary 后，当前进程仍然是旧版本。用磁盘版本判断会让 UI 声称 Hook 可用，实际调用的旧 app-server 却不支持对应方法。

## 进程与协议

CodexBar 启动以下命令并通过 stdio 通信：

```bash
codex app-server --listen stdio://
```

协议是逐行 JSON-RPC。建立连接后先发送 `initialize`，再发送 `initialized`，然后读取账户：

```text
启动子进程
  -> initialize(clientInfo)
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
  -> initialized notification
  -> account/read(refreshToken: false)
  -> account 存在: 提交 connection
  -> account 缺失: 关闭进程并返回 notLoggedIn
```

只有 handshake 与首次账户读取都成功，connection 才进入 service 状态。半初始化 session 不会被留给下一轮复用。

### 为什么 stdout reader 只暴露完整行

app-server 的 framing 是一行一个 JSON message。pipe 回调收到的 `Data` 块可能：

- 只包含半行
- 同时包含多行
- 在 JSON 行之间混有普通日志
- 在进程结束时留下没有换行的最后一行

`PipeReadBuffer` 因而自己维护 byte buffer，只在看到换行时发布完整非空行。会话层先轻量解码 response id，只有 id 匹配才完整解码 result 或 error。

这既避免把日志误判成协议错误，也让大响应只进行一次完整泛型解码。

### 为什么 stderr 也必须持续读取

即使 CodexBar 不展示 stderr 正文，也必须 drain pipe。子进程 pipe buffer 有上限，如果父进程从不读取 stderr，app-server 写满后会阻塞，随后的 stdout response 也不会到达。

`PipeDrain` 不解析内容，只消除背压。这是进程正确性要求，不是日志功能。

### 关闭策略

session 关闭时按以下顺序收口：

1. 停止 stdout 和 stderr reader
2. 关闭 stdin 写端，给 app-server 正常感知 EOF 的机会
3. 最多等待 1 秒优雅退出
4. 仍未退出时发送强制终止，再等待 0.5 秒
5. 仍存活则记录诊断错误

进程提前退出后继续写 pipe 可能触发 `SIGPIPE`。service 在初始化时忽略该 signal，让写入以 Swift error 返回并进入 transport failure 重建路径，而不是杀死整个菜单栏 App。

## API 使用范围

| 方法 | 用途 |
| --- | --- |
| `account/read` | 读取账户、套餐和认证状态 |
| `account/rateLimits/read` | 读取额度窗口 |
| `account/usage/read` | 读取 token 和历史用量 |
| `config/read` | 读取 Codex 配置 |
| `hooks/list` | 校验 Hook 来源和事件能力 |
| `config/batchWrite` | 修改 Hook 或 TUI 通知相关配置 |

每个 session 会缓存不支持的方法。一旦 app-server 明确返回 method unsupported，当前连接后续不会重复请求该方法。

### 为什么 unsupported 只按 session 缓存

method unsupported 通常代表当前 app-server 版本缺少能力。每分钟重复调用只会制造日志和延迟。

但这个结论不能永久保存到 UserDefaults。新连接可能来自升级后的 binary，因此 unsupported 集合只属于 `AppServerSession`，连接重建后重新探测。

### 为什么配置也复用这条连接

`config/read`, `hooks/list` 和 `config/batchWrite` 需要与账户刷新使用同一个实际 app-server 来源。

如果设置页另起一套 resolver 或进程，可能出现主面板连接全局 CLI，Hook 校验却连接内置 CLI 的分裂状态。统一 service 保证能力检查、配置来源和运行版本来自同一个进程选择。

## 会话生命周期

[`CodexStatusService.swift`](../../CodexBar/Services/CodexStatus/CodexStatusService.swift) 是 actor，持有连接和刷新状态：

- 单次请求超时为 20 秒
- 连接最长复用 1 小时
- 业务错误在 session 内最多重试 1 次
- transport 失败最多重建连接 1 次
- 认证需要刷新时，`account/read` 最多使用 `refreshToken = true` 再试 1 次
- service 关闭或进程退出时终止子进程并完成所有挂起请求

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

1 小时不是数据刷新周期，而是连接最长寿命。定期重建的主要价值是让后台升级后的 Codex binary 最迟在一个连接周期后生效。

### 错误分类矩阵

| 错误 | 当前请求 | 当前连接 | 整轮刷新 |
| --- | --- | --- | --- |
| retriable server error | 同一方法再试 1 次 | 保留 | 根据第二次结果继续 |
| method unsupported | 标记当前 session 不支持 | 保留 | 对应字段为 missing |
| 普通业务失败 | 不再重试 | 保留 | 同账户缓存可降级 |
| authentication required | 本轮统一刷新 token 后再试 | 保留或转未登录 | 全程最多刷新 1 次 |
| timeout, pipe close, invalid transport | 失败 | 立即丢弃 | 仅复用连接时重建 1 次 |

限制重建次数是为了避免故障状态下反复拉起子进程。一轮刷新结束后，下一次正常定时刷新仍有新的尝试机会。

### 为什么认证刷新全程只有一次

一次刷新会读取 account, rate limits, usage 和 Reset Credits。多个接口可能同时发现 token 过期。

`fetchData` 内部用同一个 `didRefresh` 锁存本轮刷新资格。第一个认证失败触发 `account/read(refreshToken: true)`，后续接口复用刷新结果。再次需要认证时直接归类为未登录。

这避免一轮 UI 刷新对同一凭据连续触发多次 token refresh，也让 Reset Credits 的 `401` 或 `403` 与 app-server 方法共享同一个认证预算。

## 刷新模型

状态 ViewModel 默认每 60 秒刷新。用户也可以在主面板双击刷新按钮立即触发。

一次刷新先解析账户，再读取额度和用量。补充数据缓存严格绑定到账户身份：

- 账户不变且补充请求失败时可以继续展示缓存值
- 账户变化时立即清空旧账户缓存
- 服务端明确不支持的方法显示为来源缺失
- 来源缺失不能转换为业务值 `0`

刷新任务通过协调器合并，避免定时刷新、面板打开和手动刷新并发创建重复请求。

### 一次刷新如何组装快照

```text
确认或新建 connection
  -> 复用连接时 account/read
  -> 确认 account identity
  -> account/rateLimits/read
  -> account/usage/read
  -> 有 Reset Credits 时读取 expiration endpoint
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

### 刷新协调器为什么还需要 generation

`isRefreshing` guard 可以阻止普通重复触发，但 cancellation 和对象生命周期仍可能让旧 Task 返回。

`RefreshTaskCoordinator` 每次开始先推进 generation，取消旧 Task，最终只有 `canCommit(generation)` 成立的结果可以写回 UI。这让“最后发起的刷新获胜”成为显式规则。

自动刷新每轮按距离上次完成的剩余时间等待。手动刷新完成后倒计时自然重新对齐，不会在几秒后又被原来的 timer 立刻刷新一次。

### 模型层的小优化

`CodexUsageSnapshot` 构造时把可能重复的 daily bucket 聚合成 `tokensByDate`

热力图在一次渲染中会反复查询日期。提前构造索引避免每个方块都线性扫描原始 bucket，同时保留原始数组用于快照相等比较。

额度 limit 的展示顺序也在模型层统一：

- app-server 顶层 `rateLimits` 指向的主 limit 优先
- 其余按本地化名称和 limit id 稳定排序
- primary 与 secondary 使用稳定枚举，View 不根据标签字符串猜测窗口类型

## Reset Credits

Reset Credits 到期时间不来自 app-server。当可用数量大于 `0` 时，[`CodexResetCreditsService.swift`](../../CodexBar/Services/CodexStatus/CodexResetCreditsService.swift) 使用现有 `auth.json` token 请求：

```text
https://chatgpt.com/backend-api/wham/rate-limit-reset-credits
```

- 请求超时为 4 秒
- 首次请求只读取现有 token
- 收到 `401` 或 `403` 时，复用本轮统一认证刷新额度最多刷新 1 次，再重新读取 `auth.json`
- 不把 token 写入其他位置
- 数量为 `0` 时不发起请求
- 请求失败不会影响主账户和额度刷新

### 为什么这是唯一单独的账户网络请求

app-server 返回可用 Reset Credits 数量，但不返回每一批的过期时间。UI 和临期通知需要过期日，因此只在数量大于 `0` 时补充查询。

请求使用现有 `auth.json`，不另建登录流程。凭据只活在本次请求内，返回模型只保留仍为 available 且晚于当前时间的日期并排序。

这个请求是增强信息，不是账户快照的必要条件。4 秒超时或任何解析错误只让过期日缺失，不应让额度和用量一起失败。

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

### 两套日志为什么分开

系统统一日志只保存控制流分类，适合长期排查 App 是否在刷新，失败在哪个阶段。

App 内 `RequestLog` 保存最多 500 条请求交互预览，只存在进程内存，适合用户主动检查协议细节。

即使内存日志生命周期短，也不能记录 Reset Credits Authorization header。对新 RPC 增加日志时，需要检查 payload 是否可能包含凭据或内容字段。

## 扩展 app-server 字段的步骤

1. 在外部 DTO 中按协议可选性建模，不先用展示默认值填充
2. 在 `CodexStatusService` 决定该方法是账户核心还是补充数据
3. 明确普通失败、unsupported 和认证失败各自如何降级
4. 如果缓存该值，必须绑定账户 identity 并携带 stale 语义
5. 在领域 snapshot 中转换时间戳、百分比和排序等稳定规则
6. UI 只消费 snapshot，不直接访问原始 response
7. 通知等副作用只使用可信快照
8. 核对请求和日志是否扩大隐私边界

## 建议验证的故障场景

- Finder 启动时仍能找到 Homebrew, npm 或 Volta 安装的 Codex
- 全局 CLI 缺失时正确回退到 ChatGPT App 或 Codex App 内置 binary
- stdout 混有普通文本时仍能匹配正确 response id
- stderr 持续输出时请求不会因 pipe 背压卡住
- 复用连接的 transport failure 只重建一次
- 磁盘 CLI 升级后，当前连接版本与磁盘版本能被区分
- rate limits 失败但同账户有缓存时展示 stale，通知不误触发
- 账户切换后旧额度和用量立即清空
- unsupported method 不会每分钟重复请求
- Reset Credits `401` 后只共享一次认证刷新，失败不影响主快照
- 手动刷新后 60 秒倒计时重新对齐

## 关键源码

- [`CodexCLIResolver.swift`](../../CodexBar/Services/CodexCLI/CodexCLIResolver.swift)
- [`AppServerSession.swift`](../../CodexBar/Services/CodexStatus/AppServerSession.swift)
- [`AppServerPipeReaders.swift`](../../CodexBar/Services/CodexStatus/AppServerPipeReaders.swift)
- [`CodexStatusService.swift`](../../CodexBar/Services/CodexStatus/CodexStatusService.swift)
- [`CodexStatusViewModel.swift`](../../CodexBar/Services/CodexStatus/CodexStatusViewModel.swift)
- [`CodexResetCreditsService.swift`](../../CodexBar/Services/CodexStatus/CodexResetCreditsService.swift)
