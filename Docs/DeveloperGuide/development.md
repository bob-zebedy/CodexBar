# 开发与验证

简体中文 | [English](../en/DeveloperGuide/development.md)

## 环境与构建

需要 macOS 15+、Xcode、Swift 6、`swiftformat` 和 `swiftlint`。唯一 scheme 为 `CodexBar`，包含 App、`CodexBarHelper` 和 `CodexBarTests` 三个 target。

```bash
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' test
swiftformat .
swiftlint
```

格式配置见 `.swiftformat`，使用 Swift 6 和 4 空格缩进。`swiftlint` 检查 `CodexBar/` 和 `CodexBarTests/`，不覆盖 `Shared/`、`CodexBarHelper/` 和 `Scripts/`

修改前检查 `git status --short`。已有未提交改动时，仅格式化本次涉及的 Swift 文件，或使用 `swiftformat --lint . --cache ignore` 检查。`swiftlint --no-cache` 可避免写入缓存。

日常构建不需要 Developer ID 或公证凭据。写作、Git 和兼容性规则见 [AGENTS.md](../../AGENTS.md)

## 单元测试

`CodexBarTests` 使用 Swift Testing，并加入共享的 `CodexBar` scheme，可用 Xcode 的 Test 操作或上述命令执行。

测试 target 无 App 宿主，与 App 使用相同的 Swift 6、`MainActor` 和并发设置，直接编译 `CodexBar/` 与 `Shared/` 源码。`CODEXBAR_TESTING` 仅在测试 target 定义，用于移除 `@main`；测试不实例化 App，不启动 Codex、CloudKit 同步或 helper。这样无需为测试拆分生产模块，代价是测试构建会额外编译一份 App 源码。

| 测试范围 | 关键约束 |
| --- | --- |
| Hook 与 JSONL | 名称归一化、坏行隔离、元数据读取预算、半行补齐、bootstrap 与 live 分流、文件替换 |
| 实时任务 | 匿名身份、时长、乱序进展、子 Agent 计数、各执行归属独立的审批状态 |
| rollout 生命周期 | 完成与进展、读取覆盖、损坏行、文件丢失或替换、归档定位 |
| 聚合与同步模型 | ID 去重、事件对计数、缺失计数、增量与重放一致性、同设备 generation 去重 |
| 持久化与设置 | 保护记录过期、跨实例合并、条件删除、旧记录默认值、配置损坏与回填 |
| 额度、代理与展示 | 凭证筛选、稳定 UUID、实际运行版本、代理输入和环境变量、日期与热力图状态 |
| 异步刷新 | 取消和代际过期后不提交结果、不结束较新的刷新 |

每个文件测试创建独立临时目录，每个偏好测试创建独立 `UserDefaults` suite，并在结束时清理。测试使用固定时间、显式日历和受控异步检查点；新增测试应沿用这些隔离方式。

单元测试不覆盖真实 CloudKit、app-server、系统通知、窗口焦点和 helper 电源行为。这些流程仍按下方手动场景验证。

## 修改入口

| 功能 | 主要位置 | 实现说明 |
| --- | --- | --- |
| app-server、代理、自动重置 | `Services/CodexStatus` 与对应 Settings | [app-server 数据链路](app-server.md) |
| Hook 安装与统计 | `CodexHookSettings`、`WorkflowService`、聚合模型 | [Hook 采集与历史聚合](hook-and-aggregation.md) |
| 实时任务与异常保护 | `CodexActivityMonitor` 和 readers | [实时任务监控](activity-monitor.md) |
| 防睡眠与系统唤醒 | `KeepAliveController`、`AutoResetWakeScheduler`、helper | [防睡眠系统](sleep-prevention.md) |
| 通知与音效 | `CodexNotificationService`、通知 Settings | [通知系统](notifications.md) |
| 同步 | `WorkflowSyncService` 与 scheduler | [CloudKit 同步](sync.md) |
| 菜单、窗口、快捷键 | `Controllers` 与对应 View | [UI 与应用生命周期](ui-and-lifecycle.md) |

长期对象由 `CodexBarAppDelegate` 装配。新增状态优先放入现有所有者，View 消费快照并发出操作意图。源码阅读入口见 [整体架构](architecture.md)

## 变更检查

涉及持久化 key、schema、身份计算、最低系统版本或新旧版本共存时，先说明影响和可选兼容方案，等待用户选定。新增网络访问、日志字段或 CloudKit 字段时核对 [数据与隐私边界](data-and-privacy.md)

聚合算法、输出字段含义或去重规则变化时，递增 `WorkflowMaintenanceState.currentAggregationSchema`，从保留期内原始 JSONL 完整重建，不增加字段级历史迁移。

异步修改需要检查取消、结果提交时的资格和 generation。跨进程文件仍使用 `flock`；actor 只保护单进程。`@Published` 订阅使用闭包的新值参与判断，避免 `willSet` 阶段回读旧属性。

## 验证流程

1. 检查修改范围，确认未覆盖已有工作
2. 格式化并运行 `swiftlint`
3. 构建 App 与 helper，并运行单元测试
4. 手动验证受影响的正常、失败和恢复流程
5. 检查文档及 `git diff --check`

构建失败时先定位第一条实际 `error:`。签名或 entitlement 错误要核对 Debug/Release 身份；helper 协议修改同时检查两个 target 与 `Shared`。编译和静态检查不覆盖窗口焦点、系统授权或硬件电源行为。

纯文档修改运行格式检查、lint 和构建，并检查相对链接与中英文内容。

### 手动场景

| 改动范围 | 重点场景 |
| --- | --- |
| 菜单与窗口 | 快速开关、淡出中重开、popover/fallback、多屏与 Space、设置和日志焦点、通知点击和快捷键 |
| Hook 与聚合 | 保留已有 handler、最低版本、并发追加、半行和损坏行、文件替换与截断、完整重建 |
| 实时任务 | bootstrap 不补通知、等待审批、迟到终态、匿名任务、唤醒读取屏障失败与恢复 |
| 通知 | 授权拒绝与恢复、阈值跨越、同周期去重、任务恢复撤回、声音缺失 |
| 代理 | 首次配置、启停、无效配置停用、损坏记录删除、测试取消、快速操作与失败回滚 |
| 同步 | 首次上传、多设备合并、断网续传、部分上传失败、重建替换、iCloud 账户切换 |
| 系统电源与 helper | 首次授权、任务运行/等待切换、低电量、时长上限、外部睡眠来源、异常退出与重启 |
| 自动重置唤醒 | 计划替换、关闭与退出清理、连接中断、helper 重启、注销前清零、到点重新读取 |

helper 改动还需检查 App 包内可执行文件和 plist 的位置、签名与注册指纹。各专题末尾列出更细的状态转换场景。

记录验证使用的构建、前置设置、操作序列、实际结果和相关日志，便于复现。

### 性能验证

CPU、内存、唤醒、磁盘活动与采集环境见[性能报告](https://codexbar.zabrian.app/performance)

结果对应报告中记录的构建和测试场景。采集、生成报告和基线对比方法见[性能采集工具说明](../../Scripts/performance/README.md)

## Debug 与 Release

| 配置 | App bundle ID | Helper bundle ID |
| --- | --- | --- |
| Debug | `app.zabrian.codexbar.debug` | `app.zabrian.codexbar.debug.helper` |
| Release | `app.zabrian.codexbar` | `app.zabrian.codexbar.helper` |

App 偏好和系统授权按身份隔离，Hook 数据与异常会话保护文件共享。排查时确认正在运行的 App、helper 和已安装 Hook 的可执行路径。

## 日志

Release 系统日志：

```bash
/usr/bin/log stream --predicate 'subsystem == "app.zabrian.codexbar"' --style compact
```

Debug 使用 `app.zabrian.codexbar.debug`，helper 的 subsystem 使用对应 helper bundle ID。

App 内日志窗口保留最近 500 条 app-server 交互。代理配置错误在系统日志的 `settings` 分类中，临时代理测试不写交互日志。

| 问题 | 查看内容 |
| --- | --- |
| 额度未刷新 | handshake、method、retry、stale |
| Hook 未生效 | hooks 配置、版本、信任与完整性 |
| 任务未结束 | reader generation、rollout 对账、数据源健康 |
| 同步缺数据 | zone、fetch、upload、replacement、prune 阶段 |
| 通知未出现 | authorization、kind、duplicate、obsolete |
| 防睡眠未生效 | block reason、helper 注册、XPC generation、source |
| 自动重置未执行 | target、threshold、retry window、wake schedule |

日志使用 `LogTrigger`、`LogDuration` 和 `LogFields.joined`，记录阶段、分类、计数及耗时。请求内容和身份信息的限制见 [数据与隐私边界](data-and-privacy.md)

## 发布与清理脚本

| 脚本 | 用途 |
| --- | --- |
| `Scripts/build.sh` | Release archive、Developer ID 导出、公证、staple 与 Gatekeeper 校验 |
| `Scripts/dmg.sh` | 打包 DMG |
| `Scripts/appcast.sh` | 签名更新并生成 appcast |
| `Scripts/cleanup.swift` | 注销 helper；先退出所有 CodexBar 实例，`--check` 只检查，`--debug` 或 `--release` 限定范围 |

发布脚本需要签名和公证凭据，不用于日常验证。版本号从 [`Version.xcconfig`](../../Config/Version.xcconfig) 读取。

helper 清理先取消并确认系统唤醒计划清零，再注销服务；失败时停止。详细行为见 [防睡眠系统](sleep-prevention.md)
