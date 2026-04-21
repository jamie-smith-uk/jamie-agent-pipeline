# jamie-agent-pipeline

A reusable AI agent pipeline for building software projects with automated planning, TDD implementation, security review, and validation.

## What this is

Eight specialised AI agents that build software from a PRD and architecture document, following a strict red/green/refactor cycle with hard gates at every stage:

| Agent | Role |
|---|---|
| AG-01 Architect | Breaks the PRD phase into an ordered task manifest with explicit acceptance criteria |
| AG-02 Reviewer | Presents the plan for human approval in the terminal before any code is written |
| AG-03 Tester | Writes failing tests first (RED phase) — tests define the contract |
| AG-04 Developer | Implements code to make the tests pass (GREEN phase) |
| AG-05 Migration | Validates and runs DB migrations, checks reversibility (conditional) |
| AG-06 Refactor | Cleans up the implementation without changing behaviour |
| AG-07 Security | Audits every file against a security ruleset — hard gate, no bypass |
| AG-08 Validator | Signs off the full phase against PRD exit criteria and smoke tests |

## How it works

Each phase runs as: plan → human approval → per-task loop → phase sign-off.

**Per-task loop:**
1. AG-03 writes failing tests (RED)
2. Orchestrator confirms tests fail
3. AG-04 implements until `tsc + eslint + pnpm test` all pass (hard gate)
4. Scope compliance checked — out-of-scope file writes are reverted automatically
5. AG-05 validates any migration files (if applicable)
6. AG-06 refactors — hard gate re-runs after
7. Mutation testing runs for `security_sensitive` tasks
8. AG-07 audits for security
9. Per-task git commit, context.md updated, metrics recorded

## Setup for a new project

```bash
# 1. Clone this repo
git clone https://github.com/jamie-smith-uk/jamie-agent-pipeline

# 2. Set up a new project
./orchestrator/setup-pipeline.sh --project "Your Project Name" --target /path/to/project

# 3. Fill in docs/prd.md and docs/architecture.md in the target project

# 4. Run phase 1
cd /path/to/project && ./orchestrator/run-phase.sh --phase 1
```

`setup-pipeline.sh` will prompt for your Anthropic API key and write `.env`.

## Updating an existing project

```bash
./orchestrator/sync-pipeline.sh --target /path/to/project
```

## Requirements

- opencode CLI
- Anthropic API key
- Node.js 20, pnpm, Python 3

## Pipeline output

Each phase produces a `pipeline/phase-N/` directory containing:

```
pipeline/phase-1/
  task-manifest.json        task plan produced by Architect
  approval.json             human approval record
  context.md                accumulated build context across tasks
  metrics.json              timing, retry counts, security findings per task
  task-1/
    tests-written.txt       RED phase confirmation
    green-verified.txt      GREEN hard gate confirmation
    mutation-report.md      mutation testing results (security tasks)
    refactor-report.md      refactor changes made
    security-report.md      security audit result
    test-report.md          hard gate output (machine-generated)
  validation-report.md      phase sign-off
```

## Smoke tests

Add smoke tests to `smoke-tests/phase-N.sh` in your project. The template is copied automatically by `setup-pipeline.sh`. AG-08 Validator runs this script as part of phase sign-off.

## Metrics

`metrics.json` tracks per-task timing, retry counts, and security finding categories. At the end of each phase, the orchestrator logs:

- Total wall-clock time
- Tasks with high retry counts (signals weak task specs or agent prompt gaps)
- Top security finding categories (recurring findings signal a Developer prompt gap)

## Design principles

See `docs/best-practices.md` for the full rationale. Key decisions:

- **Generator/evaluator separation** — Developer, Security, Tester are distinct agents with distinct sessions
- **TDD first** — tests are written before implementation, hard gates verify the compiler and test runner directly
- **File-based state** — all pipeline artifacts persist between runs; the pipeline resumes from last checkpoint
- **Human gate at the right point** — approval required before implementation starts, not on every action
- **Prompt injection defence** — all manifest content wrapped in `<task-spec>` tags before injection into agent prompts

## Repository structure

```
.opencode/agents/    agent system prompts (ag-01 through ag-08)
.opencode/rules/     opencode rules loaded every session
orchestrator/        run-phase.sh, run-task.sh, setup-pipeline.sh, sync-pipeline.sh, check-pipeline.sh
docs/templates/      PRD, architecture, env, and smoke test templates
docs/                best-practices.md, pipeline documentation
CLAUDE.md            context file for Claude Code sessions in this repo
```
