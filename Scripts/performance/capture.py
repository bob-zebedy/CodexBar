"""Non-invasive profiling of an already running macOS app, using xctrace"""

import ctypes
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import signal
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path


from .analyze import (
    Table,
    event_summary,
    profile_summary,
    resource_summary,
    system_summary,
)
from .report import write_report
from .models import (CommandResult, Phase, ProcessIdentity, Report, SchemaKey, Schemas, Target)

SCHEMAS: tuple[SchemaKey, ...] = (
    "activity-monitor-process-live",
    "time-profile",
    "potential-hangs",
    "hang-risks",
    "device-thermal-state-intervals",
    "activity-monitor-system",
)


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
