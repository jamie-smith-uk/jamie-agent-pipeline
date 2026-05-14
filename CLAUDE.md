# jamie-agent-pipeline

A reusable AI agent pipeline for building software projects. This is the **template repo** — it contains agent definitions, orchestrator scripts, and project templates. It is not a project repo itself.

## What lives here

    .opencode/agents/    agent system prompts (ag-01 through ag-08, numbered in execution order)
    .opencode/rules/     opencode rules loaded every session (security, typescript)
    orchestrator/        approve.sh, setup-pipeline.sh, sync-pipeline.sh
    orchestrator/src/    TypeScript orchestrator (index.ts, phases/, checks/)
    docs/templates/      PRD, architecture, env, and smoke test templates for new projects
    docs/                pipeline documentation (best-practices.md)

## Execution order

AG-01 Architect → AG-02 Reviewer → human gate → per task: AG-03 Tester (RED) → AG-04 Developer (GREEN) → AG-05 Migration (if applicable) → AG-06 Refactor → AG-07 Security → AG-08 Validator (phase end)

## Placeholder convention

Use `{PROJECT_NAME}` and `{project-name}` as placeholders in all agent files and orchestrator scripts. `setup-pipeline.sh` and `sync-pipeline.sh` substitute these when deploying to a project. Never hardcode project-specific stack details (framework names, model IDs, service names) in template files — those belong in `docs/architecture.md` of each deployed project.

## Making changes

**Updating an agent:** edit `.opencode/agents/ag-XX-name.md` directly. Keep prompts focused — one role, clear scope, explicit escape hatches (BLOCKED.md). Critical rules go at the start.

**Updating orchestrator scripts:** edit files in `orchestrator/src/`. Shell scripts (`approve.sh`, `setup-pipeline.sh`, `sync-pipeline.sh`) handle setup and human gates only. Use `python3` for JSON and text manipulation in shell scripts (avoids jq dependency).

**Updating the TypeScript orchestrator:** edit files in `orchestrator/src/`. The canonical entry point is `orchestrator/src/index.ts`; phases are in `orchestrator/src/phases/` and quality checks in `orchestrator/src/checks/`. Apply the same `{PROJECT_NAME}` / `{project-name}` placeholder rules — no hardcoded project names in any `.ts` file.

**Propagating to deployed projects:** `./orchestrator/sync-pipeline.sh --target /path/to/project`

## Key conventions

- Shell scripts: `set -euo pipefail`, mkdir-based locking for shared state, no sleep after long-poll
- Prompt injection defence: wrap untrusted/external content in `<tag>` delimiters in orchestrator prompts
- Commit messages: `feat(v1.X): ...` / `fix(vY.Z): ...` for pipeline improvements
- Agent report titles must follow the exact pattern `Title: ... — PASS` or `Title: ... — FAIL` — the orchestrator's `report_passes()` matches on this
- Metrics: `pipeline/phase-N/metrics.json` — high retry counts signal spec or prompt gaps
- Context cap: `CONTEXT_MAX_CHARS=4000` in `orchestrator/src/context.ts` controls how much context.md is injected

## Running locally

Requires: opencode CLI, Anthropic API key, Node.js 20+, pnpm. See `docs/best-practices.md` for design rationale.

```bash
# Run a full pipeline phase (TypeScript orchestrator — canonical)
pnpm exec tsx orchestrator/src/index.ts --phase 1

# Run a single ad-hoc task
pnpm exec tsx orchestrator/src/run-task.ts backlog/my-task.md
pnpm exec tsx orchestrator/src/run-task.ts --quick "Fix the crash in handler"
```
