"""Decode xctrace XML using the schemas shipped with the recording Xcode"""

import collections
import math
import statistics
import xml.etree.ElementTree as ET


def percentile(values, fraction):
    if not values:
        return None
    values = sorted(values)
    position = (len(values) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    return values[lower] + (values[upper] - values[lower]) * (position - lower)


class Table:
    def __init__(self, path, columns):
        self.root = ET.parse(path).getroot()
        self.ids = {e.get("id"): e for e in self.root.iter() if e.get("id")}
        self.columns = columns

    def resolve(self, element):
        if element is None:
            return None
        return self.ids[element.get("ref")] if element.get("ref") else element

    def number(self, element):
        element = self.resolve(element)
        if element is None or element.tag == "sentinel":
            return None
        try:
            value = float(element.text)
            return value if math.isfinite(value) else None
        except (ValueError, TypeError):
            return None

    def label(self, element):
        element = self.resolve(element)
        return "" if element is None else element.get("fmt", element.text or "")

    def rows(self):
        for row in self.root.iter("row"):
            if len(row) != len(self.columns):
                raise ValueError(f"Schema mismatch: expected {len(self.columns)} columns, got {len(row)}")
            yield dict(zip(self.columns, row))


def resource_summary(table, pid):
    points = []
    for row in table.rows():
        if table.number(row.get("pid")) != pid:
            continue
        point = {key: table.number(value) for key, value in row.items()}
        if point.get("start") is not None:
            points.append(point)
    points.sort(key=lambda p: p["start"])
    if len(points) < 3:
        raise ValueError("Fewer than 3 target resource samples")
    series, errors = [], []
    previous = None
    for point in points:
        timestamp = point["start"] / 1e9
        item = {"t": timestamp, "cpu": None, "dt": None}
        for source, destination in [("memory-physical-footprint", "footprint"),
                                    ("memory-real", "rss"), ("memory-compressed", "compressed")]:
            value = point.get(source)
            item[destination] = value / 2 ** 20 if value is not None else None
        item["threads"] = point.get("thread-count")
        if previous is not None:
            dt = (point["start"] - previous["start"]) / 1e9
            current_cpu, last_cpu = point.get("cpu-total"), previous.get("cpu-total")
            if dt > 0 and current_cpu is not None and last_cpu is not None:
                delta = (current_cpu - last_cpu) / 1e9
                if delta < 0:
                    errors.append("CPU counter decreased; possible process reset or invalid data")
                else:
                    item.update(cpu=100 * delta / dt, dt=dt)
        series.append(item)
        previous = point
    span = series[-1]["t"] - series[0]["t"]
    if span <= 0:
        raise ValueError("Resource sample time did not advance")
    cpu_points = [p for p in series if p["cpu"] is not None]
    observed_seconds = sum(p["dt"] for p in cpu_points)
    cpu = [p["cpu"] for p in cpu_points]
    result = {"samples": len(series), "span_s": span, "series": series, "errors": errors,
              "max_gap_s": max(b["t"] - a["t"] for a, b in zip(series, series[1:])),
              "cpu_coverage": observed_seconds / span,
              "cpu_mean": sum(p["cpu"] * p["dt"] for p in cpu_points) / observed_seconds if observed_seconds else None,
              "cpu_p50": percentile(cpu, .5), "cpu_p95": percentile(cpu, .95),
              "cpu_peak": max(cpu) if cpu else None}
    for key in ["footprint", "rss", "compressed", "threads"]:
        values = [p[key] for p in series if p[key] is not None]
        result[key] = {"first": values[0], "last": values[-1], "min": min(values),
                       "max": max(values), "median": statistics.median(values)} if values else None
    for key, name in [("idle-wakeups", "wakeups"), ("disk-bytes-read", "read_bytes"),
                      ("disk-bytes-written", "written_bytes")]:
        first, last = points[0].get(key), points[-1].get(key)
        result[name] = last - first if first is not None and last is not None and last >= first else None
        result[name + "_per_s"] = result[name] / span if result[name] is not None else None
    footprint = [(p["t"], p["footprint"]) for p in series if p["footprint"] is not None]
    if len(footprint) >= 3:
        xs, ys = zip(*footprint)
        xmean, ymean = statistics.mean(xs), statistics.mean(ys)
        denominator = sum((x - xmean) ** 2 for x in xs)
        slope = sum((x - xmean) * (y - ymean) for x, y in footprint) / denominator if denominator else 0
        window = min(60, span / 4)
        head = [y for x, y in footprint if x <= xs[0] + window]
        tail = [y for x, y in footprint if x >= xs[-1] - window]
        result["memory_trend"] = {"slope_mib_min": slope * 60, "window_s": window,
                                  "head_median": statistics.median(head), "tail_median": statistics.median(tail),
                                  "delta_mib": statistics.median(tail) - statistics.median(head),
                                  "long_enough": span >= 240}
    return result


def profile_summary(table, pid):
    total = main = missing = app_weight = app_named = 0
    leaf, inclusive, binaries, seconds = (collections.Counter() for _ in range(4))
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
        app_frames = []
        for frame in frames:
            binary = table.resolve(frame.find("binary"))
            if binary is not None and ".app/Contents/MacOS/" in binary.get("path", ""):
                app_frames.append(frame.get("name", ""))
        if app_frames:
            app_weight += weight
            if any(n and not n.startswith("0x") and n != "<deduplicated_symbol>" for n in app_frames):
                app_named += weight
    return {"sampled_ms": total, "main_ms": main, "missing_stack_ms": missing,
            "app_stack_ms": app_weight, "app_named_stack_ms": app_named,
            "leaf": leaf.most_common(18), "inclusive": inclusive.most_common(35),
            "binaries": binaries.most_common(15), "busiest_seconds": seconds.most_common(8)}


def event_summary(table, pid=None):
    rows = []
    for row in table.rows():
        if pid is not None and "process" in row:
            process = table.resolve(row["process"])
            if process is None or table.number(process.find("pid")) != pid:
                continue
        rows.append({key: table.label(value) for key, value in row.items()
                     if key not in ("backtrace", "process", "thread")})
    return {"count": len(rows), "events": rows[:100]}


def system_summary(table):
    values = []
    for row in table.rows():
        value = table.number(row.get("cpu-total-load"))
        if value is not None:
            values.append(value)
    return {"samples": len(values), "cpu_load_mean": statistics.mean(values) if values else None,
            "cpu_load_peak": max(values) if values else None}
