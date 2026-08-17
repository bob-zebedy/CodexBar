# CodexBar Documentation

[简体中文](../README.md) | English

CodexBar documentation is split into two sets by audience and responsibility, keeping product instructions separate from implementation details:

| Document | Audience | What it covers |
| --- | --- | --- |
| [User Guide](UserGuide/README.md) | CodexBar users | Installing and using features, understanding settings, and resolving common issues |
| [Developer Guide](DeveloperGuide/README.md) | Contributors and code readers | How the app works, how data flows, and how to validate core constraints |

## Recommended Reading Paths

### Using CodexBar for the first time

1. Read [Installation and Quick Start](UserGuide/getting-started.md)
2. Learn about the [Main Panel and Menu Bar](UserGuide/main-panel.md)
3. Enable [Live Tasks and CodexBar Hook](UserGuide/activity-and-hook.md) if needed
4. Review automatic reset, sleep prevention, and other options in the [Settings Reference](UserGuide/settings.md)

### Troubleshooting

1. Start with [Troubleshooting](UserGuide/troubleshooting.md)
2. Check app-server request status in the app's Logs window
3. For local files or network boundaries, see [Data, Sync, and Privacy](UserGuide/sync-data-privacy.md)

### Reading or modifying the code

1. Start with [Architecture](DeveloperGuide/architecture.md) for a system-wide view
2. Continue to the data-flow or service guide relevant to your change
3. See [Development and Validation](DeveloperGuide/development.md) for build, debugging, and verification workflows
4. See [Data and Privacy Boundaries](DeveloperGuide/data-and-privacy.md) for local and cloud data scopes

## Directory Structure

```text
Docs/en
├── UserGuide
│   ├── README.md
│   ├── getting-started.md
│   ├── main-panel.md
│   ├── activity-and-hook.md
│   ├── notifications.md
│   ├── sleep-prevention.md
│   ├── sync-data-privacy.md
│   ├── settings.md
│   └── troubleshooting.md
└── DeveloperGuide
    ├── README.md
    ├── architecture.md
    ├── design-decisions.md
    ├── app-server.md
    ├── hook-and-aggregation.md
    ├── activity-monitor.md
    ├── sleep-prevention.md
    ├── sync.md
    ├── notifications.md
    ├── ui-and-lifecycle.md
    ├── data-and-privacy.md
    └── development.md
```
