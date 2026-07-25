# 阻止系统休眠

"阻止系统休眠"根据 Codex Hook 的实时任务状态临时保持 Mac 唤醒; 功能关闭或没有运行任务时, CodexBar 不修改系统休眠策略

## 生效条件

以下条件必须同时满足

- CodexBar 正在运行
- CodexBar Hook 已开启
- 用户已开启"阻止系统休眠"
- 至少有一个 Codex 任务处于运行状态
- CodexBarHelper 已注册并获得系统授权
- 当前连续防休眠时限尚未到达

任务等待用户批准时不属于运行状态; 如果同时还有其他任务运行, 防休眠继续生效; 否则立即恢复系统休眠

## 最长时限

可选时限为

- 1 小时
- 2 小时
- 4 小时
- 8 小时
- 12 小时
- 24 小时
- 无限制

默认值为 12 小时; 以下事件会重新开始计时

- 新任务进入运行状态
- 等待批准的任务恢复运行

普通工具, 压缩和子 Agent 活动不会延长时限; 到达上限后, 即使任务仍在运行, 也会恢复系统休眠; 后续新任务或等待批准后恢复运行可以开始新的计时周期

## 系统休眠控制

功能生效时, 主 App 同时执行两项操作

1. 创建 `PreventUserIdleSystemSleep` IOKit assertion, 阻止空闲系统休眠
2. 通过 root helper 执行 `/usr/bin/pmset -a disablesleep 1`

恢复时按相反顺序处理

1. helper 将 `SleepDisabled` 恢复为功能生效前的值
2. 主 App 释放 IOKit assertion
3. 如果 MacBook 当前合盖, 系统配置认为合盖应休眠, 且原始 `SleepDisabled` 为关闭状态, 主 App 主动请求一次系统休眠

如果系统在 CodexBar 介入前已经禁用休眠, 恢复时会保留该状态

## Helper 注册

CodexBar 使用 `SMAppService.daemon` 注册随 App 打包的 LaunchDaemon; 首次开启时, macOS 可能要求用户在"系统设置 → 通用 → 登录项与扩展"中允许 CodexBar 后台项目

Release 标识

```text
App:    app.zabrian.codexbar
Helper: app.zabrian.codexbar.helper
```

Debug 标识

```text
App:    app.zabrian.codexbar.debug
Helper: app.zabrian.codexbar.debug.helper
```

App 包内文件位置

```text
Contents/Resources/CodexBarHelper
Contents/Library/LaunchDaemons/<helper bundle id>.plist
```

CodexBar 会对 helper 可执行文件和 plist 计算指纹; App 更新后指纹变化时, 已注册服务会注销并重新注册, 确保 launchd 使用当前版本

## XPC 边界

主 App 通过 privileged XPC Mach service 调用唯一接口

```swift
setSleepDisabled(_ disabled: Bool, reply: (Int32, Bool) -> Void)
```

helper 只允许与自身相同 Team ID, 且 bundle identifier 为对应 CodexBar App 的已签名客户端连接

helper 的权限范围仅包括

- 读取当前 `SleepDisabled`
- 执行 `/usr/bin/pmset -a disablesleep 0|1`
- 在固定目录维护一份恢复哨兵
- 接受上述 XPC 开关请求

helper 不提供网络, 任意命令执行或任意文件访问接口

## 恢复哨兵

helper 在修改系统设置前, 将原始 `SleepDisabled` 写入

```text
/Library/Application Support/CodexBar/<helper bundle id>.state
```

文件内容只能是 `0` 或 `1`; 目录要求由 root 所有且不可由 group 或 other 写入; 哨兵文件权限设置为 `0600`

恢复成功后删除哨兵; 以下路径都会尝试恢复

- 主 App 主动请求
- 最后一个 XPC 连接断开 15 秒后
- helper 启动时发现遗留哨兵
- 无连接时每 60 秒检查一次
- helper 收到 `SIGTERM` 或 `SIGINT`

哨兵损坏或不可读时, helper 按允许休眠恢复, 避免把 `SleepDisabled=1` 长期留在系统中; 哨兵损坏时不会继续执行新的禁用休眠操作

## 故障处理

主 App 在休眠切换失败后重新建立 XPC 连接并按递增间隔重试, 累计约 8.5 分钟后停止; 重新出现任务状态变化或用户操作后, 可以启动新的切换流程

设置页可能显示

- 需要后台项目授权
- helper 未注册或资源缺失
- IOKit assertion 创建或释放失败
- XPC 连接失败
- `pmset` 执行失败
- 已达到最长防休眠时限

## 开发与验证

日常构建会把 helper 和对应配置的 LaunchDaemon plist 嵌入 App; 修改相关代码后至少检查

1. App 包内 helper 和 plist 路径正确
2. App, helper 和 XPC 客户端签名匹配
3. 首次开启可以完成后台项目授权
4. 运行任务时 `pmset -g` 显示 `SleepDisabled 1`
5. 等待批准, 任务完成, 关闭 Hook, 关闭功能和达到时限后恢复原值
6. App 或 XPC 异常退出后, watchdog 或定时检查能够恢复
7. Debug 和 Release helper 不互相注册

只需要注销 CodexBar 的 KeepAlive LaunchDaemon 时, 可在退出所有 CodexBar 实例后运行

```bash
Scripts/cleanup.swift
```

使用 `--dry-run` 查看目标, 使用 `--check` 只验证临时清理 App 和签名, 不执行注销
