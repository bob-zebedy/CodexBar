# 阻止系统休眠

本文档记录设置页「阻止系统休眠」的状态口径、特权边界、恢复路径和打包要求。实现思路参考 [Nemuri](https://github.com/syfssb/nemuri) 的 `pmset disablesleep`、特权 helper 与哨兵/看门狗设计；CodexBar 直接复用自身 Hook 实时状态机，不引入第二套任务检测。

## 用户行为

- 开关默认关闭，偏好键为 `KeepAlive.isEnabled`。
- 功能依赖 Codex Hook；Hook 关闭后开关会自动关闭、清除开启偏好并恢复休眠，且在 Hook 关闭期间置灰不可操作。重新开启 Hook 后仍保持关闭，由用户决定是否再次开启。
- 首次开启通过 `SMAppService.daemon(plistName:)` 注册 LaunchDaemon。状态为 `requiresApproval` 时，设置页引导用户打开 macOS「登录项与扩展」。
- 只有 `CodexActivitySnapshot.runningTasks` 非空时，才同时把 `SleepDisabled` 设为 `1` 并持有 `PreventUserIdleSystemSleep` assertion，覆盖空闲、合盖和手动系统休眠。`waitingTasks`、最近完成、最近终止和空闲都恢复休眠。
- 并发任务采用 any-running 语义：只要还有一个运行任务就继续保活。
- 用户可选择最长防休眠期限：1、2、4、8、12、24 小时或无限制，默认 12 小时，偏好键为 `KeepAlive.maximumContinuousDurationSeconds`。有限期限只维护一个计时起点，每个新运行任务第一次出现在实时快照中，或同一任务从 `waitingApproval` 恢复为 `running` 时，都把共享起点更新为当前时间；无限制不创建到期计时器。
- 达到期限后立即恢复任务开始前的休眠设置；即使旧任务仍在运行，也不会因 App 激活、设置刷新或同一运行阶段内的普通 Hook 活动而重置期限。等待批准后恢复运行属于新的运行阶段，会清除到期状态并获得完整的新期限；多任务场景下，这次恢复也会更新所有运行任务共享的截止时间。到期后改为无限制，或改为按当前起点计算后仍未到期的更长期限，会清除到期状态并继续当前周期。每次 App 成功恢复时，先由 helper 还原 `SleepDisabled`，再释放空闲休眠 assertion，让 macOS 根据当前空闲计时、用户活动、其他 assertion 和电源策略立即重新评估是否应休眠。App 不自行推算空闲期限，也不在开盖时无条件强制休眠。如果 helper 确认恢复结果为 `SleepDisabled=0`，且系统同时确认已经合盖并且合盖应触发休眠，CodexBar 还会主动请求系统休眠。该流程统一覆盖进入等待批准、任务完成或终止、没有活动任务、关闭功能和达到期限等恢复路径，无需记录本轮是否出现过合盖休眠意图。外接显示器合盖模式或原始设置本来就是禁止休眠时不会强制休眠。所有运行和等待任务都从实时快照消失或用户关闭再开启功能也会重置计时状态。

`PermissionRequest` 本身不是等待用户。`CodexActivityMonitor` 只有在 rollout 确认同 turn 的 `approvals_reviewer == user` 后才把任务移入 `waitingApproval`；`auto_review`、兼容的自动 reviewer 或尚未确认 reviewer 时仍保持运行。因此防休眠与 UI、通知使用同一份已经归一的状态，不直接解释 Hook 事件。

## 为什么不用 caffeinate

`ProcessInfo.beginActivity`、IOKit idle sleep assertion 和 `/usr/bin/caffeinate` 适合阻止空闲休眠，但不能可靠覆盖 MacBook 合盖触发的休眠。合盖继续运行需要系统级 `/usr/bin/pmset -a disablesleep 1`，写入该设置需要 root 权限。CodexBar 同时使用 idle sleep assertion，不是因为 `pmset` 无法禁止空闲休眠，而是为了在 helper 恢复全局设置后通过释放 assertion 触发 macOS 自己重新评估已累计的空闲状态。

CodexBar 使用 macOS 15 可用的 ServiceManagement 新 API。LaunchDaemon plist 位于 App 包的 `Contents/Library/LaunchDaemons/`，helper 位于 `Contents/Resources/`；主 App 不执行 `sudo`，也不持有任意 root 命令能力。

## 组件边界

| 组件                             | 职责                                                                            |
| -------------------------------- | ------------------------------------------------------------------------------- |
| `KeepAliveController`            | MainActor 上订阅活动快照、保存偏好、刷新 `SMAppService.Status`、管理 XPC 和重试 |
| `SystemSleepService`             | 持有/释放空闲休眠 assertion；恢复后读取当前合盖状态，并在满足条件时请求系统休眠 |
| `Shared/CodexBarHelperXPC.swift` | 从当前 bundle identifier 派生 Mach service 名，并声明恢复时限和唯一 XPC 方法    |
| `CodexBarHelper`                 | root 下串行执行固定的 `pmset` 命令、维护哨兵、看门狗和信号恢复                  |
| LaunchDaemon plist               | 声明 `BundleProgram`、Mach service、RunAtLoad 和 KeepAlive                      |

helper 的 XPC listener 使用代码签名 requirement。它从自身签名动态取得 Team ID，并由 helper identifier 推导对应的 App identifier，只接受两者都匹配的 Apple 签名客户端。对外接口只有：

```text
setSleepDisabled(Bool)
```

helper 不接受命令、路径或环境变量参数，不访问网络，不读取 Codex 配置、事件或会话内容。唯一写入目录是 root-owned `/Library/Application Support/CodexBar/`；哨兵文件名为当前 Mach service 名加 `.state`，因此 Release 使用 `app.zabrian.codexbar.helper.state`，Debug 使用 `app.zabrian.codexbar.debug.helper.state`。

helper 在恢复请求的 XPC reply 中同时返回成功恢复后的 `SleepDisabled` 值。App 收到成功 reply 后释放 idle sleep assertion，无论开盖还是合盖，都由 macOS 先按当前状态重新评估空闲休眠。App 只有确认 `SleepDisabled` 为 `0`，并重新读取到 `AppleClamshellState=true` 与 `AppleClamshellCausesSleep=true` 时才额外主动请求系统休眠。没有哨兵、读取失败、恢复失败或系统状态无法确认都按保守结果处理，不会误触发主动休眠。

## 原始状态与恢复

第一次请求关闭休眠时，helper 先用 `pmset -g` 读取 `SleepDisabled`；macOS 未输出该字段时按默认值 `0` 处理。helper 把原始 `0/1` 写入权限为 `0600` 的哨兵，再执行 `pmset -a disablesleep 1`。恢复时写回哨兵保存的原值，成功后才删除哨兵；因此任务开始前已经由用户或其他工具关闭休眠时，CodexBar 不会擅自改成开启休眠。

恢复路径：

1. 最后一个运行任务进入等待、完成、终止或消失时，App 立即请求恢复；等待任务恢复运行时把恢复时刻设为新的共享计时起点，并获得完整的新期限。
2. 达到从最近任务启动起计算的最长防休眠期限时请求恢复。新的运行任务、等待任务恢复运行、所有运行和等待任务都消失后再次出现任务，或用户关闭再开启功能时会开始新一轮。用户改为无限制，或改为按当前起点计算后仍未到期的更长期限，也会继续当前周期。
3. 关闭功能或正常退出 App 时在可用连接上请求恢复；连接已经断开时释放 App 持有的 assertion，并由下一条兜底恢复全局设置。
4. 最后一个 XPC 连接断开且哨兵存在时，helper 等待 15 秒后恢复；App 快速重连会取消该次看门狗。
5. helper 每 60 秒检查一次「没有连接、没有看门狗、仍有哨兵」，用于重试瞬时 `pmset` 失败。
6. helper 启动发现哨兵，或收到 `SIGTERM` / `SIGINT` 时，立即尝试恢复。

helper 的所有连接状态、命令与 timer 都在同一串行队列上修改。App 侧为每次 XPC 请求分配 generation，迟到回调不能覆盖后续任务状态；连接中断且目标状态不变时会延迟重连。若功能在断线重连等待期间关闭，App 会取消重连并释放本地 idle sleep assertion，全局 `SleepDisabled` 由 helper 的 15 秒断线看门狗恢复。凡是 App 收到成功的恢复 reply，都会在 `SleepDisabled` 已经还原后释放 idle sleep assertion，由系统重新评估空闲休眠，再检查恢复值与当前合盖状态，并在确认当前合盖应休眠时调用 `IOPMSleepSystem`；helper 在 App 已退出时执行的看门狗或启动恢复仍只负责恢复原设置。App 进程退出时其 assertion 会由系统自动释放，但异常退出路径不保证与 helper 的延迟恢复形成和正常 reply 相同的顺序。

## 打包与发布

Xcode 工程包含 `CodexBar` 和 `CodexBarHelper` 两个 target。主 target 显式依赖 helper，并在构建阶段：

- 把 helper 复制和签名到 `Contents/Resources/CodexBarHelper`。
- Debug 使用 `app.zabrian.codexbar.debug`，并只嵌入 `app.zabrian.codexbar.debug.helper.plist`。
- Release 使用 `app.zabrian.codexbar`，并只嵌入 `app.zabrian.codexbar.helper.plist`。

Debug 与 Release 使用独立的 App bundle identifier、helper bundle identifier、Mach service、LaunchDaemon label 和哨兵文件，避免开发授权与注册状态相互影响。App 从自身 bundle identifier 加 `.helper` 得到 Mach service 名，helper 直接使用自身 bundle identifier，LaunchDaemon plist 名和哨兵文件名再由该 service 名派生；helper target 的生成式 Info.plist 嵌入可执行文件，保证独立运行时也能取得自身 identifier。helper 启动时从自身代码签名读取 Team ID，并从自身 identifier 的 `.helper` 后缀推导对应的 App identifier，以生成 XPC 客户端签名要求，不在 Swift 源码中硬编码开发团队或 App identifier。由于 `pmset` 修改的是整台 Mac 的全局状态，不要同时运行 Debug 与 Release App 的防休眠功能。

Apple 要求包含 `SMAppService` LaunchDaemon 的分发 App 正确签名和公证。日常 `xcodebuild ... build` 可验证编译、bundle 结构和开发签名；完整 Developer ID 导出和公证仍走 `Scripts/build.sh`。

App 按固定顺序计算嵌入的 helper 可执行文件与当前构建配置 LaunchDaemon plist 的内容 SHA-256，并记录已注册服务对应的指纹。每次启动都会检查已注册或等待批准的服务，即使「阻止系统休眠」当前关闭；任一文件内容与记录不一致时，App 会等待 `SMAppService.unregister` 完成后重新注册，使服务使用当前 App 包内的 helper 和 plist。功能关闭且服务从未注册时不会主动注册；只有 App 本体变化而这两个嵌入文件内容不变时也不会重复注册。macOS 可能在注销刚完成时短暂拒绝重新注册；App 会先让出一次主线程事件循环，并只对 `SMAppServiceErrorDomain Code=1` 的 `Operation not permitted` 做 0.5、1、2 秒有限退避重试，其他签名、授权或配置错误立即返回。

`KeepAliveController.stop()` 先把控制器标记为停止，再取消 Helper 注册任务、XPC 重试和最长时限任务。Helper 注册任务会在注销前和注销完成后检查取消状态；只有控制器仍在运行且任务未取消时，才提交 Helper 状态、打开系统设置或重新收敛防休眠。`shouldDisableSleep` 同时要求控制器处于运行状态，因此停止后的异步结果不能重新关闭系统休眠。如果停止发生在旧 Helper 已注销而新 Helper 尚未注册时，下次 App 启动会根据当前偏好和 `SMAppService.Status` 决定是否重新注册。

开发机需要注销 Debug 和 Release 遗留的 KeepAlive 服务时，先退出所有 CodexBar 实例，再运行 `Scripts/cleanup.swift`。该独立 Swift 脚本为两个构建身份分别创建临时签名 App，并通过 `SMAppService.unregister()` 定向注销 KeepAlive LaunchDaemon；它不会调用 `sfltool resetbtm`，也不会重置其他 App 的后台项目。每个清理目标优先使用对应 App 包内的 Helper；目标包缺少可执行 Helper 时，只回退到同一 Debug 或 Release 构建配置的 Xcode 产物，不跨配置复用 Helper。可先使用 `--dry-run` 检查目标，使用 `--check` 只验证临时 App 的编译与签名，或使用 `--debug-only` / `--release-only` 只处理一个构建身份。清理后对应的 `KeepAlive.isEnabled` 偏好会被设为关闭，避免下次启动立即重新注册。

`SMAppService.unregister()` 只保证服务不再加载。macOS 的 Background Task Management 数据库可能继续保留已禁用的 App/Helper 历史记录，并在后续系统维护时清除，因此「App 后台活动」中可能暂时仍显示 CodexBar。系统没有公开的按 bundle identifier 立即删除单条 BTM 历史记录的接口；`sudo sfltool resetbtm` 会重置所有第三方 App 的后台项目与授权，不属于本脚本的定向清理范围。

## 手动验收

1. 把签名、公证后的 App 放入 `/Applications`，开启 Codex Hook。
2. 开启「阻止系统休眠」，按提示允许 CodexBar 后台项目。
3. 启动任务，确认设置行显示「当前禁止系统休眠」，`pmset -g` 显示 `SleepDisabled 1`。
4. 让任务进入等待用户批准，确认恢复为任务开始前的值；开盖时将系统空闲休眠设为较短时间，等待空闲期限先在任务运行期间经过，再确认进入等待后释放 assertion、由 macOS 按当前策略休眠；有其他有效 assertion 或近期用户活动时不应被 CodexBar 强制休眠。批准后继续运行时再次关闭休眠，并确认最长防休眠期限从恢复时重新完整计算。
5. 同时运行两个任务，确认其中一个等待或完成时不会提前恢复，最后一个停止运行后才恢复。
6. 选择较短期限并保持任务运行至到期，确认设置页提示已达到上限、系统休眠恢复；激活 App、刷新设置或让同一任务产生新 Hook 活动后仍不重新关闭休眠。
7. 分别验证等待、完成、终止、空闲、关闭功能和到期行为：开盖时由 macOS 按当前空闲计时、其他 assertion 与电源策略决定是否休眠；普通合盖且没有外接显示器时应在恢复后进入休眠；合盖连接外接显示器并处于正常外接屏工作模式时只恢复设置、不主动休眠。
8. 在开始任务前手动设置 `SleepDisabled=1`，确认到期时恢复原值且不主动休眠；结束后自行恢复测试机原有设置。
9. 在旧任务仍运行且已经到期时启动新任务，确认立即重新关闭系统休眠并从新任务启动时开始完整的新周期；另行确认到期前启动新任务，以及任一等待任务获批恢复运行，都会把共享截止时间更新为对应启动或恢复时刻加完整期限。
10. 运行期间关闭 Codex Hook，确认防休眠开关自动关闭并置灰、系统休眠恢复；重新开启 Hook 后确认防休眠开关仍保持关闭。
11. 保持服务已注册，分别替换 helper 可执行文件内容和当前构建配置的 LaunchDaemon plist 内容，确认下次启动都会刷新注册；关闭「阻止系统休眠」后重复验证，确认仍刷新已注册服务但不关闭系统休眠。仅替换 App 本体且保持这两个文件内容不变时，确认不会重复注册。
12. 运行期间正常退出与强制终止 CodexBar，确认最多经过看门狗宽限后恢复；另在 helper 刷新注册期间退出，确认停止后不再回写注册状态或重新请求防休眠，并在下次启动时按当前偏好和 `SMAppService.Status` 收敛。
13. 运行期间终止 helper，确认 launchd 重启后通过哨兵恢复，再由仍活跃的 App 按快照重新收敛。

不要在密闭包内执行合盖验收。该功能会增加耗电和发热，当前不包含低电量自动放行策略。
