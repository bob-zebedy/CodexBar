# Codex app-server

CodexBar 通过本机 Codex app-server 读取账号, 额度, Token 用量和部分用户配置; 通信使用子进程标准输入输出, 每条消息占一行 JSON

## Codex 解析

CodexBar 按以下顺序选择可执行文件

1. `PATH` 中的全局 `codex`
2. `/Applications/ChatGPT.app/Contents/Resources/codex`
3. `/Applications/Codex.app/Contents/Resources/codex`

菜单栏 App 的环境会补充 Homebrew, npm, `~/.local`, Volta 和系统命令目录; `HOME` 使用当前真实用户目录; Codex 配置目录优先取 `CODEX_HOME`, 否则使用 `~/.codex`

启动命令固定为

```text
codex app-server --listen stdio://
```

设置窗口会同时探测全局 Codex 和 App 内置 Codex 的版本, 并根据当前 app-server 握手结果标记实际使用来源

## 会话生命周期

新会话依次执行

1. 发送 `initialize`
2. 发送 `initialized` 通知
3. 发送 `account/read`, 确认账号已登录

连接在刷新之间复用, 最长保留 1 小时; 进程退出, 写入失败, 响应超时或响应无法解析时, 连接会关闭; 复用连接发生传输故障时, 本轮读取最多重建并重试一次

单次请求超时为 20 秒; stdout 读取器只向上层返回完整非空行, 并按响应 `id` 过滤; stderr 持续排空, 避免子进程因管道写满而阻塞

关闭会话时先结束管道并请求进程退出, 必要时再强制终止

## 使用的接口

| 方法 | 用途 |
| --- | --- |
| `initialize` | 建立客户端会话并读取运行版本 |
| `initialized` | 完成初始化通知 |
| `account/read` | 读取账号; 可请求刷新认证 |
| `account/rateLimits/read` | 读取额度限制, 窗口和可用重置次数 |
| `account/usage/read` | 读取 Token 摘要和每日用量 |
| `config/read` | 读取 Hook, 信任状态和 Codex TUI 通知配置 |
| `config/batchWrite` | 写入 Hook 信任状态和 TUI 通知配置 |
| `hooks/list` | 验证 Codex 实际解析出的 Hook |

`config/batchWrite` 始终设置 `reloadUserConfig: true`, 由 Codex 重新加载用户配置

## 刷新与缓存

UI 默认每 60 秒触发一次读取; 一次刷新按以下顺序处理

1. 复用连接时重新读取账号状态
2. 读取额度
3. 读取 Token 用量
4. 组装菜单面板快照

额度和用量是独立的补充数据

- 成功读取时更新当前账号的内存缓存
- 普通业务错误时可以回退到同一账号的缓存, 并标记为陈旧数据
- 方法不支持, 认证失败或连接故障时不使用该项缓存
- 账号变化时清空全部补充缓存

app-server 返回认证错误时, 本轮最多执行一次 `account/read(refreshToken: true)`; 刷新后仍未认证则进入"未登录"状态

app-server 明确表示方法不支持后, 当前会话会记住该方法, 后续不再重复请求; 可重试的服务端业务错误在会话层重试一次

## 手动重置机会

`account/rateLimits/read` 返回可用重置次数且数量大于 0 时, CodexBar 会读取当前 Codex 配置目录下的 `auth.json`, 向以下只读接口查询每次机会的过期时间

```text
https://chatgpt.com/backend-api/wham/rate-limit-reset-credits
```

请求超时为 4 秒, 只保留状态为 `available` 且尚未过期的时间; 401 或 403 时, 如果本轮尚未刷新认证, 会先通过当前 app-server 刷新一次账号认证再重试; 查询失败不影响额度和可用次数展示, 只是不提供具体过期时间

## 配置读写

CodexBar 通过 app-server 管理两类用户配置

- `hooks.state`: 只新增, 更新或移除当前 CodexBar Hook 对应的信任项
- `tui.notifications`: 写入布尔值控制 Codex TUI 通知

Hook 事件注册本身保存在 `${CODEX_HOME}/hooks.json`, 由 CodexBar 直接按 JSON 文件读写; 注册后再通过 `hooks/list` 验证; 详见 [Codex Hook 与工作流统计](CodexHook.md)

## 交互日志

日志窗口保存本次运行期间最近 500 条记录, 包括

- 请求方法和请求 JSON
- 响应 JSON
- 传输, 解析, 业务和进程错误
- 无响应通知

合法 JSON 会按稳定键序规范化; 日志只保存在进程内存中, 可以在窗口内清空, 不写入工作流文件, 也不参与跨设备同步

## UI 状态

服务层向 UI 归并为三类结果

- 数据可用
- 未登录
- 初始化失败

更具体的请求错误保留在交互日志中; 陈旧的额度或用量仍可展示, 但会降低透明度, 且不会用于额度通知判断
