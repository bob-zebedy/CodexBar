# 性能测试使用说明

## 开始测试

准备 macOS、完整 Xcode 和 Python `3.11+`，启动待测试的 App。`xcode-select -p` 应指向 Xcode 的 `Contents/Developer` 目录，终端需具备 Instruments 采集权限。

在仓库根目录运行：

```sh
python3 -m Scripts.performance --preset quick
```

默认测试 `/Applications/CodexBar.app`。采集期间按测试场景操作 App，用 `--workload` 记录操作内容：

```sh
python3 -m Scripts.performance \
  --preset standard \
  --workload '反复打开面板、切换页面和滚动列表'
```

完成后打开终端打印的 `performance.html` 路径查看报告。

## 测试时长

| 预设 | 采集时长 | 用途 |
|---|---:|---|
| `quick` | 3 分钟 | 快速检查 |
| `standard` | 10 分钟 | 日常测试，默认预设 |
| `extended` | 30 分钟 | 长时间观察 |

时长为各阶段的计划采集时间之和，不含预热、Instruments 启停和数据导出；实际运行时间更长。

## 参数

| 参数 | 用法 |
|---|---|
| `--app PATH` | App 路径，默认 `/Applications/CodexBar.app` |
| `--pid PID` | 指定待测试进程，存在多个 App 实例时使用 |
| `--preset NAME` | 选择 `quick`、`standard` 或 `extended` |
| `--label TEXT` | 本次测试的标签，会追加到采集目录名末尾 |
| `--output PATH` | 配合 `--render` 指定 HTML 文件路径 |
| `--workload TEXT` | 记录测试场景说明，默认 default |
| `--baseline PATH` | 指定基线 `performance.json` |
| `--cpu-mean-budget NUMBER` | 各阶段平均 CPU 上限，单位为 `%` |
| `--footprint-budget NUMBER` | 各阶段 Footprint 峰值上限，单位为 `MiB` |
| `--render PATH` | 从指定 JSON 重新生成报告 |
| `-h`、`--help` | 查看命令帮助 |

## 输出位置

默认输出到仓库根目录下的 `Performance/{version}({build})-{preset}-YYYYMMDDHHmmss/`，日期和时间取测试启动时的本地时间，精确到秒。版本和构建号分别读取 `Config/Version.xcconfig` 中的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`，保留版本号中的点号。

```text
Performance/4.1.1(111)-extended-20261024140000/
├── performance.html
├── performance.json
├── schemas.json
├── tool-source/
├── *.trace
├── *.xml
└── *.log
```

`performance.html` 用于查看报告，`performance.json` 用于基线比较和重新生成报告，`*.trace` 可用 Instruments 打开。目录内同时保存采样 XML、命令日志和工具源码快照。

已有同名目录时，脚本会报错而不覆盖已有结果。采集时可用 `--label` 为本次测试添加标签，在默认目录名后追加 `-{标签}`，标签不能为空或包含 `/`：

```sh
python3 -m Scripts.performance --preset quick --label idle
```

例如，输出目录为 `Performance/4.1.1(111)-quick-20261024140000-idle/`

## 基线比较

先采集基线：

```sh
python3 -m Scripts.performance \
  --preset quick \
  --label idle
```

再次测试时指定实际生成目录中的基线文件，例如：

```sh
python3 -m Scripts.performance \
  --preset quick \
  --baseline 'Performance/4.1.1(111)-quick-20261024140000-idle/performance.json'
```

两个报告均完整，且应用标识、格式、测试配置与环境条件匹配时，报告计算各阶段的 CPU 均值和 Footprint 中位数差值；条件不匹配时列出原因。

CPU 使用 Instruments 导出的 `cpu-percent`，均值按同一采样行的 `duration` 加权；报告总均值按各阶段有效 CPU 采样时长加权。P50、P95 和峰值基于有效采样值计算，缺失值不计为零。CPU 采样覆盖率为有效区间总时长除以完整采样区间跨度。

## 性能预算

将平均 CPU 上限设为 `5%`，Footprint 峰值上限设为 `512 MiB`：

```sh
python3 -m Scripts.performance \
  --cpu-mean-budget 5 \
  --footprint-budget 512
```

预算值须为有限正数。超限阶段会写入报告。

| 退出码 | 含义 |
|---|---|
| `0` | 采集完成且预算检查通过，或重新生成报告成功 |
| `1` | 重新生成报告时，读取、解析 JSON 或生成 HTML 失败 |
| `2` | 参数错误，或采集及结果保存失败 |
| `3` | 采集完成，存在预算超限 |
| `130` | 用户中止采集 |

## 重新生成报告

从已有 JSON 重新生成 HTML 报告：

```sh
python3 -m Scripts.performance --render 'Performance/4.1.1(111)-quick-20261024140000-idle/performance.json'
```

默认更新 JSON 同目录的 `performance.html`。使用 `--output` 指定另一个 HTML 文件：

```sh
python3 -m Scripts.performance \
  --render 'Performance/4.1.1(111)-quick-20261024140000-idle/performance.json' \
  --output 'Performance/4.1.1(111)-quick-20261024140000-idle/performance-updated.html'
```
