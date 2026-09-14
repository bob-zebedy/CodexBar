"""Decode xctrace XML using the schemas shipped with the recording Xcode"""

import collections
import math
import statistics
import xml.etree.ElementTree as ET
from collections.abc import Iterator, Sequence
from pathlib import Path
from typing import IO, Literal, overload

from .models import Events, MetricKey, Profile, Resources, Sample, SystemSummary


def percentile(values: Sequence[float], fraction: float) -> float | None:
    if not values:
        return None
    values = sorted(values)
    position = (len(values) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    return values[lower] + (values[upper] - values[lower]) * (position - lower)


class Table:
    def __init__(self, path: Path | IO[str], columns: Sequence[str]) -> None:
        self.root = ET.parse(path).getroot()
        self.ids = {key: e for e in self.root.iter() if (key := e.get("id"))}
        self.columns = columns

    @overload
    def resolve(self, element: ET.Element) -> ET.Element:
        ...

    @overload
    def resolve(self, element: None) -> None:
        ...

    def resolve(self, element: ET.Element | None) -> ET.Element | None:
        if element is None:
            return None
        reference = element.get("ref")
        return self.ids[reference] if reference else element

    def number(self, element: ET.Element | None) -> float | None:
        element = self.resolve(element)
        if element is None or element.tag == "sentinel":
            return None
        text = element.text
        if text is None:
            return None
        try:
            value = float(text)
            return value if math.isfinite(value) else None
        except (ValueError, TypeError):
            return None

    def label(self, element: ET.Element | None) -> str:
        element = self.resolve(element)
        return "" if element is None else element.get("fmt", element.text or "")

    def rows(self) -> Iterator[dict[str, ET.Element]]:
        for row in self.root.iter("row"):
            if len(row) != len(self.columns):
                raise ValueError(f"Schema mismatch: expected {len(self.columns)} columns, got {len(row)}")
            yield dict(zip(self.columns, row))


def resource_summary(table: Table, pid: int) -> Resources:
    points: list[tuple[float, dict[str, float | None]]] = []
    for row in table.rows():
        if table.number(row.get("pid")) != pid:
            continue
        point = {key: table.number(value) for key, value in row.items()}
        start = point.get("start")
        if start is not None:
            points.append((start, point))
    points.sort(key=lambda p: p[0])
    if len(points) < 3:
        raise ValueError("Fewer than 3 target resource samples")
    series: list[Sample] = []
    errors: list[str] = []
    interval_end = points[0][0]
    memory_fields: list[tuple[str, MetricKey]] = [
        ("memory-physical-footprint", "footprint"),
        ("memory-real", "rss"), ("memory-compressed", "compressed"),
    ]
    for start, point in points:
        timestamp = start / 1e9
        item: Sample = {"t": timestamp, "cpu": None, "dt": None,
                        "footprint": None, "rss": None, "compressed": None, "threads": None}
        for source, destination in memory_fields:
            value = point.get(source)
            item[destination] = value / 2 ** 20 if value is not None else None
        item["threads"] = point.get("thread-count")
        duration, cpu = point.get("duration"), point.get("cpu-percent")
        if duration is None or duration <= 0:
            errors.append("Resource sample duration is missing or nonpositive")
        elif start < interval_end:
            errors.append("Resource sample intervals overlap")
        else:
            interval_end = start + duration
            # Instruments pairs each CPU percentage with the duration in the same row
            if cpu is not None:
                if cpu < 0:
                    errors.append("CPU percentage is negative")
                else:
                    item["cpu"] = cpu
                    item["dt"] = duration / 1e9
        series.append(item)
    span = series[-1]["t"] - series[0]["t"]
    if span <= 0:
        raise ValueError("Resource sample time did not advance")
    cpu_points = [(p["cpu"], p["dt"]) for p in series if p["cpu"] is not None and p["dt"] is not None]
    observed_seconds = sum(duration for _, duration in cpu_points)
    cpu_span = (max(interval_end, points[-1][0]) - points[0][0]) / 1e9
    cpu_values = [value for value, _ in cpu_points]
    result: Resources = {
        "samples": len(series),
        "span_s": span,
        "series": series,
        "errors": errors,
        "max_gap_s": max(b["t"] - a["t"] for a, b in zip(series, series[1:])),
        "cpu_coverage": observed_seconds / cpu_span,
        "cpu_mean": sum(value * duration for value, duration in cpu_points) / observed_seconds if observed_seconds else None,
        "cpu_p50": percentile(cpu_values, .5),
        "cpu_p95": percentile(cpu_values, .95),
        "cpu_peak": max(cpu_values) if cpu_values else None,
        "footprint": None,
        "rss": None,
        "compressed": None,
        "threads": None,
        "wakeups": None,
        "wakeups_per_s": None,
        "read_bytes": None,
        "read_bytes_per_s": None,
        "written_bytes": None,
        "written_bytes_per_s": None
    }
    metric_keys: tuple[MetricKey, ...] = ("footprint", "rss", "compressed", "threads")
    for key in metric_keys:
        values = [value for p in series if (value := p[key]) is not None]
        result[key] = {
            "first": values[0],
            "last": values[-1],
            "min": min(values),
            "max": max(values),
            "median": statistics.median(values)
        } if values else None
    counters: tuple[tuple[str, Literal["wakeups", "read_bytes", "written_bytes"],
    Literal["wakeups_per_s", "read_bytes_per_s", "written_bytes_per_s"]], ...] = (
        ("idle-wakeups", "wakeups", "wakeups_per_s"),
        ("disk-bytes-read", "read_bytes", "read_bytes_per_s"),
        ("disk-bytes-written", "written_bytes", "written_bytes_per_s"),
    )
    for source_key, name, rate_name in counters:
        first, last = points[0][1].get(source_key), points[-1][1].get(source_key)
        difference = last - first if first is not None and last is not None and last >= first else None
        result[name] = difference
        result[rate_name] = difference / span if difference is not None else None
    footprint = [(p["t"], value) for p in series if (value := p["footprint"]) is not None]
    if len(footprint) >= 3:
        xs, ys = zip(*footprint)
        xmean, ymean = statistics.mean(xs), statistics.mean(ys)
        denominator = sum((x - xmean) ** 2 for x in xs)
        slope = sum((x - xmean) * (y - ymean) for x, y in footprint) / denominator if denominator else 0
        window = min(60, span / 4)
        head = [y for x, y in footprint if x <= xs[0] + window]
        tail = [y for x, y in footprint if x >= xs[-1] - window]
        result["memory_trend"] = {
            "slope_mib_min": slope * 60,
            "window_s": window,
            "head_median": statistics.median(head),
            "tail_median": statistics.median(tail),
            "delta_mib": statistics.median(tail) - statistics.median(head),
            "long_enough": span >= 240
        }
    return result


def profile_summary(table: Table, pid: int) -> Profile:
    total: float = 0
    main: float = 0
    missing: float = 0
    app_weight: float = 0
    app_named: float = 0
    leaf: collections.defaultdict[str, float] = collections.defaultdict(float)
    inclusive: collections.defaultdict[str, float] = collections.defaultdict(float)
    binaries: collections.defaultdict[str, float] = collections.defaultdict(float)
    seconds: collections.defaultdict[int, float] = collections.defaultdict(float)
    for row in table.rows():
        process = table.resolve(row.get("process"))
        process_pid = table.number(process.find("pid")) if process is not None else None
        if process_pid != pid:
            continue
        weight = table.number(row.get("weight"))
        if weight is None:
            continue
        weight /= 1e6
        total += weight
        thread = table.label(row.get("thread"))
        if "Main Thread" in thread:
            main += weight
        timestamp = table.number(row.get("time"))
        if timestamp is not None:
            seconds[int(timestamp / 1e9)] += weight
        stack = table.resolve(row.get("stack"))
        backtrace = table.resolve(stack.find("backtrace")) if stack is not None else None
        if backtrace is None:
            missing += weight
            continue
        frames = [table.resolve(f) for f in backtrace]
        if not frames:
            missing += weight
            continue
        names = {f.get("name", "Unknown") for f in frames}
        first = frames[0]
        leaf[first.get("name", "Unknown")] += weight
        for name in names:
            inclusive[name] += weight
        binary = table.resolve(first.find("binary"))
        binaries[binary.get("name", "Unknown") if binary is not None else "Unknown"] += weight
        app_frames: list[str] = []
        for frame in frames:
            binary = table.resolve(frame.find("binary"))
            if binary is not None and ".app/Contents/MacOS/" in binary.get("path", ""):
                app_frames.append(frame.get("name", ""))
        if app_frames:
            app_weight += weight
            if any(n and not n.startswith("0x") and n != "<deduplicated_symbol>" for n in app_frames):
                app_named += weight
    return {
        "sampled_ms": total,
        "main_ms": main,
        "missing_stack_ms": missing,
        "app_stack_ms": app_weight,
        "app_named_stack_ms": app_named,
        "leaf": sorted(leaf.items(), key=lambda item: item[1], reverse=True)[:18],
        "inclusive": sorted(inclusive.items(), key=lambda item: item[1], reverse=True)[:35],
        "binaries": sorted(binaries.items(), key=lambda item: item[1], reverse=True)[:15],
        "busiest_seconds": sorted(seconds.items(), key=lambda item: item[1], reverse=True)[:8]
    }


def event_summary(table: Table, pid: int | None = None) -> Events:
    rows: list[dict[str, str]] = []
    for row in table.rows():
        if pid is not None and "process" in row:
            process = table.resolve(row["process"])
            if table.number(process.find("pid")) != pid:
                continue
        rows.append({key: table.label(value) for key, value in row.items()
                     if key not in ("backtrace", "process", "thread")})
    return {"count": len(rows), "events": rows[:100]}


def system_summary(table: Table) -> SystemSummary:
    values: list[float] = []
    for row in table.rows():
        value = table.number(row.get("cpu-total-load"))
        if value is not None:
            values.append(value)
    return {"samples": len(values), "cpu_load_mean": statistics.mean(values) if values else None,
            "cpu_load_peak": max(values) if values else None}
