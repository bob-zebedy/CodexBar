"""Render a self-contained report with no remote resources or runtime dependencies"""

import html
import json
import math
from pathlib import Path


def escape(value):
    return html.escape(str(value))


def number(value, digits=2, suffix=""):
    return "N/A" if value is None else f"{value:,.{digits}f}{suffix}"


def table(headers, rows):
    head = "".join(f"<th>{escape(h)}</th>" for h in headers)
    body = "".join("<tr>" + "".join(f"<td>{escape(c)}</td>" for c in row) + "</tr>" for row in rows)
    if not body:
        body = f'<tr><td colspan="{len(headers)}" class="muted">无可用数据</td></tr>'
    return f'<div class="table-scroll"><table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table></div>'


def chart(series, key, label, color, unit, phase_index, ceiling=None, step=False):
    width, height, left, right, top, bottom = 960, 250, 68, 28, 32, 40
    points = [p for p in series if p.get(key) is not None]
    if not points:
        return '<div class="empty">无可用采样数据</div>'
    start, end = min(p["t"] for p in series), max(p["t"] for p in series)
    peak = max(points, key=lambda p: p[key])
    maximum = ceiling or nice_max(peak[key])
    x = lambda t: left + (t - start) / max(end - start, 1) * (width - left - right)
    y = lambda v: top + (1 - v / maximum) * (height - top - bottom)
    parts = [f'<div class="trend-chart" data-phase="{phase_index}" data-key="{escape(key)}" data-unit="{escape(unit)}">',
             f'<div class="trend-stats"><b>{escape(label)}</b><span>最低 {number(min(p[key] for p in points))} · 峰值 {number(peak[key])} {escape(unit)}</span></div>',
             f'<svg viewBox="0 0 {width} {height}" role="img" aria-label="{escape(label)} 趋势, 单位 {escape(unit)}">']
    for index in range(5):
        value = maximum * index / 4
        yy = y(value)
        parts.append(f'<line class="grid" x1="{left}" x2="{width - right}" y1="{yy:.2f}" y2="{yy:.2f}"/>')
        parts.append(f'<text x="{left - 10}" y="{yy + 4:.2f}" text-anchor="end">{value:g}</text>')
    for index in range(6):
        t = start + (end - start) * index / 5
        parts.append(f'<text x="{x(t):.2f}" y="{height - 10}" text-anchor="middle">{t:.0f}s</text>')
    segments, current = [], []
    previous = None
    for point in series:
        if point.get(key) is None or (previous is not None and point["t"] - previous > 5):
            if current:
                segments.append(current)
            current = []
        if point.get(key) is not None:
            current.append(point)
        previous = point["t"]
    if current:
        segments.append(current)
    for segment in segments:
        path = f'M {x(segment[0]["t"]):.2f} {y(segment[0][key]):.2f}'
        for point in segment[1:]:
            path += (f' H {x(point["t"]):.2f} V {y(point[key]):.2f}' if step else
                     f' L {x(point["t"]):.2f} {y(point[key]):.2f}')
        parts.append(f'<path d="{path} L {x(segment[-1]["t"]):.2f} {y(0):.2f} L {x(segment[0]["t"]):.2f} {y(0):.2f} Z" fill="{color}" opacity=".10"/>')
        parts.append(f'<path d="{path}" fill="none" stroke="{color}" stroke-width="2"/>')
        if len(segment) == 1:
            parts.append(f'<circle cx="{x(segment[0]["t"]):.2f}" cy="{y(segment[0][key]):.2f}" r="3" fill="{color}"/>')
    anchor = "end" if x(peak["t"]) > width / 2 else "start"
    parts.append(f'<circle cx="{x(peak["t"]):.2f}" cy="{y(peak[key]):.2f}" r="4" fill="{color}"/>')
    parts.append(f'<text x="{x(peak["t"]):.2f}" y="{y(peak[key]) - 10:.2f}" text-anchor="{anchor}">峰值 {peak[key]:.2f}</text>')
    parts.append(f'<line class="cursor" x1="{left}" x2="{left}" y1="{top}" y2="{height - bottom}" hidden/></svg>')
    parts.append(f'<div class="chart-control"><input type="range" min="0" max="{len(series) - 1}" value="0" aria-label="{escape(label)} 采样时间"><output aria-live="polite"></output></div></div>')
    return "".join(parts)


def nice_max(value):
    if value <= 0:
        return 1
    magnitude = 10 ** math.floor(math.log10(value))
    step = magnitude / 2
    return math.ceil(value * 1.1 / step) * step


COLORS = ["#168c80", "#5668cb", "#bd812e", "#c96675"]


def bars(groups, unit="", digits=2):
    values = [value for _, entries in groups for _, value, _ in entries if value is not None]
    low, high = min([0] + values), max([0] + values)
    extent = high - low or 1
    zero = -low / extent * 100
    parts = [f'<div class="bar-chart" role="img" aria-label="{escape(unit)} 柱状图">']
    for label, entries in groups:
        parts.append(f'<div class="bar-group"><div class="bar-label">{escape(label)}</div>')
        for name, value, color in entries:
            parts.append(f'<div class="bar-entry"><span class="bar-series">{escape(name)}</span>')
            if value is None:
                parts.append('<div class="bar-track missing"></div><b class="bar-value">N/A</b>')
            else:
                position = (min(0, value) - low) / extent * 100
                width = abs(value) / extent * 100
                parts.append(f'<div class="bar-track"><span class="zero" style="left:{zero:.4f}%"></span><i style="left:{position:.4f}%;width:{width:.4f}%;background:{color}" data-value="{value}"></i></div><b class="bar-value">{number(value, digits)} <small>{escape(unit)}</small></b>')
            parts.append('</div>')
        parts.append('</div>')
    return ''.join(parts) + ('<div class="empty">无采集数据</div>' if not groups else '') + '</div>'


def ranked(items, unit="ms", color=COLORS[0], digits=0):
    return bars([(label, [("", value, color)]) for label, value in items], unit, digits)


def panel(title, content, note=""):
    return '<article class="panel"><h3>' + escape(title) + '</h3>' + ('<p class="muted">' + escape(note) + '</p>' if note else '') + content + '</article>'


def distribution(main, total):
    if not total:
        return '<div class="empty">无 CPU 样本</div>'
    ratio = main / total * 100
    return f'''<div class="share-chart"><div class="share-track" role="img" aria-label="主线程 {ratio:.1f}%, 其他线程 {100 - ratio:.1f}%"><i style="width:{ratio:.4f}%;background:{COLORS[0]}"></i><i style="width:{100 - ratio:.4f}%;background:{COLORS[1]}"></i></div>
<div class="share-values"><div><span>主线程</span><b>{ratio:.1f}%</b><small>{main:,.0f} ms</small></div><div><span>其他线程</span><b>{100 - ratio:.1f}%</b><small>{total - main:,.0f} ms</small></div></div></div>'''


def interval_chart(rows, paired=False):
    values = [v for _, entries in rows for v in entries if v is not None]
    if not values:
        return '<div class="empty">无可用数据</div>'
    maximum = nice_max(max(values))
    x = lambda value: 100 * value / maximum
    parts = ['<div class="interval-chart">', '<div class="interval-axis"><span>0</span><span>' + number(maximum, 0) + ' MiB</span></div>']
    for label, values in rows:
        parts.append(f'<div class="interval-row"><b>{escape(label)}</b>')
        if any(v is None for v in values):
            parts.append('<span class="muted">N/A</span></div>')
            continue
        first, last = values[0], values[-1]
        description = (f'首段 {first:.1f} → 尾段 {last:.1f} MiB · 变化 {last - first:+.1f} MiB' if paired else
                       f'最小 {first:.1f} · 中位 {values[1]:.1f} · 峰值 {last:.1f} MiB')
        parts.append(f'<div class="interval-track" role="img" aria-label="{escape(description)}"><i class="interval-line" style="left:{x(min(first, last)):.4f}%;width:{x(abs(last - first)):.4f}%"></i>')
        for i, value in enumerate(values):
            kind = ("head" if i == 0 else "tail") if paired else ("median" if i == 1 else "bound")
            parts.append(f'<i class="interval-point {kind}" style="left:{x(value):.4f}%" title="{value:.2f} MiB"></i>')
        parts.append('</div><span class="interval-values">' + description + '</span></div>')
    parts.append('<div class="interval-key">' + ('○ 首段　● 尾段' if paired else '┃ 最小值 / 峰值　● 中位数') + '</div></div>')
    return ''.join(parts)


def write_report(data, destination):
    import collections
    import re
    phases = data.get("phases", [])
    valid = [p for p in phases if p.get("resources") and not p.get("errors")]
    target, env = data.get("target", {}), data.get("environment", {})
    measured = sum(p.get("recorded_s", 0) for p in phases)
    cpu_phases = [p for p in valid if p["resources"].get("cpu_mean") is not None]
    span = sum(p["resources"]["span_s"] for p in cpu_phases)
    cpu_mean = sum(p["resources"]["cpu_mean"] * p["resources"]["span_s"] for p in cpu_phases) / span if span else None
    footprints = [p["resources"]["footprint"]["max"] for p in valid if p["resources"].get("footprint")]
    hang_phases = [p for p in valid if "potential-hangs" in p]
    hangs = sum(p["potential-hangs"]["count"] for p in hang_phases) if hang_phases else None
    state = {"complete": "采集完成", "incomplete": "采集不完整", "running": "采集中", "interrupted": "采集已中断"}.get(data.get("state"), "状态未知")
    tone = "ok" if data.get("state") == "complete" else "warn"
    if data.get("budget_breaches"):
        state, tone = "超过配置预算", "warn"

    def resource_groups(specification, scale=1):
        groups = []
        for phase in valid:
            r = phase["resources"]
            entries = []
            for index, (label, key) in enumerate(specification):
                value = r.get(key)
                entries.append((label, value / scale if value is not None else None, COLORS[index]))
            groups.append((phase["id"], entries))
        return groups

    comparisons = [panel("平均 CPU", bars(resource_groups([("均值", "cpu_mean")]), "%")),
                   panel("CPU P95 与峰值", bars(resource_groups([("P95", "cpu_p95"), ("峰值", "cpu_peak")]), "%"))]
    memory_rows = [(p["id"], [(p["resources"].get("footprint") or {}).get(key)
                              for key in ("min", "median", "max")]) for p in valid]
    comparisons.append(panel("内存 footprint 分布", interval_chart(memory_rows)))
    trends = [(p["id"], p["resources"]["memory_trend"]) for p in valid if p["resources"].get("memory_trend")]
    comparisons.append(panel("footprint 首尾变化", interval_chart([(name, [t["head_median"], t["tail_median"]])
                                                                   for name, t in trends], paired=True),
                             "窗口长度为 60 秒与阶段跨度四分之一中的较小值"))
    comparisons.append(panel("footprint 变化斜率", ranked([(name, t["slope_mib_min"]) for name, t in trends], "MiB/min", digits=2),
                             "按阶段样本作最小二乘拟合"))
    comparisons.append(panel("footprint 首尾差值", ranked([(name, t["delta_mib"]) for name, t in trends], "MiB", digits=2),
                             "尾段窗口中位数减去首段窗口中位数"))
    io_charts = [panel("Idle Wake Ups 速率", bars(resource_groups([("均值", "wakeups_per_s")]), "次/s")),
                 panel("磁盘读取与写入", bars(resource_groups([("读取", "read_bytes"), ("写入", "written_bytes")], 1024), "KiB", 1)),
                 panel("磁盘平均吞吐", bars(resource_groups([("读取", "read_bytes_per_s"), ("写入", "written_bytes_per_s")], 1024), "KiB/s")),
                 panel("系统 CPU", bars([(p["id"], [("均值", p["system"].get("cpu_load_mean"), COLORS[0]),
                                                    ("峰值", p["system"].get("cpu_load_peak"), COLORS[1])])
                                         for p in valid if p.get("system")], "%", 1), "各逻辑核心合计")]
    profiles = [p for p in valid if p.get("profile")]
    total = sum(p["profile"]["sampled_ms"] for p in profiles)
    main = sum(p["profile"]["main_ms"] for p in profiles)
    libraries = collections.Counter()
    for p in profiles:
        for name, weight in p["profile"].get("binaries", []):
            libraries[name] += weight
    hot_overview = panel("主线程 CPU 样本分布", distribution(main, total)) + panel("叶节点所属库 · 已导出 Top 10", ranked(libraries.most_common(10)))
    phase_html, hotspot_html, record_rows, event_rows = [], [], [], []
    ceilings = {key: nice_max(max([point[key] for p in phases for point in p.get("resources", {}).get("series", [])
                                   if point.get(key) is not None] or [0]))
                for key in ("cpu", "footprint", "rss", "compressed", "threads")}
    for index, phase in enumerate(phases):
        r = phase.get("resources", {})
        content = f'<article class="phase" id="phase-{index}"><div class="section-head"><div><span class="eyebrow">{escape(phase["template"])}</span><h3>{escape(phase["id"])}</h3></div><span class="badge {"ok" if phase in valid else "warn"}">{"已采集" if phase in valid else "部分数据"}</span></div>'
        content += f'<p class="muted">{escape(phase.get("trace_started", phase.get("started", "N/A")))} · {number(phase.get("recorded_s"), 2)} s</p>'
        if r:
            content += chart(r["series"], "cpu", "CPU", COLORS[0], "%", index, ceilings["cpu"])
            for key, label, color in zip(["footprint", "rss", "compressed"], ["Footprint", "RSS", "压缩内存"], COLORS):
                content += chart(r["series"], key, label, color, "MiB", index, ceilings[key])
            content += chart(r["series"], "threads", "线程数", COLORS[1], "个", index, ceilings["threads"], step=True)
            metrics = [("CPU P50", number(r.get("cpu_p50"), 2, "%")), ("CPU P95", number(r.get("cpu_p95"), 2, "%")),
                       ("唤醒次数", number(r.get("wakeups"), 0)), ("资源样本", str(r["samples"]))]
            content += '<div class="metric-strip">' + ''.join(f'<div><span>{escape(label)}</span><b>{escape(value)}</b></div>' for label, value in metrics) + '</div>'
        if phase.get("errors"):
            content += '<div class="notice warn">' + '<br>'.join(escape(e) for e in phase["errors"]) + '</div>'
        phase_html.append(content + '</article>')
        profile = phase.get("profile")
        if profile:
            hot = f'<details class="panel hotspot" {"open" if index == 0 else ""}><summary>{escape(phase["id"])} · CPU 采样权重 {profile["sampled_ms"]:,.0f} ms</summary>'
            hot += '<div class="two">' + panel("叶节点热点 · Top 12", ranked(profile["leaf"][:12]))
            hot += panel("调用链热点 · Top 12", ranked(profile["inclusive"][:12], color=COLORS[1]), "权重包含子调用") + '</div>'
            hot += '<div class="two">' + panel("高 CPU 采样权重的 1 秒区间", ranked([(f"{t}–{t + 1} s", value) for t, value in profile["busiest_seconds"]]))
            hot += panel("调用栈采样记录", ranked([("有调用栈", profile["sampled_ms"] - profile["missing_stack_ms"]),
                                                   ("缺失调用栈", profile["missing_stack_ms"]),
                                                   ("含 App 帧", profile["app_stack_ms"]),
                                                   ("含命名 App 帧", profile["app_named_stack_ms"])], color=COLORS[2])) + '</div>'
            hot += '<details><summary>全部已导出热点</summary>' + table(["叶节点", "权重 / ms"], [(name, number(weight, 0)) for name, weight in profile["leaf"]])
            hot += table(["调用链", "权重 / ms"], [(name, number(weight, 0)) for name, weight in profile["inclusive"]]) + '</details></details>'
            hotspot_html.append(hot)
        record_rows.append([phase["id"], phase["template"], number(phase.get("recorded_s"), 2, " s"),
                            r.get("samples", "N/A"), number(r.get("max_gap_s"), 2, " s"),
                            number(r.get("cpu_coverage") * 100 if r.get("cpu_coverage") is not None else None, 1, "%"),
                            "已采集" if phase in valid else "部分数据"])
        for key, label in [("potential-hangs", "Hangs"), ("hang-risks", "Hang risks")]:
            for event in phase.get(key, {}).get("events", []):
                event_rows.append([phase["id"], label, ' · '.join(f'{k}: {v}' for k, v in event.items())])
    events_chart = bars([(p["id"], [("Hangs", p.get("potential-hangs", {}).get("count"), COLORS[0]),
                                    ("Hang risks", p.get("hang-risks", {}).get("count"), COLORS[2])]) for p in phases], "条", 0)
    thermal = '<div class="thermal-grid">'
    for p in phases:
        events = p.get("device-thermal-state-intervals", {}).get("events", [])
        thermal += f'<div class="thermal-phase"><b>{escape(p["id"])}</b>'
        if not events:
            thermal += '<span class="muted">N/A</span>'
        for event in events:
            state_name = event.get("thermal-state", "N/A")
            thermal += f'<div class="thermal-state {"nominal" if state_name.lower() == "nominal" else "elevated"}"><b>{escape(state_name)}</b><span>{escape(event.get("start", ""))} → {escape(event.get("end", ""))}</span></div>'
        thermal += '</div>'
    thermal += '</div>'
    metadata = [["App", target.get("name", "N/A")], ["Bundle ID", target.get("bundle_id", "N/A")],
                ["版本 / 构建", f'{target.get("version", "N/A")} / {target.get("build", "N/A")}'],
                ["macOS / 架构", f'{env.get("os", "N/A")} / {env.get("arch", "N/A")}'],
                ["芯片 / 逻辑核心", f'{env.get("chip", "N/A")} / {env.get("cores", "N/A")}'],
                ["内存", number(int(env["memory_bytes"]) / 2 ** 30, 0, " GiB") if env.get("memory_bytes") else "N/A"],
                ["Instruments", env.get("instruments", "N/A")], ["电源", env.get("power", "N/A")],
                ["工作负载", data.get("config", {}).get("workload", "N/A")]]
    fingerprint = [["App 文件指纹", target.get("binary_sha256", "N/A")],
                   ["Mach-O UUID", '; '.join(f'{arch}: {uuid}' for uuid, arch in target.get("uuids", []))]]
    load_groups = [(label, [("开始", env.get("load_before", [None] * 3)[i], COLORS[0]),
                            ("结束", env.get("load_after", [None] * 3)[i], COLORS[1])])
                   for i, label in enumerate(["1 分钟", "5 分钟", "15 分钟"])]
    optional = ''
    comparison = data.get("comparison")
    if comparison:
        optional += '<section class="section"><h2>历史基线差值</h2>'
        if comparison.get("deltas"):
            optional += '<div class="two">' + panel("平均 CPU 差值", ranked([(r["phase"], r["cpu_pp"]) for r in comparison["deltas"]], "百分点", digits=2))
            optional += panel("footprint 中位数差值", ranked([(r["phase"], r["footprint_mib"]) for r in comparison["deltas"]], "MiB", digits=2)) + '</div>'
        else:
            optional += table(["比较状态", "字段"], [["条件不匹配", ', '.join(comparison.get("differences", []))]])
        optional += '</section>'
    budgets = data.get("config", {})
    if budgets.get("cpu_mean_budget") is not None or budgets.get("footprint_budget") is not None:
        optional += '<section class="section"><h2>配置预算</h2>' + table(["平均 CPU 上限", "footprint 峰值上限", "超出项"], [[
            number(budgets.get("cpu_mean_budget"), 2, "%"), number(budgets.get("footprint_budget"), 1, " MiB"), ', '.join(data.get("budget_breaches", [])) or "0"]]) + '</section>'
    portable = json.loads(json.dumps(data))
    portable.get("target", {}).get("identity", {}).pop("path", None)
    for phase in portable.get("phases", []):
        phase.pop("commands", None)
    payload = json.dumps(portable, ensure_ascii=False, allow_nan=False).replace("&", "\\u0026").replace("<", "\\u003c").replace(">", "\\u003e")
    errors = data.get("errors", [])
    replacements = {"TITLE": escape(target.get("name", "App")) + " · 性能数据", "APP": escape(target.get("name", "App")),
                    "STATE": state, "STATE_TONE": tone, "STARTED": escape(data.get("started", "N/A")),
                    "ENDED": escape(data.get("ended", "采集中")), "PRESET": escape(data.get("config", {}).get("preset", "N/A")),
                    "VERSION": escape(f'{target.get("version", "N/A")} ({target.get("build", "N/A")})'),
                    "MINUTES": number(measured / 60, 1), "CPU": number(cpu_mean, 2),
                    "MEMORY": number(max(footprints) if footprints else None, 1), "HANGS": str(hangs) if hangs is not None else "N/A",
                    "HANG_PHASES": str(len(hang_phases)), "VALID": str(len(valid)), "PLANNED": str(len(data.get("plan", []))),
                    "ERRORS": '<div class="notice warn">' + '<br>'.join(escape(e) for e in errors) + '</div>' if errors else '',
                    "COMPARISONS": ''.join(comparisons), "IO_CHARTS": ''.join(io_charts), "PHASES": ''.join(phase_html),
                    "HOT_OVERVIEW": hot_overview, "HOTSPOTS": ''.join(hotspot_html),
                    "EVENTS": panel("Hangs / Hang risks", events_chart) + panel("热状态", thermal),
                    "EVENT_DETAILS": table(["阶段", "事件", "记录"], event_rows) if event_rows else '',
                    "RECORDS": table(["阶段", "模板", "记录时长", "样本数", "最大间隔", "CPU 计数覆盖", "状态"], record_rows),
                    "METADATA": table(["项目", "值"], metadata), "FINGERPRINT": table(["字段", "值"], fingerprint),
                    "LOAD": bars(load_groups, "", 2), "OPTIONAL": optional, "PAYLOAD": payload}
    template = Path(__file__).with_name("report.html").read_text()
    document = re.sub(r"@@([A-Z_]+)@@", lambda match: replacements[match[1]], template)
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".html.tmp")
    temporary.write_text(document)
    temporary.replace(destination)
