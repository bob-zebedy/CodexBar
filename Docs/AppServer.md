# app-server 通信合约

本文档记录 CodexBar 与本机 Codex app-server 的连接、请求、错误处理和日志规则。`AGENTS.md` 只保留开发时必须遵守的边界，具体实现细节以本文档为准。

## 启动命令

启动命令统一是:

```bash
codex app-server --listen stdio://
```

必须通过 `CodexCLIResolver.resolveAppServerCommand()` 解析:

- 优先 PATH 中的全局 `codex`。
- 如果 PATH 中的 `codex` 等价于 `/Applications/Codex.app/Contents/Resources/codex`，当作内置 Codex APP CLI，不当作全局 CLI。
- 全局 CLI 不存在时回退 Codex APP 内置 CLI。
- 两者都不存在时返回 `CodexStatusError.executableNotFound`，UI 归为「初始化失败」，日志记录具体错误。

不要绕过 `CodexCLIResolver` 直接启动 app-server。

## 启动环境

启动环境由 `CodexCLIResolver.environment` 构造:

- 保留当前环境。
- `HOME` 必须来自 `getpwuid(getuid())` 的真实用户 home。
- 同步设置 `USER`、`LOGNAME`。
- 合并 Homebrew、npm global、`.local`、Volta 和系统路径。
- 确保 `TERM` 有值。
- 不要改回 Xcode sandbox/container 的 `HOME`，否则会读不到真实 `~/.codex/auth.json`。

## 首次连接

首次连接流程:

```json
{"method":"initialize","id":1,"params":{"clientInfo":{"name":"codex_bar","title":"Codex Bar","version":"<Bundle MARKETING_VERSION 或 1.0.0>"}}}
{"method":"initialized"}
{"method":"account/read","id":2,"params":{"refreshToken":false}}
```

`initialized` 是无 id 请求，不等待响应；日志中记录为空响应请求，不归为通知类型。

`initialize` 响应的 `userAgent` 首个 token 形如 `codex_bar/0.139.0 (...)`；取 `/` 后版本号作为当前运行版本。

## 后续读取

同一会话后续读取:

- `account/read` 每轮复用连接时用 `refreshToken: false` 更新账户状态。
- `account/rateLimits/read` 读取额度。
- `account/usage/read` 读取 `summary.lifetimeTokens`、`summary.peakDailyTokens`、`dailyUsageBuckets`。

认证失败时，同会话最多调用一次 `account/read(refreshToken:true)` 后重试原读取。

## 错误处理

所有走 `AppServerSession.request` 的方法，收到方法不支持错误后都记录到当前会话的 `unsupportedMethods`，本连接后续不再请求该方法。

方法不支持必须是 JSON-RPC error，且 message 包含:

```text
Invalid request: unknown variant
```

请求有 JSON-RPC error 响应，且不是认证失败、不是方法不支持、不是传输/解析故障时，先立即重试同一个请求一次。

非认证业务错误重试后仍失败时，不阻断整轮刷新，详情只进日志。

`account/rateLimits/read` 和 `account/usage/read` 重试后仍失败时:

- 若同账号有上次成功数据，则复用旧数据并标记为 stale。
- 没有旧数据则不展示对应区域。
- 方法不支持不复用旧数据，对应读取结果视为空。

传输/解析故障归为需要重建连接。

## 连接生命周期

连接细节:

- `requestTimeout` 是 20 秒。
- `connectionMaxAge` 是 1 小时。
- `SIGPIPE` 已被忽略，写入断管后应由 `write` 抛错并走重建。
- 复用连接出现传输故障时只重建重试一次。
- 全新连接初始化失败直接返回「初始化失败」，不重复完整握手。
- 关闭会话时先停止 stdout/stderr reader 并关闭 stdin，然后对 app-server 进程执行有界退出: 先 `terminate()` 等待 1 秒，仍未退出再 `SIGKILL` 并等待 0.5 秒；被强制结束或仍未退出时写入请求日志。

## UI 状态

`CodexLoadState` 只有四种:

- `loading`
- `loaded`
- `notLoggedIn`
- `initializationFailed`

UI 只展示「未登录」和「初始化失败」两类特殊状态；具体请求错误、启动错误、超时、断连、解析失败都进入日志。

## 请求日志

日志状态标签:

- `.pending` ->「进行」
- `.response` ->「完成」
- `.failure` ->「错误」
- `.emptyResponse` ->「请求」

日志规则:

- 带 id 的 JSON-RPC 请求先记录为进行，响应或错误到达后回填到同一条。
- `initialized` 这类无 id 请求记录为空响应。
- 日志容量上限 500 条，单条详情上限 4000 字符。
- 合法 JSON 通过 `JSONSerialization` 重新序列化，使用 `.sortedKeys` 和 `.withoutEscapingSlashes`。
- 非 JSON 错误消息保持原样。
- 不要把子进程 stderr 直接展示给用户。
