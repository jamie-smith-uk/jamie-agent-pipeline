import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { log } from "../config.js";
import { runAgent } from "../agent.js";
import { halt } from "../halt.js";
import { verifyImplementation } from "../gates.js";
import { tryFixer } from "./fixer.js";
import { checkTesterTrajectory } from "../checks/trajectory.js";
import { recordTaskMetrics } from "../metrics.js";
import type { PipelineConfig, Task } from "../types.js";

// ── runTesterPhase() ──────────────────────────────────────────────────────────

/**
 * RED phase: Tester writes failing tests.
 * Returns true if the phase ran (false if already complete).
 */
export function runTesterPhase(
  cfg: PipelineConfig,
  task: Task,
  taskDir: string,
  contextBlock: string,
): void {
  const testsWrittenFile = path.join(taskDir, "tests-written.txt");

  if (fs.existsSync(testsWrittenFile)) {
    log("RED phase already complete — skipping");
    return;
  }

  const redStart = Math.floor(Date.now() / 1000);
  log("RED phase — Tester writing failing tests...");

  const taskSpec = `<task-spec>\n${JSON.stringify(task, null, 2)}\n</task-spec>`;
  const contextSection = contextBlock ? `\n${contextBlock}` : "";

  const redPrompt = `You are AG-03 Tester for {PROJECT_NAME}.

This is the RED phase of TDD. The Developer has not yet written implementation code.

Write the test suite for task ${task.id} that defines the expected behaviour.
Task spec:
${taskSpec}${contextSection}

Write test files to the __tests__/ directories as normal.
Tests will fail right now because there is no implementation — that is correct and expected.

Time budget: complete the RED phase in under 5 minutes. Read only the files
directly listed in files_in_scope and their immediate imports. Do not explore
the entire codebase — the task spec and build context contain everything needed.

Do NOT write implementation code.
Do NOT write test-report.md — the orchestrator writes that.
After writing all test files, write the single line 'tests-written' to:
  ${taskDir}/tests-written.txt

Follow your system prompt exactly.`;

  runAgent(
    "ag-03-tester",
    redPrompt,
    path.join(taskDir, "tester-red-output.md"),
    0,
    cfg.pipelineDir,
  );

  if (!fs.existsSync(testsWrittenFile)) {
    halt(
      "Tester did not confirm tests written",
      "AG-03",
      `Task: ${task.id} — tests-written.txt not found after RED phase`,
    );
  }

  // Verify tests fail before implementation (RED check)
  log("Confirming tests fail before implementation (RED check)...");
  const testResult = spawnSync("pnpm", ["test"], {
    cwd: cfg.repoRoot,
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024,
  });

  const redOutput = `${testResult.stdout || ""}${testResult.stderr || ""}`;
  fs.writeFileSync(path.join(taskDir, "test-red-output.txt"), redOutput);

  if (testResult.status === 0) {
    log(
      "WARNING: Tests pass before implementation — verify tests have meaningful assertions",
    );
  } else {
    log("RED confirmed — tests fail as expected");
  }

  // Sanity check: if every new test file shows 0 tests run (load error), halt early
  const newTestFilesResult = spawnSync(
    "git",
    ["-C", cfg.repoRoot, "diff", "--name-only", "HEAD"],
    { encoding: "utf8" },
  );
  const newTestFiles = (newTestFilesResult.stdout || "")
    .split("\n")
    .filter((f) => f.endsWith(".test.ts"));

  if (newTestFiles.length > 0) {
    let zeroTestCount = 0;
    let nonzeroTestCount = 0;

    for (const tf of newTestFiles) {
      const tfBase = path.basename(tf);
      // Check if this test file shows "(0 test)" in the red output
      if (new RegExp(`${escapeRegex(tfBase)}.*\\(0 test\\)`).test(redOutput)) {
        zeroTestCount++;
      } else {
        nonzeroTestCount++;
      }
    }

    if (zeroTestCount > 0 && nonzeroTestCount === 0) {
      log(
        "ERROR: All new test files ran 0 tests — likely a load error (missing vitest import, syntax error, etc.)",
      );
      log(`Test files with 0 tests: ${zeroTestCount}`);
      log(`Check ${taskDir}/test-red-output.txt for details`);

      // Try fixer to recover from broken test files
      const fixerFailures = tryFixer(
        cfg,
        task,
        taskDir,
        "Tester produced broken test files (0 tests ran)",
        "AG-03",
        `Task: ${task.id} — all new test files loaded with 0 tests. Check for missing 'import { describe, it, expect } from "vitest"'.`,
        JSON.stringify(task.files_in_scope),
      );

      if (fixerFailures) {
        halt(
          "Tester produced broken test files (0 tests ran)",
          "AG-03",
          `Task: ${task.id} — all new test files loaded with 0 tests. Fixer also failed. Check test files for import errors.`,
        );
      }
    }
  }

  // Capture baseline failing test IDs
  captureBaselineFailures(redOutput, path.join(taskDir, "baseline-failures.txt"));

  // Trajectory check
  checkTesterTrajectory(
    cfg.repoRoot,
    taskDir,
    testsWrittenFile,
    task.acceptance_criteria.length,
  );

  recordTaskMetrics(
    cfg.pipelineDir,
    task.id,
    task.title,
    "red",
    Math.floor(Date.now() / 1000) - redStart,
    1,
    "pass",
    cfg.phase,
    cfg.phaseStartedAt,
  );
}

function captureBaselineFailures(redOutput: string, baselinePath: string): void {
  const failFiles = new Set(
    [...redOutput.matchAll(/^\s*FAIL\s+(\S+)/gm)].map((m) => m[1]),
  );
  const failTests = new Set(
    [...redOutput.matchAll(/^\s*×\s+(.+?)\s+\d+ms/gm)].map((m) => m[1]),
  );
  const baseline = [...new Set([...failFiles, ...failTests])].sort();
  fs.writeFileSync(
    baselinePath,
    baseline.length > 0 ? baseline.join("\n") + "\n" : "",
  );
  log(`Baseline: ${baseline.length} pre-existing failure(s) recorded.`);
}

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
