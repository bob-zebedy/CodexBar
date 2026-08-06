# app-server 数据链路

## 职责

app-server 链路负责读取 Codex 账户和服务端状态：

- 当前账户和套餐
- 5 小时额度和周额度
- token 用量与用量历史
- Reset Credits 状态
- Hook 功能开关，handler 列表和配置写入能力

这条链路不负责 Hook 历史统计，也不负责实时任务状态。

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

## API 使用范围

| 方法 | 用途 |
| --- | --- |
| `account/read` | 读取账户，套餐和认证状态 |
| `account/rateLimits/read` | 读取额度窗口 |
| `account/usage/read` | 读取 token 和历史用量 |
| `config/read` | 读取 Codex 配置 |
| `hooks/list` | 校验 Hook 来源和事件能力 |
| `config/batchWrite` | 修改 Hook 或 TUI 通知相关配置 |

每个 session 会缓存不支持的方法。一旦 app-server 明确返回 method unsupported，当前连接后续不会重复请求该方法。

## 会话生命周期

[`CodexStatusService.swift`](../../CodexBar/Services/CodexStatus/CodexStatusService.swift) 是 actor，持有连接和刷新状态：

- 单次请求超时为 20 秒
- 连接最长复用 1 小时
- 业务错误在 session 内最多重试 1 次
- transport 失败最多重建连接 1 次
- 认证需要刷新时，`account/read` 最多使用 `refreshToken = true` 再试 1 次
- service 关闭或进程退出时终止子进程并完成所有挂起请求

业务错误与 transport 错误分开处理。前者可能是某个方法暂时失败，后者代表当前 stdio 会话已经不可信。

## 刷新模型

状态 ViewModel 默认每 60 秒刷新。用户也可以在主面板双击刷新按钮立即触发。

一次刷新先解析账户，再读取额度和用量。补充数据缓存严格绑定到账户身份：

- 账户不变且补充请求失败时可以继续展示缓存值
- 账户变化时立即清空旧账户缓存
- 服务端明确不支持的方法显示为来源缺失
- 来源缺失不能转换为业务值 `0`

刷新任务通过协调器合并，避免定时刷新，面板打开和手动刷新并发创建重复请求。

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

## Hook 版本与配置校验

Hook 设置也复用 app-server 链路，但采用独立的可用性状态：

- `isEnabled` 表示目标 handler 已安装
- `isVerified` 表示最近一次 app-server 显式校验通过
- `isOperable` 只有在两者都为 `true` 时成立
- 短暂 RPC 失败保留上一次明确校验结果

启用或校验 Hook 时必须确认实际 app-server 版本不低于 `0.145.0`

详细配置流程见 [Hook 采集与历史聚合](hook-and-aggregation.md)

## 请求日志

[`RequestLog.swift`](../../CodexBar/Services/CodexStatus/RequestLog.swift) 在内存中保留最近 500 条请求日志，用于 App 内日志窗口诊断。

日志用于观察进程启动，JSON-RPC 方法，重试和错误分类。不应写入 access token 或 Hook prompt 内容。

## 关键源码

- [`CodexCLIResolver.swift`](../../CodexBar/Services/CodexCLI/CodexCLIResolver.swift)
- [`AppServerSession.swift`](../../CodexBar/Services/CodexStatus/AppServerSession.swift)
- [`AppServerPipeReaders.swift`](../../CodexBar/Services/CodexStatus/AppServerPipeReaders.swift)
- [`CodexStatusService.swift`](../../CodexBar/Services/CodexStatus/CodexStatusService.swift)
- [`CodexStatusViewModel.swift`](../../CodexBar/Services/CodexStatus/CodexStatusViewModel.swift)
- [`CodexResetCreditsService.swift`](../../CodexBar/Services/CodexStatus/CodexResetCreditsService.swift)
