import fs from "node:fs";
import path from "node:path";
import { log } from "../config.js";
import { runAgent } from "../agent.js";
import { halt } from "../halt.js";
import { verifyImplementation, getAffectedPkgFilter, getExpandedFileList } from "../gates.js";
import { tryFixer } from "./fixer.js";
import { runCodeHealthChecks, writeRefactorDelta } from "../checks/health.js";
import { recordTaskMetrics } from "../metrics.js";
import type { PipelineConfig, Task } from "../types.js";

// ── runRefactorPhase() ────────────────────────────────────────────────────────

/**
 * REFACTOR phase: AG-06 cleans up without changing behaviour.
 */
export function runRefactorPhase(
  cfg: PipelineConfig,
  task: Task,
  taskDir: string,
  contextBlock: string,
): void {
  const refactorVerifiedFile = path.join(taskDir, "refactor-verified.txt");

  if (fs.existsSync(refactorVerifiedFile)) {
    log("REFACTOR phase already complete — skipping");
    return;
  }

  const refactorStart = Math.floor(Date.now() / 1000);
  log("REFACTOR phase — AG-06 Refactor...");

  const filesInScopeJson = JSON.stringify(task.files_in_scope);
  const filesExpanded = getExpandedFileList(filesInScopeJson);
  const affectedPkgs = getAffectedPkgFilter(filesInScopeJson);
  const pkgTestCmd = affectedPkgs ? `pnpm ${affectedPkgs} test` : "pnpm test";
  const taskSpec = `<task-spec>\n${JSON.stringify(task, null, 2)}\n</task-spec>`;
  const contextSection = contextBlock ? `\n${contextBlock}` : "";

  // Pre-check: derive health metrics from the pre-refactor baseline
  const complexCount = readPreRefactorComplexCount(taskDir);
  const dupPct = readPreRefactorDupPct(taskDir);

  const metricsClean = complexCount < 5 && dupPct < 8.0;

  if (metricsClean) {
    log(
      `REFACTOR phase: metrics clean (complex_fns=${complexCount}, dup=${dupPct}%) — skipping agent`,
    );
    fs.writeFileSync(
      path.join(taskDir, "refactor-report.md"),
      `# Refactor Report — ${task.id}\n\nSkipped: health metrics within thresholds.\n- Complex functions above threshold: ${complexCount} (limit: 5)\n- Code duplication: ${dupPct}% (limit: 8%)\n\nNo refactoring needed.\n`,
    );
  } else {
    // Build complexity block
    const complexityBlock = buildComplexityBlock(taskDir);
    const complexitySection = complexityBlock
      ? `\n## Complexity violations to fix\n\n${complexityBlock}\n`
      : "";

    const refactorPrompt = `You are AG-06 Refactor for {PROJECT_NAME}.

The Developer has implemented task ${task.id} and all tests pass.
Your job is to improve the code without changing its behaviour.

Task spec:
${taskSpec}${contextSection}${complexitySection}
Read every file in files_in_scope and the corresponding test files.
Make conservative, targeted improvements only.
Do NOT modify test files. Do NOT change public interfaces.

## Required: run validation before writing the report
Run these in order and fix every error:
\`\`\`bash
pnpm exec tsc --noEmit
pnpm exec biome check --write ${filesExpanded}
pnpm exec biome check ${filesExpanded}
${pkgTestCmd}
\`\`\`
Do not write refactor-report.md until all four pass.

Write refactor-report.md to ${taskDir}/
Follow your system prompt exactly.`;

    runAgent(
      "ag-06-refactor",
      refactorPrompt,
      path.join(taskDir, "refactor-output.md"),
      0,
      cfg.pipelineDir,
    );

    if (!fs.existsSync(path.join(taskDir, "refactor-report.md"))) {
      halt(
        "Refactor agent did not write refactor-report.md",
        "AG-06",
        `Task: ${task.id} — refactor-report.md not found`,
      );
    }
  }

  // Re-run hard gate regardless of whether agent ran
  log("Re-running hard gate after refactor...");
  let refactorFailures = verifyImplementation(filesInScopeJson, cfg.repoRoot);
  if (refactorFailures) {
    refactorFailures = tryFixer(
      cfg,
      task,
      taskDir,
      "Refactor broke tsc or tests",
      "AG-06",
      refactorFailures,
      filesInScopeJson,
    );
    if (refactorFailures) {
      halt(
        `Refactor broke tsc or tests on task ${task.id}`,
        "AG-06",
        `Task: ${task.id}\n${refactorFailures}`,
      );
    }
  }

  fs.writeFileSync(refactorVerifiedFile, "refactor-verified");
  recordTaskMetrics(
    cfg.pipelineDir,
    task.id,
    task.title,
    "refactor",
    Math.floor(Date.now() / 1000) - refactorStart,
    1,
    "pass",
    cfg.phase,
    cfg.phaseStartedAt,
  );

  // Post-refactor health check + delta
  log("Code health (post-refactor):");
  runCodeHealthChecks(
    cfg.repoRoot,
    cfg.pipelineDir,
    task.id,
    taskDir,
    filesInScopeJson,
    "",
    true,
  );
  writeRefactorDelta(taskDir, cfg.pipelineDir, task.id);

  log("REFACTOR phase: PASS");
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function readPreRefactorComplexCount(taskDir: string): number {
  try {
    const report = JSON.parse(
      fs.readFileSync(path.join(taskDir, "health-report-pre.json"), "utf8"),
    ) as { complex_functions?: unknown[] };
    return report.complex_functions?.length ?? 99;
  } catch {
    return 99;
  }
}

function readPreRefactorDupPct(taskDir: string): number {
  try {
    const report = JSON.parse(
      fs.readFileSync(path.join(taskDir, "health-report-pre.json"), "utf8"),
    ) as { duplication_pct?: number };
    return report.duplication_pct ?? 99;
  } catch {
    return 99;
  }
}

function buildComplexityBlock(taskDir: string): string {
  try {
    const report = JSON.parse(
      fs.readFileSync(path.join(taskDir, "health-report-pre.json"), "utf8"),
    ) as { complex_functions?: Array<{ file: string; line: number; score?: number }> };
    const fns = report.complex_functions ?? [];
    if (fns.length === 0) return "";

    const lines = [
      "The following functions exceeded the cognitive complexity threshold (max: 10).",
      "These are your primary refactor targets — reduce their complexity score:",
      "",
    ];
    for (const fn of fns) {
      const scoreStr = fn.score ? ` — complexity score ${fn.score}` : "";
      lines.push(`  ${fn.file}:${fn.line}${scoreStr}`);
    }
    return lines.join("\n");
  } catch {
    return "";
  }
}
