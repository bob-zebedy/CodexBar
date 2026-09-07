# 设计原则与关键决策

简体中文 | [English](../en/DeveloperGuide/design-decisions.md)

## 状态所有权

每条数据链路由一个服务维护事实，消费者读取快照或转场：

| 链路 | 状态来源 | 输出用途 |
| --- | --- | --- |
| app-server | 账户、额度和用量响应 | 周期性展示，同账户内可使用 stale 缓存 |
| Hook 历史 | 原始 JSONL | 可重建的日级统计与跨设备同步 |
| 实时任务 | Hook 增量事件与 rollout 生命周期 | 活动快照、任务通知和防睡眠 |

快照可以反复读取；通知使用 live transition，bootstrap 只建立基线，不补发历史通知。历史聚合与额度刷新共享部分触发时机，但读取和失败处理独立。组件关系见 [整体架构](architecture.md)

## 用户意图与实际效果

保存的开关表示用户意图，依赖状态决定是否能执行，结果状态表示已经确认的效果。依赖临时不可用时保留用户开关，恢复后重新协调。

防睡眠的 `isEnabled`、`sleepBlockReason` 和 `isPreventingSleep` 分别对应这三层。Hook 的 `isEnabled` 与 `isVerified` 共同决定 `isOperable`；实时任务依赖可操作状态，历史聚合仍可处理已落盘数据。

## 缺失、陈旧与不可信数据

| 状态 | 当前处理 |
| --- | --- |
| app-server 补充接口暂时失败 | 使用同账户缓存并标记 stale，降低 UI 透明度，不触发额度通知或自动消费 |
| method unsupported | 当前 session 缓存能力缺失，重建连接后重新探测 |
| 历史 Hook 计数字段缺失 | 持久化和同步模型保留 `nil`；当前展示投影仍会按规则回退为计数 |
| 实时 reader 无法取得稳定边界 | 发布 degraded health，暂停异常会话保护 |

这些状态由来源层给出，消费方按用途决定是否展示或执行副作用。计数投影见 [Hook 聚合](hook-and-aggregation.md)，账户缓存见 [app-server](app-server.md)

## 并发与过期结果

| 手段 | 保护范围 |
| --- | --- |
| `MainActor` | UI、控制器及可观察状态的提交顺序 |
| actor | 服务进程内的共享状态和 I/O 协调 |
| `NSLock` 等锁 | 非隔离 pipe reader 等同步接口的可变状态 |
| `flock` | Hook 子进程、主 App、Debug 与 Release 之间的共享文件事务 |

异步调用返回时，配置或 reader 可能已经变化。不能取消的系统回调通过 generation 校验后才提交；请求取消与代际检查各自处理任务生命周期和结果归属。

菜单淡入淡出的完成任务在取消检查后同步提交，因此只保存一个可取消 Task。XPC、reader 更换和系统唤醒路径仍需 generation；各路径的具体字段见对应专题。

Combine 的 `@Published` 在 `willSet` 发布。组合设置状态时使用订阅闭包收到的新值，避免回读尚未更新的属性。

## 可重建数据与恢复记录

Hook 原始 JSONL 是历史重建来源，日聚合是派生结果。聚合语义变化通过 schema 递增触发保留期内完整重建。文件替换由 `sourceGeneration` 区分，同日同源数据按替换合并，独立来源才累加。

异常会话保护记录和 helper ownership 则用于恢复已经发生的状态变化。前者异步保存，隐藏不等待落盘；后者必须先持久化恢复责任，再修改系统睡眠值。具体顺序见 [实时任务监控](activity-monitor.md) 和 [防睡眠系统](sleep-prevention.md)

## 特权与上传范围

任务识别、自动重置策略和网络访问在主 App 中执行。root helper 只接受固定的睡眠租约与唤醒操作，通过签名校验客户端，并回读系统结果。

CloudKit 只同步日级聚合。原始事件、会话标识、账户和代理密码留在本机；项目显示名属于上传内容，必须由用户开启同步。字段和存储范围见 [数据与隐私边界](data-and-privacy.md)
