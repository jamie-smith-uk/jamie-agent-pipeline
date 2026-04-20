# jamie-agent-pipeline

A reusable AI agent pipeline for building software projects with automated coding, security review, testing, and validation.

## What this is

Six specialised AI agents that build software from a PRD and architecture document:

- AG-01 Architect — breaks the PRD into an ordered task manifest
- AG-02 Reviewer — presents the plan for human approval via Telegram
- AG-03 Developer — implements one task at a time
- AG-04 Security — audits every output against a security ruleset
- AG-05 Tester — writes and runs tests against every task
- AG-06 Validator — signs off the phase against exit criteria

## Setup for a new project

1. Clone this repo
2. Run: ./setup-pipeline.sh --project "Your Project Name" --target /path/to/your/project
3. Add your PRD to docs/prd.md and architecture to docs/architecture.md in the target project
4. Run: ./orchestrator/run-phase.sh --phase 1

## Updating an existing project

To pull the latest pipeline improvements into a project:

    ./sync-pipeline.sh --target /path/to/your/project

## Requirements

- opencode CLI installed
- Anthropic API key
- Telegram bot token and chat ID
- pnpm
