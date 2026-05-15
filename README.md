# jamie-agent-pipeline

A reusable AI agent pipeline that builds software from a PRD and architecture document, following a strict TDD cycle with hard gates at every stage. Runs locally or on GitHub Actions.

---

## What this is

Eleven specialised AI agents that plan, split, build, test, secure, and validate software — one phase at a time. A PM agent writes the PRD itself from a GitHub Issue brief.

| Agent | Role | Permissions |
|---|---|---|
| **AG-PM** | Turns a GitHub Issue brief into a structured PRD draft, iterating on feedback | write (drafts only) |
| **AG-01 Architect** | Breaks a PRD phase into an ordered task manifest with acceptance criteria | read-only |
| **AG-02 Reviewer** | Translates the manifest into a plain-English summary for human approval | read-only |
| **AG-09 Splitter** | Splits high-complexity tasks into small, independently testable sub-tasks | write (manifest only) |
| **AG-03 Tester** | Writes failing tests (RED phase) — tests define the contract before any code | write (tests only) |
| **AG-04 Developer** | Implements code to make tests pass (GREEN phase) — bounded to `files_in_scope` | write (in-scope only) |
| **AG-05 Migration** | Validates and runs DB migrations, checks reversibility | conditional |
| **AG-06 Refactor** | Cleans up the implementation without changing behaviour | write (in-scope only) |
| **AG-07 Security** | Audits every file against security rules — hard gate, no bypass | read-only |
| **AG-08 Validator** | Signs off the full phase against PRD exit criteria and smoke tests | read-only |
| **AG-Fixer** | Emergency recovery agent — last resort before a hard HALT | write (anything) |

---

## How it works

### Phase flow

```
AG-PM (optional) ─── writes PRD draft from GitHub Issue
        ↓
AG-01 Architect ─── produces task-manifest.json
        ↓
AG-02 Reviewer ──── produces reviewer-summary.md
        ↓
  [Human approval gate]
        ↓
AG-09 Splitter ──── breaks high-complexity tasks into sub-tasks
        ↓
  ┌─── per-task loop ──────────────────────────────────────┐
  │  AG-03 Tester    writes failing tests (RED)            │
  │  AG-04 Developer implements until gate passes (GREEN)  │
  │    → tsc + biome check + pnpm test (hard gate)         │
  │    → scope compliance check (violations reverted)      │
  │    → false-GREEN guard (no in-scope changes = fail)    │
  │  AG-05 Migration validates DB migrations (if any)      │
  │  AG-06 Refactor  cleans up; gate re-runs after         │
  │  AG-07 Security  audits; Developer fixes; re-audits    │
  │  AG-Fixer        if all retries exhausted (emergency)  │
  │  per-task git commit + context.md + metrics            │
  └────────────────────────────────────────────────────────┘
        ↓
AG-08 Validator ─── signs off phase; creates git tag
```

### Hard gates

Every gate runs the actual toolchain — not agent self-report:

- **tsc `--noEmit`** — no TypeScript errors
- **biome check** — linting including `noExcessiveCognitiveComplexity` (threshold: 10)
- **pnpm test `--run`** — all tests pass

A developer attempt failing any gate produces a detailed failure message fed back to AG-04 for the next retry (max 3 attempts). If all retries are exhausted, AG-Fixer is invoked as a last resort before a hard HALT.

### Task splitting

AG-09 Splitter runs once after the human gate, before any Tester or Developer work. It breaks tasks with `estimated_complexity: "high"`, more than 4 acceptance criteria, or more than 3 files in scope into 2–4 focused sub-tasks (`task-5a`, `task-5b`, etc.) — each independently testable. Already-complete tasks are excluded before the splitter sees the manifest.

### Security gate

AG-07 Security audits against rules in `.opencode/agents/security-rules.md`. On FAIL, AG-04 Developer receives the findings with `files_in_scope` and accumulated context, fixes them, and the hard gate re-runs before AG-07 audits again. Up to 3 fix cycles per task.

### Complexity gate

`biome check` enforces `noExcessiveCognitiveComplexity` with a threshold of 10. Before AG-06 Refactor runs, the health check parses Biome's JSON output and injects specific violations — `file:line (score N)` — directly into AG-06's prompt as named targets.

### Fixer agent

If AG-04 Developer exhausts all retries on a gate, AG-Fixer is invoked. Unlike other agents, it can touch any file — including test files — to resolve genuine pipeline deadlocks. It writes `fixer-report.md` explaining every change made, and the hard gate re-runs after it before the pipeline continues.

### Validator retry loop

If AG-08 Validator rejects the phase, AG-04 Developer receives the specific exit-criteria failures and fixes them. The hard gate runs across all tasks before the validator is retried. Up to 2 fix cycles per phase.

---

## Running locally

### Prerequisites

- [opencode CLI](https://opencode.ai)
- Anthropic API key
- Node.js 20, pnpm

### Setup for a new project

```bash
# 1. Clone this repo
git clone https://github.com/jamie-smith-uk/jamie-agent-pipeline

# 2. Set up a new project
./jamie-agent-pipeline/orchestrator/setup-pipeline.sh \
  --project "My Project" \
  --target /path/to/my-project

# 3. Fill in docs/prd.md and docs/architecture.md

# 4. Install orchestrator dependencies
cd /path/to/my-project
npm install

# 5. Run phase 1
npx tsx orchestrator/src/index.ts --phase 1
```

`setup-pipeline.sh` creates the full directory structure, copies all agent files with your project name substituted, installs GitHub Actions workflows, and copies doc templates.

### Approval (local runs)

When the pipeline reaches the human gate, it waits for `pipeline/phase-N/approval.json`. Use the approval helper:

```bash
./orchestrator/approve.sh --phase 1              # approve
./orchestrator/approve.sh --phase 1 --stop       # stop pipeline
./orchestrator/approve.sh --phase 1 --changes "split task-3 into two tasks"
```

### Updating an existing project

When the pipeline repo improves, sync changes to any existing project:

```bash
./jamie-agent-pipeline/orchestrator/sync-pipeline.sh \
  --target /path/to/my-project
```

This updates `.opencode/agents/`, `.opencode/rules/`, `orchestrator/`, and `.github/workflows/` — but never touches `docs/`, `.env`, `pipeline/`, or `migrations/`.

---

## Running on GitHub Actions

The pipeline runs fully on GitHub Actions infrastructure — no local machine required.

### Workflow files

| Workflow | Trigger | What it does |
|---|---|---|
| `pipeline-architect.yml` | `workflow_dispatch` | Runs AG-01 + AG-02, commits manifest to repo |
| `pipeline-implement.yml` | `workflow_dispatch` | Runs AG-09 + AG-03 → AG-08 for all tasks, commits results |
| `pipeline-issue-task.yml` | Issue labeled `pipeline-ready` | Runs a single task described in the issue body |
| `pipeline-pm.yml` | Issue labeled `pm-ready` | Runs AG-PM to draft or revise PRD sections |
| `pipeline-pm-approve.yml` | Issue labeled `pm-approve` | Appends approved draft to `docs/prd.md`, opens PR, closes issue |

### CI flow

```
1. Trigger pipeline-architect (workflow_dispatch, phase: N)
      ↓ commits task-manifest.json and reviewer-summary.md to main
2. Review the manifest in the Actions log or repo
3. Approve via approve.sh (writes approval.json to the repo)
4. Trigger pipeline-implement (workflow_dispatch, phase: N)
      ↓ runs all tasks, commits results + phase-N-complete tag to main
```

### Required secrets

Set these in your repo → Settings → Secrets and variables → Actions:

| Secret | Required by |
|---|---|
| `ANTHROPIC_API_KEY` | All pipeline workflows |
| `POSTGRES_PASSWORD` | architect + implement jobs |
| `TODOIST_API_TOKEN` | implement job (if using Todoist) |

---

## PM agent — writing PRDs from GitHub Issues

### Flow

```
1. Create a GitHub Issue describing the feature
2. Add label "pm-ready" → pipeline-pm.yml runs
3. AG-PM reads the issue + existing docs/prd.md + previous drafts
4. Draft written to docs/prd-drafts/issue-{N}-round-{R}.md
5. Comment posted on issue with summary + link to draft
6. Review draft, reply with feedback, re-add "pm-ready" → Round 2
7. Repeat until satisfied
8. Add label "pm-approve" → draft appended to docs/prd.md, PR opened, issue closed
```

### Labels to create

- `pm-ready` — triggers draft/revision run
- `pm-approve` — triggers append to PRD + PR

---

## Pipeline output

Each phase produces a `pipeline/phase-N/` directory committed to the repo:

```
pipeline/phase-1/
  task-manifest.json          task plan (AG-01)
  reviewer-summary.md         human-readable plan summary (AG-02)
  approval.json               human approval record
  context.md                  accumulated build context across tasks
  metrics.json                timing, retry counts, health scores per task
  health-summary.md           complexity trends across tasks
  validation-report.md        phase sign-off (AG-08)
  task-1a/
    tester-red-output.md      RED phase confirmation
    test-report.md            test strategy summary
    dev-output-1.md           Developer attempt 1 output
    green-verified.txt        hard gate passed sentinel
    migration-report.md       migration result (if applicable)
    refactor-report.md        refactor changes made (AG-06)
    security-report.md        security audit result (AG-07)
    health-report.json        complexity/coverage after refactor
    self-assessment.md        Developer self-assessment
```

The `pipeline/` directory is tracked in git so the phase gate (`validation-report.md` from phase N must PASS before phase N+1 starts) works correctly on GitHub Actions.

---

## Design principles

See `docs/best-practices.md` for the full rationale. Key decisions:

- **Generator/evaluator separation** — Developer, Security, and Tester are distinct agents with distinct sessions and scoped tool permissions
- **TDD first** — tests written before implementation; hard gates verify the actual toolchain, not agent self-report
- **File-based state** — all artifacts persist between runs; pipeline resumes from last checkpoint via sentinel files
- **Anchored PASS detection** — `reportPasses()` inspects only the first 10 lines of a report file — prevents body text from creating false positives
- **Task splitting** — AG-09 ensures no task is too large to complete in one developer session before work begins
- **Scope enforcement** — `files_in_scope` violations automatically reverted; false-GREEN guard detects zero in-scope changes after revert and forces retry
- **Strict manifest schema** — Architect prompt includes explicit field list with allowed values; manifest machine-validated before Reviewer runs
- **Human gate at the right point** — approval on the plan before implementation starts, not on every action
- **Mutation testing** — security-sensitive tasks get mutation testing after GREEN to verify tests catch removed security checks
- **Context continuity** — accumulated `context.md` injected into all agent prompts so agents know established patterns from earlier tasks

---

## Repository structure

```
.opencode/
  agents/          agent system prompts (ag-pm, ag-01 through ag-09, ag-fixer, security-rules)
  config.json      opencode configuration
  rules/           security.md, typescript.md — loaded every session
.github/
  workflows/       pipeline-architect.yml, pipeline-implement.yml,
                   pipeline-pm.yml, pipeline-pm-approve.yml,
                   pipeline-issue-task.yml
orchestrator/
  src/
    index.ts       main pipeline orchestrator (canonical entry point)
    phases/        one module per agent phase (architect, splitter, tester, developer, ...)
    checks/        health, mutation, trajectory checks
    gates.ts       hard gate runner (tsc + biome + pnpm test)
    metrics.ts     per-task timing and retry tracking
    context.ts     context.md builder
  approve.sh       local approval helper
  setup-pipeline.sh  new project setup
  sync-pipeline.sh   update existing project from this repo
docs/
  templates/       PRD, architecture, env, smoke test templates
  best-practices.md  design rationale and research references
CLAUDE.md          context file for Claude Code sessions in this repo
```

---

## Quick reference

### When the pipeline halts

1. Check the Actions log or `HALT.md` — contains the exact reason, agent, and full detail
2. Fix the root cause — in the agent prompt or the spec, not just the code
3. Delete sentinel files for affected tasks to force re-run (e.g. `pipeline/phase-2/task-3/green-verified.txt`)
4. Re-run — completed tasks are skipped automatically via sentinel files

### When security keeps failing on the same rule

1. Add the rule with a concrete FAIL/PASS example to `.opencode/agents/security-rules.md`
2. Run `sync-pipeline.sh` to propagate to all projects using this pipeline

### When the manifest fails schema validation

The architect job prints the exact violations and raw manifest JSON to the Actions log before halting. Common causes:
- `estimated_complexity` using `XS`/`S`/`M` instead of `low`/`medium`/`high`
- `security_sensitive` field missing
- `files_in_scope` empty

### Red flags in pipeline output

- Tests passing 100% on first attempt every time — check for self-validation
- Many survived mutations — Tester is writing shallow tests
- Developer always needs 3 attempts — spec is probably ambiguous
- Same security rule failing repeatedly — fix the rule example in security-rules.md, not just the code
- Complexity scores above 10 in health-summary — tighten the AG-06 Refactor prompt

---

*Last updated: May 2026 | jamie-agent-pipeline v2.1*
