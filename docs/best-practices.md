# Agentic Development Best Practices

> Evidence-based principles for building software with AI agents — drawn from Anthropic engineering, academic research, and production experience.

**Sources:** Anthropic Engineering Blog (Harness Design, March 2026) · Anthropic Agentic Coding Trends Report 2026 · Vantor Engineering Agentic SDLC (April 2026) · OWASP Top 10 for Agentic Applications 2026 · NVIDIA AI Red Team (January 2026) · arXiv 2601.17548 Prompt Injection in Agentic Coding Assistants · HumanLayer — Writing a Good CLAUDE.md · Addy Osmani — How to Write a Good Spec for AI Agents · Claude Code Best Practices (Anthropic, April 2026)

---

## 1. The State of Agentic Development in 2026

Agentic AI coding has crossed a threshold. In 2025, AI assisted discrete tasks. In 2026, agents are being orchestrated across full software delivery pipelines — planning, implementation, security review, testing, and deployment. The question has shifted from whether AI can participate to how deliberately you design the system around it.

> **The core shift:** The primary impact of agentic engineering is not faster code generation. It is a structural shift in how software moves through the delivery pipeline — compressing coordination overhead, sharing context across stages, and redefining where human attention is most valuable. *(LangChain, 2026)*

### What the research tells us

- Multi-agent architectures — where an orchestrator coordinates specialised agents each with dedicated context — consistently outperform single-agent workflows on complex tasks
- Context window management is the defining constraint. Performance degrades as the context window fills, and models exhibit "context anxiety" as they approach what they believe is their limit
- Self-evaluation is unreliable. Agents asked to grade their own work skew positive even when quality is obviously poor. Separating the generator from the evaluator is the strongest single lever for quality improvement
- Engineers delegate tasks that are easily verifiable or low-stakes. Design-dependent, architecturally significant decisions stay with humans
- Prompt injection is a first-class vulnerability. Attack success rates against current defences exceed 85% when adaptive strategies are employed

### The three failure modes to design against

| Failure mode | What happens | Solution |
|---|---|---|
| Context drift | Agents lose coherence on lengthy tasks as context fills. Decisions made early do not carry forward | Context resets between agents, structured handoff artifacts |
| Self-validation bias | Agents grade their own work leniently. A generator cannot reliably evaluate what it just produced | Separate evaluator agents with explicit skepticism instructions |
| Prompt injection | External content can redirect agent behaviour | Label all external content as untrusted, validate inputs, minimal tool permissions |

---

## 2. Pipeline Design Principles

### P-01 — Separate the generator from the evaluator

An agent cannot reliably judge what it just produced. Build distinct agents for doing and for checking.

**Do:**
- Create a dedicated Security Agent that only audits, never implements
- Create a dedicated Tester Agent that only verifies, never writes application code
- Give evaluator agents explicit skepticism instructions — "be critical, do not pass mediocre work"
- Pass the evaluator the original specification so it can check intent, not just output

**Do not:**
- Ask the Developer agent to review its own code for security issues
- Use the same agent session for generation and validation
- Trust self-assessment without independent verification

---

### P-02 — Define success before writing code

Acceptance criteria must exist before the Developer runs. Ambiguous criteria produce ambiguous code.

**Do:**
- Write explicit, testable acceptance criteria for every task in the manifest
- Require the Tester to map each criterion to at least one test
- Use the Architect to produce the specification — not the Developer
- Treat the PRD and task manifest as contracts, not suggestions

**Do not:**
- Let the Developer interpret vague requirements on the fly
- Write acceptance criteria after the fact to match what was built
- Accept "it works" as a passing criterion

---

### P-03 — Communicate through files, not shared context

State should live in files that persist between agent sessions, not in conversation context that evaporates.

**Do:**
- Write structured output files at the end of every agent run
- Use the pipeline directory as the shared state store between agents
- Include enough state in handoff artifacts for the next agent to start fresh
- Treat each agent invocation as stateless — it reads files, does work, writes files

**Do not:**
- Rely on conversation history to carry context between agents
- Assume one agent knows what another agent did in a previous session
- Use in-memory state that disappears when the process exits

---

### P-04 — Reset context between agents

Context resets — clearing the context window and starting fresh — outperform compaction for long-running tasks.

**Do:**
- Give each agent a clean session with only the context it needs for its specific role
- Pass structured handoff artifacts rather than conversation history
- Keep each agent's context lean — task spec, not full codebase

**Do not:**
- Pipe full conversation history from one agent to the next
- Use compaction as a substitute for a proper context reset
- Give every agent access to everything — scope context to role

---

### P-05 — Decompose into atomic tasks

Large tasks produce large, unverifiable outputs. Atomic tasks produce small, testable increments.

**Do:**
- Each task should touch a defined set of files — scope matters
- Each task should have a single, clear acceptance criteria set
- Dependencies between tasks should be explicit and ordered
- If a task cannot be tested in isolation, it is too large

**Do not:**
- Create tasks that span multiple packages or services without clear boundaries
- Allow tasks with vague scope ("implement the authentication system")
- Skip dependency ordering — let agents figure it out

---

### P-06 — Put a human in the loop at the right moment

Human gates earn their cost when placed at high-leverage decision points. Everywhere else they create friction without safety.

**Do:**
- Gate on the plan, not on every implementation detail
- Let the human approve the task manifest before any code is written
- Notify on halt conditions — let the human unblock
- Send phase completion summaries so the human stays informed without being involved

**Do not:**
- Require human approval for every tool call
- Skip human review entirely
- Place the human gate after implementation has already started

---

### P-07 — Enforce scope discipline on the Developer

Agents will expand scope if not constrained. `files_in_scope` is not a suggestion.

**Do:**
- Define the exact files a Developer may touch per task
- Reject any output that writes outside `files_in_scope`
- Use the Security Agent to check for scope violations
- Give Developers a `BLOCKED.md` escape hatch for genuine blockers — never let them guess

**Do not:**
- Allow the Developer to create new files not in the manifest
- Let scope expand because "it seemed related"
- Accept wide refactors unless explicitly in the task spec

---

### P-08 — Build for resumability

Pipelines will fail mid-run. Design so they can resume from the last successful checkpoint.

**Do:**
- Write PASS/FAIL status to a file after every task gate
- Skip already-complete tasks on re-run based on file existence
- Write `HALT.md` with full context on pipeline failure
- Never re-run completed tasks without explicit instruction

**Do not:**
- Assume pipelines will always run to completion on the first attempt
- Restart the entire pipeline from scratch after a failure
- Discard pipeline output on failure — preserve it for debugging

---

## 3. Context and Prompt Engineering

### The context window is your most limited resource

Every token in context competes for attention. As instruction count increases, instruction-following quality decreases uniformly — the model does not just ignore newer instructions, it begins to ignore all of them.

> **Rule:** Keep your root CLAUDE.md or agent system prompt under 100 lines. Universal rules only. Task-specific knowledge belongs in separate files loaded on demand.

> **Finding:** Claude Code's system prompt already contains approximately 50 individual instructions. That is nearly a third of what a model can reliably follow before quality degrades. Every instruction you add competes with the baseline. *(HumanLayer, 2025)*

### Tiered context loading

| Tier | When loaded | What it contains |
|---|---|---|
| Tier 1 — Always | Every session | Universal rules, identity, tone, security non-negotiables. Under 100 lines. |
| Tier 2 — Task-type | When task type matches | TypeScript rules for TS tasks, database rules for DB tasks, security rules for sensitive tasks |
| Tier 3 — On-demand | Fetched via tool calls | Specific schemas, API contracts, existing code patterns |

### Writing effective agent system prompts

- Lead with identity — who the agent is and what its job is, in two sentences
- State what the agent must NOT do as explicitly as what it must do
- Use the Why / What / How structure
- Include escape hatches — "if blocked, write BLOCKED.md rather than guessing"
- Reference external files rather than embedding their content
- Put the most critical instructions at the beginning and end — LLMs attend most strongly to peripheries

### Spec-driven development

The spec is the highest-leverage artifact in an agentic pipeline. Before any agent writes code:

- Define users, workflows, and acceptance criteria explicitly
- Use Plan Mode (read-only) to let the Architect explore the codebase before committing to a manifest
- Save the approved spec as a file that all subsequent agents reference
- Treat the spec as a living document — update it when scope changes, never let it drift from implementation

> Addy Osmani's principle: "If Claude needs to ask clarifying questions during execution, your plan has gaps."

---

## 4. Security in Agentic Pipelines

> **OWASP 2026:** Prompt injection has topped the OWASP Top 10 for LLM Applications since the list's inception. In agentic systems, what was a single manipulated output becomes an orchestrated multi-tool attack chain. ASI01 (Agent Goal Hijack) is the defining agentic security risk of 2026.

### The threat model

| Threat | Description |
|---|---|
| Indirect prompt injection | Malicious instructions embedded in content the agent reads — git repos, README files, emails, API responses, MCP tool results |
| Tool permission escalation | Agents with broad tool permissions can be manipulated to exceed their intended scope |
| Secret exfiltration | Agents with access to .env or env vars can be manipulated to log or transmit secrets |
| Supply chain attacks | Agents adding dependencies with ^ or ~ prefixes can pull in compromised package versions |
| Self-validating tests | Agents generating tests designed to pass regardless of correctness |

### Defence-in-depth framework

**Layer 1 — Input boundaries**
- Label all external content as untrusted before passing to the agent
- Never concatenate raw external input with system instructions
- Validate all inputs — length limits, format checks, whitelist checks
- Treat MCP responses as untrusted data, not trusted instructions

**Layer 2 — Minimal permissions**
- Give each agent only the tools it needs for its specific role
- Read-only agents must have write: false enforced at the framework level, not just in the system prompt
- Block file writes outside the workspace
- Block network egress to arbitrary sites

**Layer 3 — Secrets management**
- Never pass secrets to agents
- Never log environment variable values
- Secrets never appear in agent prompts, system prompts, tool results, or conversation history
- Use exact dependency pinning — no ^ or ~ prefixes

**Layer 4 — Human gates for high-impact actions**
- Require explicit confirmation before any write operation that cannot be undone
- The confirmation pattern must be enforced at the orchestrator level, not just requested in the agent prompt
- Be aware of approval fatigue — humans who approve too many low-stakes actions stop reviewing high-stakes ones

**Layer 5 — Audit trails**
- Log all agent actions, tool calls, and decisions with timestamps
- Write structured output files that persist beyond the session
- Every action must be traceable to a human who authorised it
- Git tags and commit messages serve as the audit trail for what was built and when

---

## 5. Testing in Agentic Pipelines

### The self-validation problem

Agents asked to test their own code face the same bias as agents asked to review their own design. The Tester must be a separate agent that receives only the specification and the security-cleared code — never the Developer's self-assessment.

### What to test

| Priority | What |
|---|---|
| 100% coverage required | Security-critical paths, state machines, scheduler logic, all database query functions |
| High coverage | Business logic with clear inputs and outputs |
| Lower priority | Formatting, presentation, third-party integrations (mock these) |
| Watch for | Tests with no meaningful assertions, tests that mock the thing being tested, coverage without correctness |

### Mutation testing

The strongest defence against self-validating tests. Change the implementation and check if tests fail. If they do not, the tests are not testing anything real. Apply to all security-critical tasks.

### The Writer/Reviewer pattern

Have one session write tests, then a separate session write code to pass them. A fresh context improves code review since the agent will not be biased toward code it just wrote. *(Claude Code Best Practices, Anthropic 2026)*

---

## 6. Observability and Recovery

### Metrics that matter

| Metric | What it tells you |
|---|---|
| Task pass rate | Percentage passing Security and Tester on first attempt. Low rate = spec or prompt gap. |
| Security finding categories | Which rules fail most often. Recurring failures = Developer prompt gap. |
| Retry depth | How many cycles to pass each gate. Deep loops = spec ambiguity. |
| Token spend per phase | Spikes indicate too-broad context loading. |
| Halt frequency and cause | Categorise halts — approval timeout, security failure, test failure, blocked task. |

### Designing for recovery

- Every task gate writes a PASS/FAIL file — the pipeline can resume from last checkpoint
- `HALT.md` must contain: reason, agent, phase, task, full output that caused the halt
- Preserve pipeline output on failure — never clean up automatically
- The orchestrator must not crash on agent failure — catch errors, write HALT.md, notify, exit cleanly
- Loop limits prevent infinite retry cycles — 3 attempts for task gates, 2 for phase validation

### The AgentOps mindset

Treat agent system prompts like code: version them, review changes, test the effect of modifications. When a security rule keeps getting violated, fix the Developer agent prompt. When a test pattern keeps failing, fix the Tester specification. Build the system to learn and improve.

---

## 7. Applied to jamie-agent-pipeline

### What the pipeline does well

- **Generator/evaluator separation** — Developer, Security, and Tester are distinct agents with distinct sessions and scoped permissions
- **TDD first** — AG-03 Tester writes failing tests (RED) before AG-04 Developer implements (GREEN); orchestrator hard gate runs `tsc + eslint + pnpm test` directly, not via agent self-report
- **File-based state** — all pipeline artifacts persist between runs; the pipeline resumes from last checkpoint using sentinel files
- **Atomic tasks** — Architect produces a manifest with explicit `files_in_scope`, `dependencies`, and testable `acceptance_criteria`
- **Human gate at the right point** — approval required before implementation, with revision rounds and "What changed" summaries to combat approval fatigue
- **Security as a hard gate** — AG-07 Security blocks the pipeline on FAIL with no bypass; security findings categorised and tracked in metrics
- **Prompt injection defence** — all manifest content wrapped in `<task-spec>` tags; external content rules in security-rules.md use explicit `<untrusted>` labelling
- **Scope enforcement** — `files_in_scope` violations automatically reverted after every Developer run
- **Mutation testing** — security-sensitive tasks get mutation testing after GREEN to verify tests actually catch removed security checks
- **Tiered context loading** — Architect receives only the relevant PRD phase section and its epics, not the full document
- **Metrics** — per-task timing, retry counts, security finding categories, and high-retry signals written to `metrics.json`
- **Resumability** — sentinel files per phase (tests-written, green-verified, refactor-verified, migration-verified) enable clean mid-task resume

### Remaining gaps

| Gap | Description |
|---|---|
| Code health monitoring | No cyclomatic complexity, duplication detection, or test coverage tracked over time. The Refactor agent uses judgment, not measurement. |
| Trajectory evaluation | Pipeline checks end-state (did it write PASS?) but not trajectory (did it take the right actions in the right order?). |
| Architecture doc tiering | The full architecture doc is still injected into Architect prompts — same tiering applied to the PRD in v1.2 should extend here. |
| pass@1 rate | `attempts` is tracked per phase but first-attempt pass rate is not computed as a percentage across all tasks. |
| Task-manifest schema validation | AG-01 output is loosely parsed — not validated against a JSON schema before the Reviewer runs. |
| LLM judge for acceptance criteria | Regex-based quality gate (v1.3) misses nuanced non-testability. A model-based grader would be more accurate. |
| Token cost tracking | No token spend recorded per agent or phase — spikes in context loading are invisible. |
| Agent calibration run | No way to verify the full pipeline is correctly configured on a new project without running a real phase. |
| Codebase health pre-flight | No pre-phase assessment of codebase patterns that cause agent failures (inconsistent naming, missing types, unresolved TODOs). |
| Context compaction | `context.md` overflow is handled by truncation — LLM-based summarisation would preserve more signal. |

### Improvement roadmap

**Shipped:**
- v1.1 — Prompt injection defence, validator completeness, stale agent descriptions, Life OS content removed from templates
- v1.2 — `files_in_scope` enforcement, tiered Architect context (PRD), `context.md` growth cap
- v1.3 — Mutation testing, acceptance criteria quality gate, security finding category tracking
- v1.4 — CLAUDE.md, smoke test template, approval fatigue mitigation (revision format, security tasks first)

**Planned:**
- **v2.1** — Architecture doc tiered loading · JSON schema validation for task-manifest.json · pass@1 rate metric
- **v2.2** — Trajectory evaluation · LLM judge for acceptance criteria · Agent calibration script (`check-pipeline.sh`)
- **v2.3** — Code health monitoring: `jscpd` duplication gate, Vitest coverage tracking, complexity measurement per task; cross-phase health trends in metrics
- **v2.4** — Codebase health pre-flight agent (AG-00) · Trust boundary hardening · Token cost tracking
- **v3.0** — Parallel task execution for independent tasks in the same phase (dependency-aware wave execution)

---

## 8. Quick Reference

### Before starting a new project
- Write the PRD and architecture doc before running the pipeline
- Define acceptance criteria for every user story before the Architect runs
- Create a Telegram bot via @BotFather
- Run `setup-pipeline.sh` and verify all environment variables are set
- Check `pnpm audit` returns zero high or critical findings

### When the pipeline halts
- Read `HALT.md` — it contains the exact reason, agent, and output
- Fix the root cause in the agent prompt or the spec — not just the code
- Delete the PASS files for affected tasks to force re-run
- Re-run — completed tasks will be skipped automatically

### When security keeps failing on the same rule
- Add a CRITICAL prefix to the rule in the Developer system prompt
- Update `security-rules.md` with a concrete example of the violation and the fix
- Run `sync-pipeline.sh` to propagate the fix to all projects

### Red flags in pipeline output
- Tests passing 100% on first attempt every time — check for self-validation
- Mutation testing showing many survived mutations — Tester is writing shallow tests
- Security reports only catching dependency pinning — Security Agent may not be reading the full ruleset
- Developer always needs 3 attempts — spec is probably ambiguous, not Developer failure
- Acceptance criteria quality warnings on every task — PRD needs more specific stories
- Phase completes but behaviour is wrong — exit criteria were too vague
- Pipeline is slow and expensive — context loading is probably too broad
- high_retry_tasks growing across phases — same tasks keep struggling; review those task specs
- top_security_findings showing the same rule repeatedly — fix the Developer agent prompt, not just the code

---

*Last updated: April 2026 | jamie-agent-pipeline*
