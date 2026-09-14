"""Non-invasive profiling of an already running macOS app, using xctrace"""

import argparse
import ctypes
import datetime as dt
import hashlib
import json
import os
import platform
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from types import FrameType
from typing import Literal, cast

sys.dont_write_bytecode = True

from .analyze import (
    Table,
    event_summary,
    profile_summary,
    resource_summary,
    system_summary,
)
from .performance import write_report
from .models import (
    CommandResult, Comparison, Phase, PhasePlan, ProcessIdentity, Report, SchemaKey, Schemas, Target,
)

VERSION = "1"
ROOT = Path(__file__).resolve().parents[2]
SCHEMAS: tuple[SchemaKey, ...] = (
    "activity-monitor-process-live",
    "time-profile",
    "potential-hangs",
    "hang-risks",
    "device-thermal-state-intervals",
    "activity-monitor-system",
)
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


def now() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def status(message: str) -> None:
    print(f"[{now()}] {message}", flush=True)


def capture(args: list[str], timeout: float = 20) -> str:
    result = subprocess.run(args, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(
            f"{args[0]} exited {result.returncode}: {result.stderr.decode(errors='replace')[-1000:]}"
        )
    return result.stdout.decode(errors="replace").strip()


def optional(args: list[str]) -> str | None:
    try:
        return capture(args)
    except (OSError, RuntimeError, subprocess.TimeoutExpired):
        return None


def process_path(pid: int) -> Path | None:
    lib = ctypes.CDLL("/usr/lib/libproc.dylib")
    lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    lib.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    size = lib.proc_pidpath(pid, buffer, len(buffer))
    return Path(os.fsdecode(buffer.value)).resolve() if size > 0 else None


def identity(pid: int) -> ProcessIdentity:
    path = process_path(pid)
    started = optional(["/bin/ps", "-p", str(pid), "-o", "lstart="])
    return {"pid": pid, "path": str(path) if path else None, "started": started}


def inspect_target(app: Path, pid: int | None) -> Target:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    executable = (app / "Contents/MacOS" / info["CFBundleExecutable"]).resolve()
    if not executable.is_file():
        raise ValueError("App executable does not exist")
    if pid is None:
        candidates = [int(p) for p in capture(["/bin/ps", "-A", "-o", "pid="]).split()]
        matches = [p for p in candidates if process_path(p) == executable]
        if len(matches) != 1:
            raise ValueError(
                f"Expected one running instance of {app.name}, found {len(matches)}; specify --pid"
            )
        pid = matches[0]
    original = identity(pid)
    if original["path"] != str(executable) or not original["started"]:
        raise ValueError("PID does not match the requested app executable")
    entitlements = subprocess.run(
        ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)],
        capture_output=True,
        timeout=20,
    )
    ent = None
    for stream in (entitlements.stdout, entitlements.stderr):
        start = stream.find(b"<?xml")
        end = stream.find(b"</plist>")
        if 0 <= start <= end:
            ent = plistlib.loads(stream[start: end + len(b"</plist>")])
            break
    uuids = optional(["/usr/bin/xcrun", "dwarfdump", "--uuid", str(executable)])
    uuid_list = re.findall(r"UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)", uuids or "")
    with executable.open("rb") as file:
        binary_hash = hashlib.file_digest(file, "sha256").hexdigest()
    return {
        "name": app.stem,
        "bundle_id": info.get("CFBundleIdentifier"),
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "binary_sha256": binary_hash,
        "uuids": uuid_list,
        "get_task_allow": bool(ent.get("com.apple.security.get-task-allow"))
        if ent is not None
        else None,
        "identity": original,
    }


def load_schemas(developer: str) -> Schemas:
    base = Path(developer).parent / "Applications/Instruments.app/Contents/Packages"
    found: Schemas = {}
    for path in base.rglob("schemas.xml"):
        for schema in ET.parse(path).getroot().findall("schema"):
            name = schema.get("name")
            for known_name in SCHEMAS:
                if name != known_name:
                    continue
                columns = [c.get("mnemonic") for c in schema.findall("column")]
                if any(column is None for column in columns):
                    raise ValueError(f"Missing column mnemonic in schema: {name}")
                found[known_name] = [column for column in columns if column is not None]
    if "activity-monitor-process-live" not in found:
        raise RuntimeError(
            "No Activity Monitor column schema found in the selected Xcode"
        )
    return found


def run_command(
        args: list[str], logfile: Path, timeout: float, expected: ProcessIdentity | None = None,
) -> CommandResult:
    began = time.monotonic()
    interrupted = False
    failure = None
    directory = logfile.parent.stat()

    def check_output() -> None:
        try:
            current = logfile.parent.stat()
            if (current.st_dev, current.st_ino) == (directory.st_dev, directory.st_ino):
                return
        except FileNotFoundError:
            pass
        raise RuntimeError(
            f"Output directory removed or replaced during capture: {logfile.parent}"
        )

    with logfile.open("w") as log:
        process = subprocess.Popen(
            args, stdout=log, stderr=subprocess.STDOUT, start_new_session=True
        )
        try:
            while process.poll() is None:
                check_output()
                elapsed = time.monotonic() - began
                if elapsed >= timeout:
                    failure = "Command timeout"
                    break
                if expected and identity(expected["pid"]) != expected:
                    failure = "Target exited or process identity changed"
                    break
                time.sleep(1)
        except KeyboardInterrupt:
            interrupted = True
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGINT)
                try:
                    process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
    check_output()
    result: CommandResult = {
        "argv": args,
        "exit_code": process.returncode,
        "elapsed_s": round(time.monotonic() - began, 2),
        "log": logfile.name,
    }
    if failure:
        result["error"] = failure
    if interrupted:
        raise KeyboardInterrupt
    return result


def save(data: Report, output: Path) -> None:
    temporary = output / "performance.json.tmp"
    temporary.write_text(
        json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
    )
    temporary.replace(output / "performance.json")
    write_report(data, output / "performance.html")


def analyze_phase(phase: Phase, output: Path, schemas: Schemas, pid: int) -> None:
    for name, columns in schemas.items():
        file = output / f"{phase['id']}-{name}.xml"
        if not file.exists() or name not in phase.get("exported", []):
            continue
        try:
            table = Table(file, columns)
            if name == "activity-monitor-process-live":
                phase["resources"] = resource_summary(table, pid)
            elif name == "time-profile":
                phase["profile"] = profile_summary(table, pid)
            elif name == "activity-monitor-system":
                phase["system"] = system_summary(table)
            else:
                phase[name] = event_summary(
                    table, pid if name in ("potential-hangs", "hang-risks") else None
                )
        except (ValueError, KeyError, ET.ParseError, TypeError) as error:
            phase.setdefault("errors", []).append(f"{name}: {error}")


def record_phase(phase: Phase, data: Report, output: Path, schemas: Schemas) -> None:
    target = data["target"].get("identity")
    if target is None:
        raise RuntimeError("Target process identity is unavailable")
    if identity(target["pid"]) != target:
        raise RuntimeError("Target process changed before recording")
    phase["started"] = now()
    errors: list[str] = []
    commands: list[CommandResult] = []
    exported: list[SchemaKey] = []
    phase["errors"] = errors
    phase["commands"] = commands
    phase["exported"] = exported
    phase["trace"] = phase["id"] + ".trace"
    args = [
        "/usr/bin/xcrun",
        "xctrace",
        "record",
        "--template",
        phase["template"],
        "--attach",
        str(target["pid"]),
        "--time-limit",
        f"{phase['seconds']}s",
        "--output",
        str(output / phase["trace"]),
        "--no-prompt",
    ]
    if phase["template"] == "Time Profiler":
        args.extend(["--instrument", "Activity Monitor"])
    command = run_command(
        args, output / f"{phase['id']}-record.log", phase["seconds"] + 150, target
    )
    commands.append(command)
    if command["exit_code"] or command.get("error"):
        errors.append(
            command.get("error", "xctrace recording failed; see record log")
        )
    elif "[Error]" in (output / command["log"]).read_text(errors="replace"):
        errors.append("xctrace reported an error despite a zero exit code")
    if identity(target["pid"]) != target:
        errors.append("Target identity changed during recording")
    trace = output / phase["trace"]
    if not trace.exists():
        errors.append("No trace artifact was created")
        return
    toc = output / f"{phase['id']}-toc.xml"
    cmd = run_command(
        [
            "/usr/bin/xcrun",
            "xctrace",
            "export",
            "--input",
            str(trace),
            "--toc",
            "--output",
            str(toc),
        ],
        output / f"{phase['id']}-toc.log",
        120,
    )
    commands.append(cmd)
    if cmd["exit_code"] or cmd.get("error"):
        errors.append("TOC export failed")
        return
    root = ET.parse(toc).getroot()
    duration = root.findtext(".//summary/duration", "0")
    phase["recorded_s"] = float(duration)
    phase["trace_started"] = root.findtext(".//summary/start-date")
    phase["hang_settings"] = [
        e.text for e in root.findall(".//instrument[@name='Hangs']//key")
    ]
    phase["tables"] = [e.get("schema") for e in root.findall(".//data/table")]
    if phase["recorded_s"] < phase["seconds"] * 0.9:
        errors.append("Recording duration below 90% of requested duration")
    for name in SCHEMAS:
        if name not in phase["tables"] or name not in schemas:
            continue
        xml = output / f"{phase['id']}-{name}.xml"
        cmd = run_command(
            [
                "/usr/bin/xcrun",
                "xctrace",
                "export",
                "--input",
                str(trace),
                "--xpath",
                f'/trace-toc/run[@number="1"]/data/table[@schema="{name}"]',
                "--output",
                str(xml),
            ],
            output / f"{phase['id']}-{name}.log",
            120,
        )
        commands.append(cmd)
        if cmd["exit_code"] or cmd.get("error"):
            errors.append(f"{name}: export failed")
        else:
            exported.append(name)
    analyze_phase(phase, output, schemas, target["pid"])
    if "resources" not in phase:
        errors.append("No valid resource measurements")
    else:
        resource = phase["resources"]
        errors.extend(resource["errors"])
        if resource["span_s"] < phase["seconds"] * 0.8:
            errors.append("Resource coverage below 80% of requested duration")
        if resource["max_gap_s"] > 5:
            errors.append("Resource sample gap exceeds 5 seconds")
        if resource["cpu_coverage"] < 0.95:
            errors.append("CPU sample coverage below 95%")
        if resource.get("footprint") is None:
            errors.append("Physical footprint was not available")
    if phase["template"] == "Time Profiler" and "profile" not in phase:
        errors.append("No decoded CPU profile")
    phase["ended"] = now()


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
                "performance.py",
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
