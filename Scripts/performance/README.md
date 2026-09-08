# App 性能测试与报告

通过 Instruments 采集运行中 macOS App 主进程的 CPU、调用栈、内存、线程、唤醒、磁盘活动和热状态，自动生成单文件 HTML 报告。默认测试 `/Applications/CodexBar.app`，通过 `--app` 可指定其他 App。

## 快速开始

准备好以下环境：

- macOS、完整 Xcode、Python `3.11+`
- `xcode-select -p` 指向 Xcode 的 `Contents/Developer` 目录
- 被测 App 已启动，终端具备 Instruments 采集权限

在仓库根目录运行：

```sh
python3 -B Scripts/performance/run.py --preset standard
```

脚本完成预检、预热、分阶段采集、数据解析和报告生成，结束后在终端打印 `report.html` 路径。采集直接附加到现有 App 进程。按 `Ctrl-C` 可停止采集并保存已有结果，App 继续运行。

默认输出目录为 `Build/Performance/YYYYMMDD-HHMMSS`。`Scripts/build.sh` 会清理 `Build`，需要长期保留的结果请指定其他目录：

```sh
python3 -B Scripts/performance/run.py \
  --preset standard \
  --output PerformanceResults/idle-01 \
  --workload '闲置：面板关闭，无手动操作，接通电源'
```

采集输出目录必须尚未存在。测试期间保持单个 Instruments 采集任务，并将构建等高负载工作安排在采集结束后。

## 选择测试时长

| 预设 | 预热 | CPU 采集 | 资源观察 | 后续观察 | 累计采集 |
|---|---:|---:|---:|---:|---:|
| `quick` | 5 秒 | 2 × 20 秒 | 60 秒 | 20 秒 | 2 分钟 |
| `standard` | 20 秒 | 3 × 60 秒 | 300 秒 | 60 秒 | 9 分钟 |
| `extended` | 30 秒 | 3 × 120 秒 | 900 秒 | 120 秒 | 23 分钟 |

- `quick`：检查采集流程，快速观察操作时的资源变化
- `standard`：日常性能评估，观察重复采样与后台活动
- `extended`：观察更长时间的内存变化和周期性任务

实际运行时间还包括 Instruments 初始化、保存和导出。`cpu-*` 阶段使用 `Time Profiler + Activity Monitor`，同时采集调用栈、资源指标和 Hangs；`soak`、`settle` 阶段使用 `Activity Monitor` 继续观察资源变化。

## 组织测试场景

采集和报告由脚本自动执行，界面操作由测试者执行。用 `--workload` 记录场景、操作步骤、活动任务和电源状态。

| 场景 | 执行方式 | 重点观察 |
|---|---|---|
| 闲置 | 关闭面板，保持后台设置一致，采集期间不手动操作 | CPU 常态与突增、唤醒频率、内存基线 |
| 高频操作 | 按固定顺序反复打开面板、切换页面和滚动列表 | 主线程热点、CPU 峰值、Hangs、内存峰值 |
| 操作后闲置 | 记录停止操作的时间，随后保持面板关闭 | CPU 回落、内存释放、后台活动 |

比较两个版本时，使用相同的预设和操作步骤，并记录各次结果。比较闲置与高频操作时，分别保存报告，按阶段查看差异。

## 参数

| 参数 | 用途 |
|---|---|
| `--app` | 被测 App 路径，默认 `/Applications/CodexBar.app` |
| `--pid` | 指定进程；存在多个匹配实例时使用 |
| `--preset` | `quick`、`standard` 或 `extended`，默认 `standard` |
| `--output` | 采集模式指定新目录；`--render` 模式指定 HTML 文件路径 |
| `--workload` | 写入报告的测试场景说明 |
| `--baseline` | 指定同场景历史 `results.json`，采集后计算阶段差值 |
| `--cpu-mean-budget` | 各阶段平均 CPU 上限，单位为 `%` |
| `--footprint-budget` | 各阶段内存 footprint 峰值上限，单位为 `MiB` |
| `--render` | 从已有 JSON 生成 HTML |

例如，将平均 CPU 上限设为 `5%`、内存峰值上限设为 `512 MiB`：

```sh
python3 -B Scripts/performance/run.py \
  --cpu-mean-budget 5 \
  --footprint-budget 512
```

上限值须为有限正数。脚本逐阶段检查预算，超出项写入报告。

## 阅读报告

报告按数据总览、阶段对比、唤醒与磁盘、运行曲线、CPU 热点、事件与热状态、采集记录组织。

| 数据 | 图表与读数方式 |
|---|---|
| CPU、footprint、RSS、压缩内存 | 分别绘制趋势图；同一指标各阶段共用纵轴，标注峰值 |
| 线程数量 | 阶梯图 |
| 内存最小值、中位数、峰值 | 区间图 |
| 内存首尾窗口中位数 | 哑铃图，标注增减量 |
| 主线程采样占比 | 百分比堆叠条 |
| 调用栈热点 | 按采样权重排列的横向条形图 |

趋势图支持鼠标游标和键盘滑块读数，采样间隔超过 5 秒时断开连线。报告支持深浅主题、展开热点、导出 JSON 和打印，可离线打开。中文使用苹果系统字体，英文和数字使用本机安装的 `MesloLGS NF`。

### 指标含义

- **CPU**：累计 CPU 时间增量除以观测时长，`100%` 表示占用一个逻辑核心。平均值按有效观测时长加权，P50、P95 为区间 CPU 使用率样本的线性插值分位数，峰值为区间使用率最大值
- **内存**：分别展示 physical footprint、RSS 和压缩内存，单位为 `MiB`。趋势斜率由阶段样本作最小二乘拟合，单位为 `MiB/min`。首尾窗口长度取 60 秒与阶段跨度四分之一中的较小值
- **唤醒与磁盘**：累计计数取阶段末值减去初值，平均速率除以阶段资源观测时长
- **CPU 热点**：按调用栈采样权重统计，单位为 `ms`。叶节点表示栈顶函数，调用链权重包含子调用，同一调用栈中的递归符号计一次
- **Hangs**：按导出的事件计数，检测配置保存在阶段数据的 `hang_settings` 中。空表记为 `0`，缺失数据展示为 `N/A`
- **App 文件指纹**：被测 App 主可执行文件的 SHA-256；`Mach-O UUID` 标识各架构二进制，用于匹配 dSYM

### 与历史结果比较

```sh
python3 -B Scripts/performance/run.py \
  --preset standard \
  --output PerformanceResults/idle-02 \
  --workload '闲置：面板关闭，无手动操作，接通电源' \
  --baseline PerformanceResults/idle-01/results.json
```

脚本核对 App 的 bundle ID、系统、芯片、架构、核心数、内存容量、电源来源、Instruments、场景说明、预设、预算、数据格式和阶段计划。两次采集均完整且上述条件一致时，报告展示各阶段平均 CPU 差值和 footprint 中位数差值；条件不匹配时列出差异字段。App 版本可以不同。

## 输出文件与重新生成报告

| 文件 | 内容 |
|---|---|
| `report.html` | 内嵌样式、图表、交互脚本和统计 JSON 的报告 |
| `results.json` | 完整统计结果、采集状态、命令及日志索引 |
| `schemas.json` | 当前 Xcode 的 XML 列定义 |
| `tool-source/` | 采集启动时的工具源码快照，文件哈希保存在 `results.json` |
| `*.trace` | 可用 Instruments 打开的原始记录 |
| `*-toc.xml`、各 schema 的 XML | trace 目录信息与导出的采样数据 |
| `*.log` | 各条采集、导出命令的日志 |

修改报告模板后，用已有结果重新生成 HTML：

```sh
python3 -B Scripts/performance/run.py \
  --render PerformanceResults/idle-01/results.json
```

默认更新 JSON 同目录的 `report.html`。指定另一个文件可保留原报告：

```sh
python3 -B Scripts/performance/run.py \
  --render PerformanceResults/idle-01/results.json \
  --output PerformanceResults/idle-01/report-updated.html
```

报告页面导出的统计 JSON 也可传给 `--render`。

## 采集检查与排错

阶段有效须满足以下条件：

- 被测可执行文件、PID 和进程启动时间保持一致
- 记录成功，时长达到计划的 `90%`
- 至少 3 个资源样本，资源观测跨度达到计划的 `80%`
- 最大资源采样间隔不超过 5 秒
- CPU 计数覆盖率至少 `95%`，累计计数不回退
- 成功取得 footprint；CPU 阶段成功解析 `time-profile` 表

| 退出码 | 含义 |
|---|---|
| `0` | 采集完整，已配置的预算检查通过 |
| `2` | 参数、环境、采集、解析、质量检查或结果保存失败 |
| `3` | 采集完整，超过配置预算 |
| `130` | 操作者中断采集 |

根据终端输出、报告中的错误信息和对应阶段日志排查：

| 现象 | 处理方式 |
|---|---|
| 找不到 App 进程或匹配到多个实例 | 启动目标 App，核对 `--app`，必要时指定 `--pid` |
| 缺少模板或列定义 | 检查 `xcode-select -p`，确认使用完整 Xcode |
| Instruments 附加失败 | 查看 `*-record.log` 中的权限或进程错误，处理后重新采集 |
| 输出目录不存在或被替换 | 查看是否执行了构建清理，将后续输出放到 `Build` 以外 |
| 热点只显示地址 | 使用与 `Mach-O UUID` 匹配的 dSYM，在 Instruments 中符号化 |

最终保存失败时，脚本会尝试将内存中已有的统计数据和原始错误写入系统临时目录 `codexbar-performance-recovery-*`，并打印报告路径；若恢复保存也失败，终端会输出对应错误。
