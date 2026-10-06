import json
from pathlib import Path
from typing import Literal, cast

from .models import Comparison, Report

def compare(data: Report, path: Path) -> Comparison:
    previous = cast(Report, json.loads(path.read_text()))
    keys: list[tuple[Literal["target", "environment", "config"], str]] = [
        ("target", "bundle_id"),
        ("environment", "os"),
        ("environment", "chip"),
        ("environment", "arch"),
        ("environment", "cores"),
        ("environment", "memory_bytes"),
        ("environment", "power_source"),
        ("environment", "instruments"),
        ("config", "workload"),
        ("config", "preset"),
        ("config", "cpu_mean_budget"),
        ("config", "footprint_budget"),
    ]
    differences = [
        f"{a}.{b}"
        for a, b in keys
        if data.get(a, {}).get(b) != previous.get(a, {}).get(b)
    ]
    if data.get("format_version") != previous.get("format_version"):
        differences.append("format_version")
    if previous.get("state") != "complete":
        differences.append("baseline.state")
    if data.get("state") != "complete":
        differences.append("current.state")
    if [(p["id"], p["seconds"]) for p in data["phases"]] != [
        (p["id"], p["seconds"]) for p in previous.get("phases", [])
    ]:
        differences.append("phase_plan")
    result: Comparison = {
        "baseline_version": previous.get("target", {}).get("version"),
        "compatible": not differences,
        "differences": differences,
        "deltas": [],
    }
    if not differences:
        for current, old in zip(data["phases"], previous["phases"]):
            a, b = current.get("resources"), old.get("resources")
            if a and b and not current.get("errors") and not old.get("errors"):
                current_cpu, old_cpu = a["cpu_mean"], b["cpu_mean"]
                current_memory, old_memory = a["footprint"], b["footprint"]
                if current_cpu is None or old_cpu is None or current_memory is None or old_memory is None:
                    raise ValueError("Complete phases must contain CPU and footprint measurements")
                result["deltas"].append(
                    {
                        "phase": current["id"],
                        "cpu_pp": current_cpu - old_cpu,
                        "footprint_mib": current_memory["median"] - old_memory["median"],
                    }
                )
    return result
