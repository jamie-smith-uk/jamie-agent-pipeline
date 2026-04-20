# Backlog

Single-task work items for the pipeline — bug fixes, small features, hotfixes.
One markdown file per task. Run with `./orchestrator/run-task.sh <file>`.

## Task file format

```markdown
---
title: Fix message handler crash on long input
security_sensitive: false
files:
  - src/handlers/message.ts
criteria:
  - Messages over 4000 chars are truncated at a clean boundary
  - A structured warning is logged when truncation occurs
  - The handler does not throw on any valid UTF-8 input
---

## Context (optional)

Users report the bot crashing when pasting long text. No length check
exists before processing. Fix should be in the main handler entry point.
```

## Required front matter fields

| Field | Type | Description |
|---|---|---|
| `title` | string | Short description — becomes the commit message |
| `files` | list | Files the Developer may touch (maps to `files_in_scope`) |
| `criteria` | list | Testable acceptance criteria |
| `security_sensitive` | bool | `true` if task touches auth, DB writes, secrets, external APIs |

## Optional fields

| Field | Default | Description |
|---|---|---|
| `complexity` | `medium` | `low` / `medium` / `high` |

## Usage

```bash
# Standard run
./orchestrator/run-task.sh backlog/my-task.md

# With Telegram approval gate first
./orchestrator/run-task.sh --review backlog/my-task.md

# Hotfix — skip Refactor and Mutation testing
./orchestrator/run-task.sh --urgent backlog/my-task.md

# Non-code change — skip Security
./orchestrator/run-task.sh --no-security backlog/my-task.md

# Preview without running agents
./orchestrator/run-task.sh --dry-run backlog/my-task.md

# Natural language (Architect generates the spec)
./orchestrator/run-task.sh --quick "Fix the crash on long messages"
```

Output goes to `pipeline/tasks/<slug>-<timestamp>/`.
