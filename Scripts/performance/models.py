"""Types for the existing capture and report dictionaries"""

from typing import Literal, NotRequired, TypedDict

MetricKey = Literal["footprint", "rss", "compressed", "threads"]
SeriesKey = Literal["cpu", "footprint", "rss", "compressed", "threads"]
StatisticKey = Literal["first", "last", "min", "max", "median"]
ResourceValueKey = Literal[
    "cpu_mean", "cpu_p50", "cpu_p95", "cpu_peak", "wakeups", "wakeups_per_s",
    "read_bytes", "read_bytes_per_s", "written_bytes", "written_bytes_per_s",
]
EventKey = Literal["potential-hangs", "hang-risks", "device-thermal-state-intervals"]
SchemaKey = Literal[
    "activity-monitor-process-live", "time-profile", "potential-hangs", "hang-risks",
    "device-thermal-state-intervals", "activity-monitor-system",
]
Schemas = dict[SchemaKey, list[str]]


class Sample(TypedDict):
    t: float
    cpu: float | None
    dt: float | None
    footprint: float | None
    rss: float | None
    compressed: float | None
    threads: float | None


class Statistics(TypedDict):
    first: float
    last: float
    min: float
    max: float
    median: float


class MemoryTrend(TypedDict):
    slope_mib_min: float
    window_s: float
    head_median: float
    tail_median: float
    delta_mib: float
    long_enough: bool


class Resources(TypedDict):
    samples: int
    span_s: float
    series: list[Sample]
    errors: list[str]
    max_gap_s: float
    cpu_coverage: float
    cpu_mean: float | None
    cpu_p50: float | None
    cpu_p95: float | None
    cpu_peak: float | None
    footprint: Statistics | None
    rss: Statistics | None
    compressed: Statistics | None
    threads: Statistics | None
    wakeups: float | None
    wakeups_per_s: float | None
    read_bytes: float | None
    read_bytes_per_s: float | None
    written_bytes: float | None
    written_bytes_per_s: float | None
    memory_trend: NotRequired[MemoryTrend]


class Profile(TypedDict):
    sampled_ms: float
    main_ms: float
    missing_stack_ms: float
    app_stack_ms: float
    app_named_stack_ms: float
    leaf: list[tuple[str, float]]
    inclusive: list[tuple[str, float]]
    binaries: list[tuple[str, float]]
    busiest_seconds: list[tuple[int, float]]


class Events(TypedDict):
    count: int
    events: list[dict[str, str]]


class SystemSummary(TypedDict):
    samples: int
    cpu_load_mean: float | None
    cpu_load_peak: float | None


class ProcessIdentity(TypedDict):
    pid: int
    path: str | None
    started: str | None


class Target(TypedDict):
    name: str
    bundle_id: NotRequired[str | None]
    version: NotRequired[str | None]
    build: NotRequired[str | None]
    binary_sha256: NotRequired[str]
    uuids: NotRequired[list[tuple[str, str]]]
    get_task_allow: NotRequired[bool | None]
    identity: NotRequired[ProcessIdentity]


class CommandResult(TypedDict):
    argv: list[str]
    exit_code: int | None
    elapsed_s: float
    log: str
    error: NotRequired[str]


class PhasePlan(TypedDict):
    id: str
    label: str
    seconds: int
    template: str


PhaseEvents = TypedDict("PhaseEvents", {
    "potential-hangs": Events,
    "hang-risks": Events,
    "device-thermal-state-intervals": Events,
}, total=False)


class Phase(PhasePlan, PhaseEvents):
    started: NotRequired[str]
    ended: NotRequired[str]
    errors: NotRequired[list[str]]
    commands: NotRequired[list[CommandResult]]
    exported: NotRequired[list[SchemaKey]]
    trace: NotRequired[str]
    recorded_s: NotRequired[float]
    trace_started: NotRequired[str | None]
    hang_settings: NotRequired[list[str | None]]
    tables: NotRequired[list[str | None]]
    resources: NotRequired[Resources]
    profile: NotRequired[Profile]
    system: NotRequired[SystemSummary]


class Config(TypedDict):
    preset: str
    workload: str
    cpu_mean_budget: float | None
    footprint_budget: float | None
    warmup_s: NotRequired[int]


class Environment(TypedDict):
    os: str
    arch: str
    instruments: NotRequired[str]
    chip: NotRequired[str | None]
    cores: NotRequired[str | None]
    memory_bytes: NotRequired[str | None]
    power: NotRequired[str | None]
    power_source: NotRequired[str]
    load_before: NotRequired[list[float]]
    load_after: NotRequired[list[float]]


class Delta(TypedDict):
    phase: str
    cpu_pp: float
    footprint_mib: float


class Comparison(TypedDict):
    baseline_version: str | None
    compatible: bool
    differences: list[str]
    deltas: list[Delta]


class Report(TypedDict):
    format_version: str
    started: str
    state: str
    errors: list[str]
    config: Config
    phases: list[Phase]
    environment: Environment
    target: Target
    ended: NotRequired[str]
    exit_code: NotRequired[int]
    tool_sha256: NotRequired[dict[str, str]]
    plan: NotRequired[list[PhasePlan]]
    comparison: NotRequired[Comparison]
    budget_breaches: NotRequired[list[str]]
