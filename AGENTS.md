# Repository Guidelines

## 项目结构与模块组织

CodexBar 是面向 macOS 15+ 的 `LSUIElement` 菜单栏应用, 使用 Swift 6, SwiftUI, AppKit 和 MVVM. 工程只有 `CodexBar` scheme, 包含主 App 与 `CodexBarHelper` 两个 target

`CodexBar/` 按 `App/` `Views/` `Controllers/` `Models/` `Services/` 和 `Resources/` 分层. root LaunchDaemon 位于 `CodexBarHelper/` 目录, 跨 target XPC 接口位于 `Shared/` 目录. `Scripts/` 提供发布和 helper 清理工具, `Images/` 存放 README 资源

## 构建, 测试与开发命令

- `open CodexBar.xcodeproj` 在 Xcode 中运行 Debug scheme
- `xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build` 执行日常构建验证
- `swiftformat .` 按 `.swiftformat` 格式化全部 Swift, 使用 Swift 6 和 4 空格缩进
- `swiftlint` 按 `.swiftlint.yml` 检查 `CodexBar/`
- `Scripts/cleanup.swift --help` 查看 KeepAlive helper 清理选项

`Scripts/build.sh` `dmg.sh` 和 `appcast.sh` 需要 Developer ID 与公证凭据, 不用于日常验证

## 写作风格

本仓库的中文文本 (提交信息, 代码注释, 文档) 统一遵守

- 禁止使用中文标点, 一律使用半角标点
- 句中停顿和并列项使用空格或者逗号, 顿号的位置也用空格或者逗号
- 分号只用来断开完整句子, 相当于句号; 拿不准就把它换成句号读一遍, 两边都能独立成句才保留
- 行末禁止使用标点
- 行内标点后如果还有文字, 间隔一个英文空格
- 行内代码后尽量不要紧跟标点, 需要断句时补一个词或者使用空格再断
- 一条 bullet 只讲一件事, 需要两个以上完整句子时拆成多条

## 架构与编码约定

启动时必须先调用 `WorkflowHookEventRecorder.handleIfRequested()` 方法. `--hook-event` 模式只读取 stdin, 加锁写入 JSONL 并立即退出, 不初始化 UI, 失败也不能阻断 Codex. 普通模式由 `CodexBarAppDelegate` 统一装配长期服务

工程默认采用 `MainActor` 隔离. UI, Controller, ViewModel 和 Settings 依赖默认隔离, 共享可变状态放入 actor, DTO 和跨 actor 值类型按需添加 `nonisolated` 标记, 禁止在主 actor 执行阻塞 I/O. 类型命名使用 `UpperCamelCase` 风格, 成员命名使用 `lowerCamelCase` 风格. 注释只解释非显然的生命周期, 焦点, actor 或系统 API 约束

保持三条数据链路独立: app-server 额度与用量, Hook 历史聚合, `CodexActivityMonitor` 实时任务; helper 只能控制休眠, 不得增加网络, 任意命令执行或额外文件访问; 修改 Hook 配置时必须保留用户和其他应用已有的 handler; 新增网络访问, 日志数据或 CloudKit 字段前先核对隐私边界

## 测试规范

仓库没有 XCTest target 或覆盖率门槛. 每次改动至少应完成构建, 运行 `swiftformat` 和 `swiftlint` 两项检查, 并手动验证受影响流程. 菜单, 窗口焦点, Hook, 同步, 通知和防休眠改动必须说明手动验证场景. Debug 与 Release 使用不同 App 和 helper bundle ID, 排查时不要混用

## Commit 与 Pull Request 规范

不要主动 push, 不要回滚, 覆盖或丢弃他人的未提交修改. 用户只要求提交时, 不要顺带格式化或修改文件

提交标题使用 `<type>: <中文描述>` 格式

- 常用 type 包括 `feat` `fix` `chore` `refactor` `docs`
- message 里不要出现版本号或发布字样, 只描述改动本身, 版本信息由 tag 承载
- 修复和发布提交需要 body
- 标题与 body 之间空一行
- body 中的 bullet 连续排列, 每条缩进 4 个空格
- commit message 中不要出现版本号, Release 标记或其他发布版本相关内容

PR 应说明用户影响, 实现范围, 关联 issue 和验证结果, UI 改动附截图或录屏. 涉及旧数据, 持久化 key, 云端格式, 最低系统版本或新旧共存的兼容性决策, 必须先说明选项与代价并询问用户
