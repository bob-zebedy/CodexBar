# 开发与验证

## 环境要求

- macOS 15 或更高版本
- Xcode 和 macOS SDK
- Swift 6 toolchain
- `swiftformat`
- `swiftlint`
- 本机可用的 Codex CLI 或包含内置 Codex 的 App

工程使用 `CodexBar` scheme，日常构建不需要 Developer ID 或公证凭据。

## 工程结构

| 目录 | 职责 |
| --- | --- |
| `CodexBar/App` | App 启动入口 |
| `CodexBar/Controllers` | AppKit 生命周期，菜单栏和窗口控制 |
| `CodexBar/Models` | 业务 DTO，快照和展示模型 |
| `CodexBar/Services` | app-server，Hook，任务，同步，通知和系统服务 |
| `CodexBar/Views` | SwiftUI 界面 |
| `CodexBar/Resources` | plist，entitlement，本地化和资源 |
| `CodexBarHelper` | root LaunchDaemon |
| `Shared` | XPC 共享接口 |
| `Config` | 版本配置 |
| `Scripts` | 发布和维护脚本 |

## 日常检查

### 构建

```bash
xcodebuild \
  -project CodexBar.xcodeproj \
  -scheme CodexBar \
  -destination 'generic/platform=macOS' \
  build
```

### 格式化

```bash
swiftformat .
```

工程使用 Swift 6 和 4 空格缩进，配置位于 `.swiftformat`

### 静态检查

```bash
swiftlint
```

规则位于 `.swiftlint.yml`

仓库当前没有 XCTest target 或覆盖率门槛。构建，格式化和 lint 不能替代受影响流程的手动验证。

## 日志

查看 Release 系统日志：

```bash
/usr/bin/log stream \
  --predicate 'subsystem == "app.zabrian.codexbar"' \
  --style compact
```

Debug subsystem 带 `.debug` 后缀。

App 内日志窗口展示当前进程最近 500 条 app-server 交互日志，适合排查 CLI 定位，handshake，method unsupported 和重试。

## Debug 与 Release

两种配置使用不同身份：

| 配置 | App bundle ID | CodexBarHelper bundle ID |
| --- | --- | --- |
| Release | `app.zabrian.codexbar` | `app.zabrian.codexbar.helper` |
| Debug | `app.zabrian.codexbar.debug` | `app.zabrian.codexbar.debug.helper` |

排查 CodexBarHelper 安装，LaunchDaemon 或系统授权时不要混用两个配置。

Hook handler 绑定当前 App 可执行文件路径。在 Debug 和 Release 之间切换时，先确认实际安装的 handler 指向目标版本。

## 架构规则

### 启动入口

`WorkflowHookEventRecorder.handleIfRequested()` 必须是 App 初始化的第一项工作。

`--hook-event` 模式只读取 stdin，加锁写入 JSONL 并立即退出。不初始化 UI，通知，CloudKit 或其他长期服务。

### MainActor

UI，Controller，ViewModel 和 Settings 依赖默认隔离。阻塞文件，子进程和网络 I/O 放入 actor 或异步服务。

共享可变状态放入 actor。DTO 和跨 actor 值类型按需要补充并发声明，不通过关闭检查绕过 Swift 6 诊断。

### 数据链路

保持以下链路独立：

- app-server 账户，额度与用量
- Hook 历史聚合
- `CodexActivityMonitor` 实时任务

新增 UI 可以组合 3 条链路的快照，但不能让一条链路成为另一条链路的隐式前置条件。

### Hook

- handler 修改保留现有用户和第三方配置
- 启用与校验检查实际 app-server 版本不低于 `0.145.0`
- Hook 子进程失败不能阻断 Codex
- `SessionEnd` 超时为 3 秒，其他事件为 5 秒
- `drainNow()` 必须维持读取屏障语义
- 数据源不可用时不能使用旧快照继续判定

### 聚合

原始事件到聚合结果的算法，字段，含义或去重规则变化时：

1. 递增 `WorkflowMaintenanceState.currentAggregationSchema`
2. 从保留期内原始 JSONL 完整重建
3. 不增加字段级历史迁移
4. 保留 missing 与 `0` 的区别
5. 标记 CloudKit 当前设备 replacement 日期

### 防睡眠

- CodexBarHelper 只控制睡眠
- CodexBarHelper 不增加网络或任意命令能力
- 外部 `SleepDisabled=1` 不能被 CodexBar 声明或恢复
- 租约，watchdog 和 owned 持久化必须共同成立
- App 退出前确认系统状态恢复

### 兼容性

以下变化属于兼容性问题：

- 持久化 key 改名或结构变化
- 本地 schema 变化
- CloudKit record 或字段变化
- CodexBarHelper ownership 格式变化
- Debug 与 Release 共享身份计算变化
- 最低系统版本或 API 可用性变化

这些变化会影响旧数据，旧 App 或 Debug 与 Release 共存，需要配套的迁移和降级设计。

## 按改动类型验证

### 菜单和窗口

- 左键，右键和 Control 点击行为
- popover 外部点击关闭
- 侧边面板 hit region 和互斥
- 设置与日志窗口焦点
- 全局快捷键和 fallback panel
- 多显示器与不同菜单栏位置

### Hook 和聚合

- 保留已有 handler
- 版本不满足时拒绝启用
- 所有事件能在超时内落盘
- 文件替换，截断和跨日读取
- schema 升级完整重建
- missing 字段不会显示为 `0`

### 实时任务

- 运行，等待批准，完成和中断转场
- auto review 不进入等待状态
- subagent 归属父任务
- bootstrap 不发送通知
- 系统唤醒完成新读取后再对账
- reader 更换时丢弃旧结果

### 同步

- 首次 backfill
- 多设备合并不重复本机贡献
- 重建只替换当前设备日期
- iCloud 离线，账户切换和恢复
- 保留期清理

### 通知

- 系统权限允许和拒绝
- 阈值 crossing 和持久化去重
- 前台展示与点击激活
- 自定义声音缺失回退
- TUI 通知与 App 通知互不影响

### 防睡眠

- App 包内 CodexBarHelper 和 plist 位置
- App 与 CodexBarHelper 签名
- 首次系统授权
- 运行与等待批准切换
- 低电量和最长时长停止
- 外部 `SleepDisabled` 共存
- 正常退出和异常退出恢复
- Debug 与 Release 分离

## 发布脚本

以下脚本需要 Developer ID，签名，公证或 appcast 凭据，不用于日常验证：

- `Scripts/build.sh`
- `Scripts/dmg.sh`
- `Scripts/appcast.sh`

版本号从 [`Version.xcconfig`](../../Config/Version.xcconfig) 读取
