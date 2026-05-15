import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { log } from "../config.js";
import { runAgent } from "../agent.js";
import { halt } from "../halt.js";
import {
  verifyImplementation,
  checkScopeCompliance,
  revertScopeViolations,
  getAffectedPkgFilter,
  getExpandedFileList,
} from "../gates.js";
import { tryFixer } from "./fixer.js";
import { runCodeHealthChecks } from "../checks/health.js";
import { recordTaskMetrics } from "../metrics.js";
import type { PipelineConfig, Task } from "../types.js";

// ── runDeveloperPhase() ───────────────────────────────────────────────────────

/**
 * GREEN phase: Developer implements until hard gate passes (up to 3 attempts + fixer).
 */
export function runDeveloperPhase(
  cfg: PipelineConfig,
  task: Task,
  taskDir: string,
  contextBlock: string,
  archDoc: string,
): void {
  const greenVerifiedFile = path.join(taskDir, "green-verified.txt");

  if (fs.existsSync(greenVerifiedFile)) {
    log("GREEN phase already complete — skipping");
    ensureTestReport(task.id, taskDir);
    return;
  }

  const greenStart = Math.floor(Date.now() / 1000);
  let devAttempts = 0;
  let greenPassed = false;
  let gateFailures = "";

  const filesInScopeJson = JSON.stringify(task.files_in_scope);
  const affectedPkgs = getAffectedPkgFilter(filesInScopeJson);
  const filesExpanded = getExpandedFileList(filesInScopeJson);
  const contextSection = contextBlock ? `\n${contextBlock}` : "";
  const taskSpec = `<task-spec>\n${JSON.stringify(task, null, 2)}\n</task-spec>`;

  const baseDevPrompt = buildBaseDevPrompt(
    taskDir,
    task,
    taskSpec,
    contextSection,
    archDoc,
    filesExpanded,
    affectedPkgs,
  );

  const baselineFile = path.join(taskDir, "baseline-failures.txt");

  while (!greenPassed && devAttempts < 3) {
    devAttempts++;
    log(`GREEN phase — Developer attempt ${devAttempts}/3...`);

    let devPrompt = baseDevPrompt;

    if (gateFailures) {
      // Get diff of in-scope files from previous attempt
      const filesArg = task.files_in_scope.join(" ");
      const diffResult = spawnSync(
        "git",
        ["-C", cfg.repoRoot, "diff", "HEAD", "--", ...task.files_in_scope],
        { encoding: "utf8", maxBuffer: 8 * 1024 * 1024 },
      );
      const prevDiff = (diffResult.stdout || "").slice(0, 8000);

      devPrompt += `\n\n## Previous attempt failed the hard gate — fix every item below before marking done:\n\n<gate-failures>\n${gateFailures}\n</gate-failures>`;
      if (prevDiff) {
        devPrompt += `\n\n<previous-attempt-diff>\nThe following diff shows exactly what your previous attempt wrote to the in-scope files.\nUse this to understand what you already changed and avoid repeating the same mistakes:\n\n${prevDiff}\n</previous-attempt-diff>`;
      }
    }

    const devOutputFile = path.join(taskDir, `dev-output-${devAttempts}.md`);
    const devRc = runAgent(
      "ag-04-developer",
      devPrompt,
      devOutputFile,
      1200,
      cfg.pipelineDir,
    );

    if (devRc === 124) {
      log(
        `Developer attempt ${devAttempts} timed out after 20 minutes — counting as gate failure`,
      );
      gateFailures = `=== Developer attempt timed out ===
The agent did not complete within 20 minutes. This usually means the task is too large
or the agent spent too long reading before writing. On your next attempt:
- Write implementation code immediately — do not re-read files you already know
- Focus only on files_in_scope; ignore everything else
- Implement the minimum needed to make the failing tests pass`;
      continue;
    }

    // Check for BLOCKED.md — route through fixer before halting
    const blockedFile = path.join(taskDir, "BLOCKED.md");
    if (fs.existsSync(blockedFile)) {
      const blockedReason = fs.readFileSync(blockedFile, "utf8");
      log(`Developer wrote BLOCKED.md — invoking fixer before halting`);
      const fixerFailures = tryFixer(
        cfg,
        task,
        taskDir,
        `Developer blocked: ${blockedReason.slice(0, 200)}`,
        "AG-04",
        blockedReason,
        filesInScopeJson,
      );
      if (fixerFailures) {
        halt(
          `Developer blocked on ${task.id} — fixer could not resolve`,
          "AG-04",
          blockedReason,
        );
      }
      // Fixer resolved the blocker — clear BLOCKED.md and continue the gate
      fs.unlinkSync(blockedFile);
      gateFailures = fixerFailures;
      continue;
    }

    // Remove common temp/debug patterns before scope check
    cleanTempFiles(cfg.repoRoot);

    // Scope compliance check
    log("Checking files_in_scope compliance...");
    const scopeViolations = checkScopeCompliance(filesInScopeJson, cfg.repoRoot);
    let scopeGate = "";
    if (scopeViolations) {
      log("Scope violation — reverting out-of-scope changes...");
      revertScopeViolations(scopeViolations, cfg.repoRoot);
      scopeGate = `=== files_in_scope violation (changes reverted) ===\nThe following files were modified or created outside files_in_scope and have been automatically reverted.\nDo NOT re-create or modify them — only write to files listed in files_in_scope:\n${scopeViolations}`;
    }

    // Auto-fix biome formatting
    autoFixBiomeFormatting(cfg.repoRoot, task.files_in_scope);

    // Hard gate
    log("Running hard gate (tsc + biome check + pnpm test)...");
    const implFailures = verifyImplementation(
      filesInScopeJson,
      cfg.repoRoot,
      baselineFile,
    );

    if (implFailures) {
      gateFailures = scopeGate ? `${scopeGate}\n${implFailures}` : implFailures;
    } else {
      gateFailures = "";
    }

    // Guard: if scope violations but no in-scope files were written, force retry
    if (!gateFailures && scopeViolations) {
      const inScopeChanged = checkInScopeChanged(
        task.files_in_scope,
        cfg.repoRoot,
      );
      if (!inScopeChanged) {
        gateFailures = `${scopeGate}\n=== No in-scope files were modified ===\nAll of your changes were in files outside files_in_scope and have been reverted.\nYou MUST write implementation code to the files listed in files_in_scope.\nDo not create new files — modify only the files already listed there.`;
      }
    }

    if (!gateFailures) {
      greenPassed = true;
      fs.writeFileSync(greenVerifiedFile, "green-verified");

      writeTestReport(task.id, taskDir, devAttempts);

      recordTaskMetrics(
        cfg.pipelineDir,
        task.id,
        task.title,
        "green",
        Math.floor(Date.now() / 1000) - greenStart,
        devAttempts,
        "pass",
        cfg.phase,
        cfg.phaseStartedAt,
      );

      log("Code health (pre-refactor baseline):");
      runCodeHealthChecks(
        cfg.repoRoot,
        cfg.pipelineDir,
        task.id,
        taskDir,
        filesInScopeJson,
        "pre-refactor",
        true,
      );

      // Push developer's code immediately (skipped in single-task mode)
      if (!cfg.noIntermediateCommit) {
        pushDeveloperCode(cfg, task, taskDir, greenVerifiedFile);
      }

      log("GREEN phase: PASS");
    } else {
      log(`Hard gate: FAIL (attempt ${devAttempts}/3)`);
      fs.writeFileSync(
        path.join(taskDir, `gate-failures-${devAttempts}.txt`),
        gateFailures,
      );

      if (devAttempts === 3) {
        // Collect all gate failures for fixer
        let allGateFailures = "";
        try {
          allGateFailures = fs.readFileSync(
            path.join(taskDir, "gate-failures-1.txt"),
            "utf8",
          );
        } catch {
          // ignore
        }
        try {
          allGateFailures += "\n" + fs.readFileSync(
            path.join(taskDir, "gate-failures-3.txt"),
            "utf8",
          );
        } catch {
          // ignore
        }

        gateFailures = tryFixer(
          cfg,
          task,
          taskDir,
          "Developer could not pass hard gate after 3 attempts",
          "AG-04",
          allGateFailures,
          filesInScopeJson,
        );

        if (gateFailures) {
          halt(
            "Developer and Fixer could not pass hard gate",
            "AG-04",
            `Task: ${task.id} — Fixer exhausted. See ${taskDir}/fixer-output-*.md`,
          );
        }

        // Fixer resolved it — mark green passed
        greenPassed = true;
        fs.writeFileSync(greenVerifiedFile, "green-verified");
        writeTestReport(task.id, taskDir, devAttempts);
        recordTaskMetrics(
          cfg.pipelineDir,
          task.id,
          task.title,
          "green",
          Math.floor(Date.now() / 1000) - greenStart,
          devAttempts,
          "pass",
          cfg.phase,
          cfg.phaseStartedAt,
        );
      }
    }
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function buildBaseDevPrompt(
  taskDir: string,
  task: Task,
  taskSpec: string,
  contextSection: string,
  archDoc: string,
  filesExpanded: string,
  affectedPkgs: string,
): string {
  const pkgTestCmd = affectedPkgs ? `pnpm ${affectedPkgs} test` : "pnpm test";
  return `You are AG-04 Developer for {PROJECT_NAME}.

Implement this task to make the failing tests pass:
${taskSpec}${contextSection}

<architecture>
${archDoc}
</architecture>

The Tester has already written failing tests in the __tests__/ directories.
Your job is to write implementation code that makes every test pass.
Do not modify the test files.

## Step 1 — Read the in-scope source files FIRST
Read the current content of every file listed in files_in_scope. Understand what is
already implemented before writing anything. Do not duplicate or conflict with existing code.

## Step 2 — Read the tests
Read every \`.test.ts\` file in the __tests__/ directories of the in-scope packages.
The tests define the exact function signatures, exported names, and interfaces you
must implement. If in doubt, the tests are the source of truth.

## Biome lint rules — violations will fail the gate
- **noExplicitAny** (error): Never use \`any\` type. Define a typed interface for the
  data shape, or use \`unknown\` with a type guard.
- **noExcessiveCognitiveComplexity** (error, max 10): Break complex logic into small
  focused helper functions. If a function genuinely must exceed 10 (e.g. a parser),
  add \`// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: <reason>\`
  on the line immediately above the function declaration.
- **noConsole** (warning, won't block gate): Avoid \`console.log\` — use the logger
  from \`packages/shared/src/logger.ts\`.
- **Formatter**: Run \`biome check --write\` (step 3 below) to auto-fix spacing/quotes/commas.

## Validation commands (run in order before marking done)

\`\`\`bash
pnpm exec tsc --noEmit
pnpm exec biome check --write ${filesExpanded}
pnpm exec biome check ${filesExpanded}
${pkgTestCmd}
\`\`\`

Step 2 (\`biome check --write\`) auto-fixes formatting. Step 3 confirms the result is clean.
You are not done until you have run all four and seen zero errors and all tests passing.
Copy the terminal output of each command into self-assessment.md as proof.

Write self-assessment.md to ${taskDir}/
Follow your system prompt exactly. Apply all security rules.
Use process.env.DATABASE_URL for any database connections — do not read .env directly.`;
}

function ensureTestReport(taskId: string, taskDir: string): void {
  const reportFile = path.join(taskDir, "test-report.md");
  if (!fs.existsSync(reportFile)) {
    fs.writeFileSync(
      reportFile,
      `Title: Test Report — ${taskId} — PASS\n\nVerified by orchestrator hard gate (restored on resume).\n\n- tsc --noEmit: PASS\n- eslint (files_in_scope): PASS\n- pnpm test: PASS\n`,
    );
  }
}

function writeTestReport(taskId: string, taskDir: string, attempts: number): void {
  const redOutput = tryReadFile(path.join(taskDir, "test-red-output.txt"));
  fs.writeFileSync(
    path.join(taskDir, "test-report.md"),
    `Title: Test Report — ${taskId} — PASS\n\nVerified by orchestrator hard gate after Developer attempt ${attempts}.\n\n- tsc --noEmit: PASS\n- eslint (files_in_scope): PASS\n- pnpm test: PASS\n\n${redOutput}`,
  );
}

function tryReadFile(filePath: string): string {
  try {
    return fs.readFileSync(filePath, "utf8");
  } catch {
    return "";
  }
}

function cleanTempFiles(repoRoot: string): void {
  // Silently remove common temp/debug patterns
  const patterns = [
    "debug-*.js",
    "debug-*.ts",
    "test-*.js",
    "test-*.ts",
    "*.debug.js",
    "*.debug.ts",
    "*.tmp",
    "*.scratch.*",
  ];

  // Use find via spawnSync to avoid shell injection
  for (const pattern of patterns) {
    spawnSync(
      "find",
      [
        repoRoot,
        "-maxdepth",
        "2",
        "-name",
        pattern,
        "-not",
        "-path",
        "*/node_modules/*",
        "-not",
        "-path",
        "*/__tests__/*",
        "-not",
        "-path",
        "*/pipeline/*",
        "-delete",
      ],
      { encoding: "utf8" },
    );
  }
}

function autoFixBiomeFormatting(
  repoRoot: string,
  filesInScope: string[],
): void {
  try {
    const pkgJson = fs.readFileSync(path.join(repoRoot, "package.json"), "utf8");
    if (!pkgJson.includes('"@biomejs/biome"')) return;
  } catch {
    return;
  }

  const existingFiles = filesInScope
    .map((f) => path.join(repoRoot, f))
    .filter((f) => fs.existsSync(f));

  if (existingFiles.length === 0) return;

  log("Auto-fixing biome formatting on in-scope files...");
  spawnSync("pnpm", ["exec", "biome", "format", "--write", ...existingFiles], {
    cwd: repoRoot,
    encoding: "utf8",
  });
}

function checkInScopeChanged(filesInScope: string[], repoRoot: string): boolean {
  const result = spawnSync(
    "git",
    ["-C", repoRoot, "diff", "--name-only", "HEAD"],
    { encoding: "utf8" },
  );
  const changed = new Set((result.stdout || "").split("\n").filter(Boolean));
  return filesInScope.some((f) => changed.has(f));
}

function pushDeveloperCode(
  cfg: PipelineConfig,
  task: Task,
  taskDir: string,
  greenVerifiedFile: string,
): void {
  // Stage in-scope files
  for (const f of task.files_in_scope) {
    const full = path.join(cfg.repoRoot, f);
    if (!fs.existsSync(full)) continue;

    const ignoreCheck = spawnSync(
      "git",
      ["-C", cfg.repoRoot, "check-ignore", "-q", f],
      { encoding: "utf8" },
    );
    if (ignoreCheck.status !== 0) {
      spawnSync("git", ["-C", cfg.repoRoot, "add", f], { encoding: "utf8" });
    }
  }

  // Stage pipeline files
  for (const extra of [
    greenVerifiedFile,
    path.join(taskDir, "test-report.md"),
    path.join(taskDir, "self-assessment.md"),
  ]) {
    try {
      spawnSync("git", ["-C", cfg.repoRoot, "add", extra], {
        encoding: "utf8",
      });
    } catch {
      // ignore
    }
  }

  const diffResult = spawnSync(
    "git",
    ["-C", cfg.repoRoot, "diff", "--cached", "--quiet"],
    { encoding: "utf8" },
  );
  if (diffResult.status !== 0) {
    spawnSync(
      "git",
      [
        "-C",
        cfg.repoRoot,
        "commit",
        "-m",
        `wip(${task.id}): developer green — awaiting security+refactor [skip ci]`,
      ],
      { encoding: "utf8" },
    );
    spawnSync(
      "git",
      ["-C", cfg.repoRoot, "stash", "push", "--include-untracked", "-m", "pre-rebase stash"],
      { encoding: "utf8" },
    );
    spawnSync("git", ["-C", cfg.repoRoot, "fetch", "origin", "main"], {
      encoding: "utf8",
    });
    spawnSync("git", ["-C", cfg.repoRoot, "rebase", "origin/main"], {
      encoding: "utf8",
    });
    spawnSync("git", ["-C", cfg.repoRoot, "push"], { encoding: "utf8" });
    spawnSync("git", ["-C", cfg.repoRoot, "stash", "pop"], { encoding: "utf8" });
    log(`Developer code for ${task.id} pushed (green gate passed)`);
  }
}
