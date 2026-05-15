import fs from "node:fs";
import path from "node:path";
import { log } from "../config.js";
import { runAgent } from "../agent.js";
import { verifyImplementation } from "../gates.js";
import type { PipelineConfig, Task } from "../types.js";

// ── tryFixer() ────────────────────────────────────────────────────────────────

/**
 * Invokes the Fixer agent (up to 2 attempts) and re-runs verifyImplementation.
 * Returns remaining failures (empty = fixed).
 */
export function tryFixer(
  cfg: PipelineConfig,
  task: Task,
  taskDir: string,
  reason: string,
  failingAgent: string,
  failureOutput: string,
  filesInScopeJson: string,
): string {
  const maxFixerAttempts = 2;

  let currentFailureOutput = failureOutput;

  for (let n = 1; n <= maxFixerAttempts; n++) {
    log(`→ Fixer agent (attempt ${n}/${maxFixerAttempts}): ${reason}`);

    const fixerOut = path.join(taskDir, `fixer-output-${n}.md`);
    try {
      fs.unlinkSync(path.join(taskDir, "fixer-report.md"));
    } catch {
      // ignore
    }

    // List gate failure files (don't inline — avoids E2BIG on large histories)
    const gateFailureFiles: string[] = [];
    let i = 1;
    while (true) {
      const gf = path.join(taskDir, `gate-failures-${i}.txt`);
      if (!fs.existsSync(gf)) break;
      gateFailureFiles.push(gf);
      i++;
    }

    // Build files_in_scope bullet list
    const filesInScope: string[] = JSON.parse(filesInScopeJson);
    const filesBulletList = filesInScope.map((f) => `  - ${f}`).join("\n");

    const taskSpec = `<task-spec>\n${JSON.stringify(task, null, 2)}\n</task-spec>`;
    const contextMdPath = path.join(cfg.pipelineDir, "context.md");

    const fixerPrompt = `GATE FAILURE — Fixer invoked [attempt ${n}/${maxFixerAttempts}]

## Situation
Phase: ${cfg.phase}
Task: ${task.id}
Failing agent: ${failingAgent}
Reason: ${reason}

## What failed (exact output)
<failure-output>
${currentFailureOutput}
</failure-output>

## Task specification
${taskSpec}

## Files in scope for this task
${filesBulletList || "  (error reading scope)"}

## Prior gate failure history (all attempts before fixer was called)
${gateFailureFiles.length > 0
  ? `Read these files for the full history:\n${gateFailureFiles.map((f) => `  - ${f}`).join("\n")}`
  : "(none recorded)"}

## Context from completed tasks in this phase
See: ${contextMdPath}

## Key reference files — read these before diagnosing
The following files contain the full design context. Read them all:

- Architecture + schema: ${cfg.repoRoot}/docs/architecture.md
- Security rules: ${cfg.repoRoot}/.opencode/agents/security-rules.md
- Phase manifest: ${cfg.pipelineDir}/task-manifest.json
- Architect analysis: ${cfg.pipelineDir}/ag01-output.md
- Reviewer summary: ${cfg.pipelineDir}/reviewer-summary.md
- Tester output (why tests were written this way): ${taskDir}/tester-red-output.md
- Developer self-assessment (what dev thought they built): ${taskDir}/self-assessment.md
- RED phase test run (tests before implementation): ${taskDir}/test-red-output.txt
- Developer output logs: ${taskDir}/dev-output-*.md (if any)
- Security agent output: ${taskDir}/sec-output-*.md (if any)
- Refactor agent output: ${taskDir}/refactor-output.md (if any)
- All test files in scope packages (read the actual test files on disk)
- All implementation files in scope (read the actual source files on disk)

## Paths
Repo root: ${cfg.repoRoot}
Pipeline phase dir: ${cfg.pipelineDir}
Task pipeline dir: ${taskDir}

## Your job
1. Read ALL the reference files listed above
2. Read the actual source and test files for this task
3. Diagnose the root cause of the failure
4. Fix the right file(s)
5. Run all four validation commands (tsc, biome --write, biome check, pnpm test)
6. Write fixer-report.md to ${taskDir}/

Follow your system prompt exactly.`;

    runAgent("ag-fixer", fixerPrompt, fixerOut, 900, cfg.pipelineDir);

    const newFailures = verifyImplementation(filesInScopeJson, cfg.repoRoot);

    if (!newFailures) {
      log(`Fixer resolved: ${reason}`);
      return "";
    }

    log(`Fixer attempt ${n}: gate still failing`);
    currentFailureOutput = newFailures;
  }

  // All fixer attempts exhausted
  return currentFailureOutput;
}
