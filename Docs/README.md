# CodexBar 文档

CodexBar 文档按读者和职责分成两套，使用说明与实现细节保持独立：

| 文档 | 目标读者 | 解决的问题 |
| --- | --- | --- |
| [用户手册](UserGuide/README.md) | 使用 CodexBar 的普通用户 | 如何安装，使用功能，理解设置和排查常见问题 |
| [开发者指南](DeveloperGuide/README.md) | 贡献者和代码阅读者 | App 如何实现，数据如何流动，核心约束如何验证 |

## 推荐阅读路径

### 第一次使用 CodexBar

1. 阅读 [安装与快速开始](UserGuide/getting-started.md)
2. 了解 [主面板与菜单栏](UserGuide/main-panel.md)
3. 按需开启 [实时任务与 CodexBar Hook](UserGuide/activity-and-hook.md)
4. 在 [设置参考](UserGuide/settings.md) 中确认自动重置、防睡眠和其他选项的作用

### 排查使用问题

1. 先查看 [常见问题与排查](UserGuide/troubleshooting.md)
2. 再从 App 的日志窗口确认 app-server 请求状态
3. 涉及本机文件或网络边界时查看 [数据，同步与隐私](UserGuide/sync-data-privacy.md)

### 阅读或修改代码

1. 从 [整体架构](DeveloperGuide/architecture.md) 建立全局视图
2. 按改动范围进入对应的数据链路或服务文档
3. 在 [开发与验证](DeveloperGuide/development.md) 中查看构建，调试和验证方式
4. 在 [数据与隐私边界](DeveloperGuide/data-and-privacy.md) 中查看本地与云端数据范围

## 目录结构

```text
Docs
├── UserGuide
│   ├── README.md
│   ├── getting-started.md
│   ├── main-panel.md
│   ├── activity-and-hook.md
│   ├── notifications.md
│   ├── sleep-prevention.md
│   ├── sync-data-privacy.md
│   ├── settings.md
│   └── troubleshooting.md
└── DeveloperGuide
    ├── README.md
    ├── architecture.md
    ├── design-decisions.md
    ├── app-server.md
    ├── hook-and-aggregation.md
    ├── activity-monitor.md
    ├── sleep-prevention.md
    ├── sync.md
    ├── notifications.md
    ├── ui-and-lifecycle.md
    ├── data-and-privacy.md
    └── development.md
```
