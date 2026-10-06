"""Non-invasive profiling of an already running macOS app, using xctrace"""

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import signal
import sys
import tempfile
import time
from pathlib import Path
from types import FrameType
from typing import cast

sys.dont_write_bytecode = True

from .capture import capture, inspect_target, load_schemas, now, optional, record_phase, save, status
from .compare import compare
from .report import write_report
from .models import Phase, PhasePlan, Report

VERSION = "1"
ROOT = Path(__file__).resolve().parents[2]
PRESETS = {
    "quick": (5, 30, 2, 90, 30),
    "standard": (20, 60, 4, 300, 60),
    "extended": (30, 120, 5, 900, 300),
}


class Arguments(argparse.Namespace):
    app: Path
    pid: int | None
    preset: str
    output: Path | None
    workload: str
    baseline: Path | None
    cpu_mean_budget: float | None
    footprint_budget: float | None
    render: Path | None


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="python3 -m Scripts.performance", description=__doc__
    )
    parser.add_argument("--app", type=Path, default=Path("/Applications/CodexBar.app"))
    parser.add_argument("--pid", type=int)
    parser.add_argument("--preset", choices=PRESETS, default="standard")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--workload", default="Natural workload; UI and active tasks uncontrolled")
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--cpu-mean-budget", type=float)
    parser.add_argument("--footprint-budget", type=float, help="Physical footprint budget in MiB")
    parser.add_argument("--render", type=Path, help="Regenerate HTML from an existing performance.json without profiling")
    args = parser.parse_args(namespace=Arguments())
    if args.render:
        render_data = cast(Report, json.loads(args.render.read_text()))
        destination = args.output or args.render.parent / "performance.html"
        write_report(render_data, destination)
        print(destination)
        return 0
    for value in (args.cpu_mean_budget, args.footprint_budget):
        if value is not None and (not 0 < value < float("inf")):
            parser.error("Budgets must be finite positive numbers")
    timestamp = dt.datetime.now().strftime("%Y%m%d/%H%M%S")
    output = (
            args.output or ROOT / "Performance" / f"{timestamp}-{args.preset}"
    ).resolve()
    try:
        output.mkdir(parents=True, exist_ok=False)
    except OSError as error:
        parser.error(f"Cannot create a new output directory: {error}")
    os.chmod(output, 0o700)
    data: Report = {
        "format_version": VERSION,
        "started": now(),
        "state": "running",
        "errors": [],
        "config": {
            "preset": args.preset,
            "workload": args.workload,
            "cpu_mean_budget": args.cpu_mean_budget,
            "footprint_budget": args.footprint_budget,
        },
        "phases": [],
        "environment": {"os": platform.mac_ver()[0], "arch": platform.machine()},
        "target": {"name": args.app.stem},
    }
    exit_code = 0

    def stop(_signum: int, _frame: FrameType | None) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    try:
        if platform.system() != "Darwin":
            raise RuntimeError("Recording requires macOS and full Xcode")
        data["tool_sha256"] = {}
        source_directory = output / "tool-source"
        source_directory.mkdir()
        for name in (
                "__init__.py",
                "__main__.py",
                "analyze.py",
                "models.py",
                "capture.py",
                "compare.py",
                "report.py",
                "performance.html",
        ):
            source = Path(__file__).with_name(name).read_bytes()
            (source_directory / name).write_bytes(source)
            data["tool_sha256"][name] = hashlib.sha256(source).hexdigest()
        status("Preflight: target, Xcode, templates, schemas")
        target = inspect_target(args.app.resolve(), args.pid)
        data["target"] = target
        target_identity = target.get("identity")
        if target_identity is None:
            raise RuntimeError("Target process identity is unavailable")
        env = data["environment"]
        env["instruments"] = capture(["/usr/bin/xcrun", "xctrace", "version"])
        env["chip"] = optional(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"])
        env["cores"] = optional(["/usr/sbin/sysctl", "-n", "hw.logicalcpu"])
        env["memory_bytes"] = optional(["/usr/sbin/sysctl", "-n", "hw.memsize"])
        env["power"] = optional(["/usr/bin/pmset", "-g", "batt"])
        env["power_source"] = (env["power"] or "Unknown").splitlines()[0]
        env["load_before"] = list(os.getloadavg())
        templates = capture(["/usr/bin/xcrun", "xctrace", "list", "templates"], timeout=60)
        for template in ("Time Profiler", "Activity Monitor"):
            if template not in templates.splitlines():
                raise RuntimeError(f"Missing Instruments template: {template}")
        schemas = load_schemas(capture(["/usr/bin/xcode-select", "-p"]))
        (output / "schemas.json").write_text(json.dumps(schemas, indent=2))
        warmup, sample, repeats, soak, settle = PRESETS[args.preset]
        data["config"]["warmup_s"] = warmup
        plan: list[PhasePlan] = [
            {
                "id": f"cpu-{i + 1}",
                "label": f"CPU repeat {i + 1}",
                "seconds": sample,
                "template": "Time Profiler",
            }
            for i in range(repeats)
        ]
        plan.extend([
            {
                "id": "soak",
                "label": "Resource observation",
                "seconds": soak,
                "template": "Activity Monitor",
            },
            {
                "id": "settle",
                "label": "Follow-up observation",
                "seconds": settle,
                "template": "Activity Monitor",
            },
        ])
        data["plan"] = plan
        save(data, output)
        status(
            f"Warm-up {warmup}s; target PID {target_identity['pid']}; output {output}"
        )
        time.sleep(warmup)
        for planned in plan:
            phase: Phase = {"id": planned["id"], "label": planned["label"],
                            "seconds": planned["seconds"], "template": planned["template"]}
            data["phases"].append(phase)
            status(
                f"Recording {phase['id']} ({phase['template']}, {phase['seconds']}s)"
            )
            record_phase(phase, data, output, schemas)
            status(
                f"Finished {phase['id']}: {'incomplete' if phase.get('errors') else 'valid'}"
            )
            save(data, output)
        data["state"] = (
            "complete"
            if all(not p.get("errors") for p in data["phases"])
            else "incomplete"
        )
        data["environment"]["load_after"] = list(os.getloadavg())
        if args.baseline:
            data["comparison"] = compare(data, args.baseline)
        breached: list[str] = []
        for phase in data["phases"]:
            resource = phase.get("resources", {})
            if phase.get("errors"):
                continue
            if args.cpu_mean_budget is not None:
                cpu_mean = resource.get("cpu_mean", 0)
                if cpu_mean is None:
                    raise ValueError("CPU budget requires a valid mean measurement")
                if cpu_mean > args.cpu_mean_budget:
                    breached.append(phase["id"] + ": cpu_mean")
            footprint = resource.get("footprint")
            footprint_peak = footprint["max"] if footprint is not None else 0
            if args.footprint_budget is not None and footprint_peak > args.footprint_budget:
                breached.append(phase["id"] + ": footprint_peak")
        data["budget_breaches"] = breached
        exit_code = 2 if data["state"] != "complete" else 3 if breached else 0
    except KeyboardInterrupt:
        data["state"] = "interrupted"
        data["errors"].append("Interrupted by operator; partial results retained")
        exit_code = 130
    except Exception as error:
        data["state"] = "incomplete"
        data["errors"].append(f"{type(error).__name__}: {error}")
        exit_code = 2
    finally:
        data["ended"] = now()
        data["exit_code"] = exit_code
        report_output: Path | None = output
        try:
            save(data, output)
        except Exception as error:
            data["errors"].append(
                f"Saving results failed: {type(error).__name__}: {error}"
            )
            data["state"] = "incomplete"
            exit_code = data["exit_code"] = 2
            for message in data["errors"]:
                status(message)
            try:
                report_output = Path(tempfile.mkdtemp(prefix="codexbar-performance-recovery-"))
                save(data, report_output)
            except Exception as recovery_error:
                status(
                    f"Recovery save failed: {type(recovery_error).__name__}: {recovery_error}"
                )
                report_output = None
        if report_output is not None:
            status(f"Report: {report_output / 'performance.html'}; exit {exit_code}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
