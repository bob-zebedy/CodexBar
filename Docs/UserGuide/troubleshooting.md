# 常见问题与排查

## 菜单栏找不到 CodexBar

- CodexBar 是菜单栏 App，不显示 Dock 图标
- 在 macOS 控制中心设置中确认菜单栏项目没有被隐藏
- 从 Applications 再次启动不会创建第二个实例
- 仍然找不到时，在活动监视器中确认 CodexBar 是否正在运行

## 主面板显示未登录

1. 打开当前正在使用的 Codex CLI, ChatGPT App 或 Codex App
2. 完成 Codex 登录
3. 双击 CodexBar 主面板中的账户图标刷新
4. 仍然未登录时退出并重新打开 CodexBar

CodexBar 优先使用全局 Codex CLI，关于页面的 `当前使用` 标记可以确认实际来源。

## 主面板显示初始化失败

常见原因如下：

- 没有找到可执行的 Codex
- Codex app-server 启动失败
- app-server 没有在超时时间内响应
- app-server 返回了无法解析的响应

打开日志窗口查看最近失败的请求和错误详情，再到关于页面确认 Codex 路径和版本。

## 额度或 Token 显示变淡

变淡表示本轮读取失败后回退到了同一账户的缓存数据。

缓存用于保留上次可用信息，不代表数据已经成功刷新。

双击账户图标重试，如果持续变淡则查看日志窗口中的 `account/rateLimits/read` 和 `account/usage/read`

## Hook 无法开启或校验失败

| 提示 | 含义 | 建议处理 |
| --- | --- | --- |
| 需要更高 Codex 版本 | 当前 app-server 版本不足 | 更新 Codex 后重启 CodexBar |
| Codex Hook 已全局关闭 | `features.hooks` 已禁用 | 在 Codex 配置中重新启用 Hooks |
| CodexBar Hook 已不完整 | 至少一个必要事件缺少当前 handler | 关闭后重新开启 CodexBar Hook |
| CodexBar Hook 未被信任 | Codex 仍把 handler 判定为未信任或已修改 | 重新开启 Hook 并检查 Codex 配置 |
| CodexBar Hook 意外来源 | app-server 返回的来源不是当前配置文件 | 检查 `CODEX_HOME` 和当前 Codex 来源 |
| `hooks.json` 文件格式错误 | 顶层或 `hooks` 结构不是有效 JSON | 修复 JSON 后重新操作 |
| 无法验证 Codex Hook | app-server 暂时不可用或校验失败 | 查看日志并在 Codex 可用后重新打开设置 |

Hook 配置位于 `$CODEX_HOME/hooks.json`，未设置 `CODEX_HOME` 时位于 `~/.codex/hooks.json`

升级 CodexBar 后出现 Hook 不完整提示时，关闭并重新开启 Hook 会补齐当前版本要求的事件。

## 实时任务没有出现

1. 确认 CodexBar Hook 已开启且没有错误提示
2. 确认 `主面板任务中心` 已开启
3. 新建一轮 Codex 任务以产生实时事件
4. 打开设置窗口触发一次 Hook 重新校验

历史回放期间不会发送旧任务通知，数据源边界不稳定时会降级并跳过不可信历史。

## 收不到系统通知

按以下顺序检查：

1. `系统通知` 总开关是否开启
2. macOS 是否允许 CodexBar 发送通知
3. 对应通知子开关是否开启
4. 任务类通知所需的 CodexBar Hook 是否有效
5. 任务完成时长是否达到所选阈值
6. 通知音效是否选择了静音

触觉反馈不依赖 macOS 通知权限，但依赖 CodexBar 通知总开关。

## 防睡眠没有生效

按以下顺序检查：

1. CodexBar Hook 是否有效
2. `防止系统睡眠` 是否开启
3. 当前是否存在运行中任务
4. 只有等待任务时，`等待批准时保持` 是否开启
5. 设置页是否提示需要批准 CodexBar 后台运行
6. 是否正在触发低电量保护
7. 是否已经达到最长防睡眠时间

咖啡杯表示系统睡眠当前确实被阻止，开关打开但没有咖啡杯不一定是故障。

如果设置页显示 `系统睡眠已由其他来源关闭`，CodexBar 不会覆盖该来源。

## CodexBarHelper 无法注册

- 确认 `自动重置` 或 `防止系统睡眠` 已开启；关闭状态不显示 Helper 状态说明
- Helper 等待系统批准时，点击设置行下方的 `打开系统设置` 并允许 CodexBar 后台运行
- 确认 CodexBar 位于 Applications 中且 App 包完整
- 如果提示服务异常或 CodexBarHelper 文件缺失，重新安装完整 CodexBar App
- 更新后持续失败时退出 CodexBar，重新打开并再次检查授权

## 自动重置没有按时执行

按以下顺序检查：

1. `自动重置` 是否开启，提前量是否符合预期
2. 自动重置设置行是否提示 CodexBarHelper 待批准、未注册或唤醒计划失败；临期选项按钮只在 Helper 已获得系统批准时显示
3. 当前 app-server 是否返回了具体的可用重置次数和过期时间
4. 计划时间到达后，网络与 Codex 登录状态是否可用
5. “自动重置通知”是否开启；通知关闭不会阻止自动重置本身执行

自动重置只处理 app-server 最新响应明确列出的凭证。单轮网络或暂时服务故障最多连续重试 5 分钟，后续普通额度刷新仍会为仍然有效的凭证重新安排。

关闭自动重置或退出 CodexBar 会取消当前唤醒计划。需要核对系统计划时，可在 Terminal 中执行：

```bash
pmset -g sched
```

## 跨设备同步不可用

- 确认 Mac 已登录 iCloud
- 确认 iCloud Drive 和 CloudKit 服务当前可用
- 确认 CodexBar Hook 已开启
- 确认 `跨设备同步` 开关已开启
- 将鼠标悬停在主面板底部 iCloud 图标上查看具体状态

同步失败不会删除本机 Hook 数据，后续维护会再次尝试。

## 更新 Codex 后仍显示旧版本

当前版本来自已经运行的 app-server 握手，磁盘版本来自重新执行 Codex `--version`

如果关于页面显示新安装版本但 `当前使用` 仍是旧版本，退出并重新打开 CodexBar。

## 使用日志窗口

打开方式如下：

- 右键菜单栏图标并选择 `日志`
- 主面板打开时按 `⌘L`

日志窗口保留当前进程最近 500 条 app-server 请求。

每条记录包含请求时间、方法、状态和响应时间，展开后可以查看请求、响应或错误预览。

完整内容可以在独立窗口中查看或复制，清空或退出 App 后不会恢复。

## 查看系统日志

在 Terminal 中执行以下命令：

```bash
/usr/bin/log stream --predicate 'subsystem == "app.zabrian.codexbar"' --style compact
```

Debug 版本的 `subsystem` 使用 `.debug` 后缀。

提交问题时请描述复现步骤和可见错误，分享日志前先检查 App 内交互日志是否包含不希望公开的请求内容。

返回 [用户手册](README.md)
