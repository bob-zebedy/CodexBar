# Repository Guidelines

## 项目结构与模块组织

CodexBar 是面向 macOS 15+ 的 `LSUIElement` 菜单栏应用，使用 Swift 6, SwiftUI, AppKit 和 MVVM。工程只有 `CodexBar` scheme，包含主 App 与 `CodexBarHelper` 两个 target。

`CodexBar/` 按 `App/` `Views/` `Controllers/` `Models/` `Services/` 和 `Resources/` 分层。root LaunchDaemon 位于 `CodexBarHelper/` 目录，跨 target XPC 接口位于 `Shared/` 目录。`Scripts/` 提供发布和 helper 清理工具，`Images/` 存放 README 资源。

## 构建、测试与开发命令

- `xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build` 执行代码变更后的构建验证
- `swiftformat .` 按 `.swiftformat` 格式化全部 Swift，使用 Swift 6 和 4 空格缩进
- `swiftlint` 按 `.swiftlint.yml` 检查
- `/usr/bin/log stream --predicate 'subsystem == "app.zabrian.codexbar"' --style compact` 查看系统日志，Debug 版 subsystem 带 `.debug` 后缀

`Scripts/build.sh` `dmg.sh` 和 `appcast.sh` 需要 Developer ID 与公证凭据，不用于日常验证。

## 写作风格

代码、代码注释和项目文档使用彼此独立的规则，不得把一类内容的标点约定直接套用到另一类内容。提交信息由 Git 规范单独约束。

### 代码和注释

代码和注释统一遵守：

- 禁止使用中文标点，一律使用半角标点
- 句中停顿和并列项使用空格或者逗号，顿号的位置也用空格或者逗号
- 分号只用来断开完整句子，相当于句号；拿不准就把它换成句号读一遍，两边都能独立成句才保留
- 行末禁止使用标点
- 行内标点后如果还有文字，间隔一个英文空格
- 注释中引用类型、成员、参数或命令后尽量不要紧跟标点，需要断句时补一个词或者使用空格再断
- 一个注释段只解释一件事，需要说明多个独立主题时拆成多个注释段

### 项目文档

项目文档统一遵守：

- 代码标识符、命令、路径、配置键、原始字段值和需要精确复制的版本号使用行内代码
- 中文正文使用全角中文标点，包括 `，` `。` `；` `：` `！` `？` `“”` 和 `（）`
- 中文短词或短语的并列使用 `、`；能独立表达语义的分句使用 `，`，两边都能独立成句时才考虑 `；`
- 中文标点前后不加空格；中文与英文、数字或行内代码之间按词语边界保留一个半角空格
- 不机械替换特殊内容中的英文标点。数字序列、行内代码序列或英文术语并列时，如果英文标点观感更好，使用英文标点并在其后保留一个半角空格
- 普通正文行末使用与语义匹配的中文标点；引出列表、表格或代码块的正文使用 `：`
- 标题、独立列表项、编号项和表格单元格行末不加标点
- 如果一行以 Markdown 格式的链接或行内代码结尾，后面不加任何标点；链接或行内代码位于句中时仍按句子结构使用中文标点
- Markdown 语法、代码块、命令、路径、URL、版本号和程序标识符内部的符号保持原样

## 架构与编码约定

启动时必须先调用 `WorkflowHookEventRecorder.handleIfRequested()` 方法。`--hook-event` 模式只读取 `stdin`，加锁写入 JSONL 并立即退出，不初始化 UI，失败也不能阻断 Codex。Handler 超时按事件从 `hookTimeoutSeconds(for:)` 取得，`SessionEnd` 为 3 秒，其他事件为 5 秒。普通模式由 `CodexBarAppDelegate` 统一装配长期服务。

工程默认采用 `MainActor` 隔离。UI, Controller, ViewModel 和 Settings 依赖默认隔离，共享可变状态放入 actor，DTO 和跨 actor 值类型按需添加 `nonisolated` 标记，禁止在主 actor 执行阻塞 I/O。类型命名使用 `UpperCamelCase` 风格，成员命名使用 `lowerCamelCase` 风格。注释只解释非显然的生命周期、焦点、actor 或系统 API 约束。

保持三条数据链路独立：app-server 额度与用量、Hook 历史聚合、`CodexActivityMonitor` 实时任务。helper 只能执行固定的睡眠控制和自动重置唤醒计划，不得增加网络、任意命令执行或额外文件访问。账户主链路必须检查当前 app-server 的实际版本不低于 `0.143.0`。修改 Hook 配置时必须保留用户和其他应用已有的 handler。启用和校验 Hook 必须额外检查当前 app-server 的实际版本不低于 `0.145.0`。新增网络访问、日志数据或 CloudKit 字段前先核对隐私边界。

自动重置默认关闭，提前量可选 15 分钟、30 分钟、1 小时、2 小时、4 小时或 6 小时，默认 30 分钟。状态机只处理新鲜响应明确列出的 `available + codexRateLimits + expiresAt` 凭证，每轮连续重试最多 5 分钟。CodexBarHelper 只接收有限时间戳，使用固定 owner 和固定 `wake` 类型维护一个系统事件；目标变化、功能关闭、App 退出、对应 XPC 连接断开或 helper 启动时必须收敛并清理该事件。修改 owner 或事件类型属于清理兼容性问题。

自动重置和防睡眠从关闭切换为开启时必须先显示确认框。确认文案按 `HelperStatus` 展示：`.notRegistered` 和 `.notFound` 使用 `需要安装并授权 CodexBar Helper 后台运行`，`.requiresApproval` 使用 `已安装 CodexBar Helper 但需要授权允许后台运行`，`.enabled` 只显示对应功能说明。确认后写入用户意图并触发 helper 注册，Helper 授权系统设置仅由设置行的 `打开系统设置` 按钮显式打开。两个开关关闭时不显示状态说明。自动重置子面板入口仅在开关开启且 helper 状态为 `.enabled` 时显示，条件失效时关闭已展开面板。

缺少 session ID 的 Hook 事件使用匿名 project key。匿名任务保留在实时快照和 UI 中，活动卡片与任务中心统一显示橙色 `person.crop.circle.dashed` 图标，`help` 为 `匿名任务不参与防睡眠`。匿名任务不发布任务通知或触觉反馈，不参与防睡眠和异常会话保护，不生成保护状态持久化标识。活动卡片的 `+N` 只显示其他活跃任务总数。

`CodexActivityMonitor` 的异常会话保护跟随防睡眠主开关，只判定非匿名运行中任务，等待批准任务不参与判定。静默阈值可选 30 分钟, 1, 2 或 4 小时，默认 1 小时。Hook bootstrap、系统睡眠、唤醒恢复或 Hook 数据源不可用期间必须暂停判定，数据恢复后统一无通知对账。

`HookEventTailReader.drainNow()` 是读取屏障，每个调用方必须等待一轮在本次请求之后开始的读取。系统唤醒只有在该轮读取成功后才执行 rollout 生命周期对账并恢复异常会话保护判定。reader 更换时丢弃旧结果，数据源不可用或任务取消时不得使用旧快照继续判定。

异常会话保护记录由 `ActivityProtectionStateStore` 保存在 `~/Library/Application Support/CodexBar/ActivityProtection/state.json`，只包含哈希任务标识和时间戳，最长保留到最后进展后的 24 小时。Debug 与 Release 通过 `flock` 共用该文件，当前 schema 为 `1`。修改格式或身份计算属于兼容性问题。

需要从原始 Hook 事件重新计算的聚合算法、输出字段、字段含义或去重规则变化时，必须递增 `WorkflowMaintenanceState.currentAggregationSchema`，统一从保留期内的原始 JSONL 完整重建，不新增字段级历史迁移。Hook 计数字段缺失表示历史来源不可用，不能解码成明确的 `0`

## 测试规范

仓库没有 XCTest target 或覆盖率门槛。每次改动至少应完成构建，运行 `swiftformat` 和 `swiftlint` 两项检查，并手动验证受影响流程。菜单、窗口焦点、Hook、同步、通知和防睡眠改动必须说明手动验证场景。Debug 与 Release 使用不同 App 和 helper bundle ID，排查时不要混用。

## Git 规范

不要主动 push，不要回滚、覆盖或丢弃他人的未提交修改。用户只要求提交时，不要顺带格式化或修改文件。

提交标题使用 `<type>: <中文描述>` 格式：

- 常用 type 包括 `feat` `fix` `chore` `refactor` `docs`
- message 里不要出现版本号或发布字样，只描述改动本身，版本信息由 tag 承载
- 修复和发布提交需要 body
- 标题与 body 之间空一行
- body 中的 bullet 连续排列，每条缩进 4 个空格
- commit message 中不要出现版本号，Release 标记或其他发布版本相关内容

Tag 名 `v{MARKETING_VERSION}` 里的版本号从 `Config/Version.xcconfig` 读取，使用附注 tag `git tag -a v3.x.y -m "Release v3.x.y"`

## 代码修改原则

- 优先结合现有文件结构和类型职责，不为小改动新建抽象
- 改 shared controller、shared service、模型解析或持久化 key 时，要考虑旧数据和降级路径；用户设置要保持默认值；持久化 key 和旧版本迁移兼容
- **任何兼容性问题都必须主动询问用户，不要自行决定**；只要改动会影响新旧共存就适用，不限于旧数据迁移或丢弃、持久化 key 改名或改结构、老版本升上来的降级路径、最低系统版本与 API 可用性取舍、云端记录格式变更；先说清影响面和几种做法的代价，等用户选定再动手
- 处理窗口、菜单、快捷键、App 激活或事件监听时，特别注意 `LSUIElement` 应用特有的焦点行为
- 注释保持克制，只解释非显然的生命周期、焦点、actor 或系统 API 约束；现有注释多为解释为什么的类型，沿用同样风格
- 改动涉及菜单面板、窗口焦点、Hook、同步、通知、自动重置唤醒或防睡眠时，构建通过之外还要说明应手动覆盖的交互场景；helper 相关改动额外要验证 App 包内 helper 与 plist 位置、签名、首次系统授权、运行/等待切换、唤醒计划替换与清理和异常退出后的恢复
