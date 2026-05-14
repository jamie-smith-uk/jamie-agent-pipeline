import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { log } from "./config.js";
import { halt } from "./halt.js";
import { runAgent } from "./agent.js";
import { checkScopeCompliance, revertScopeViolations } from "./gates.js";
import type { PipelineConfig, Task } from "./types.js";

interface SmokeResults {
  tscExit: number;
  tscOut: string;
  biomeExit: number;
  biomeOut: string;
  testExit: number;
  testOut: string;
}

function runSmokeChecks(repoRoot: string): SmokeResults {
  const tscResult = spawnSync("pnpm", ["exec", "tsc", "--noEmit"], {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
  });
  const tscOut = `${tscResult.stdout || ""}${tscResult.stderr || ""}`;
  const tscExit = tscResult.status ?? 0;
  log(`  tsc:   ${tscExit === 0 ? "PASS" : "FAIL"}`);

  const biomeResult = spawnSync(
    "pnpm",
    ["exec", "biome", "check", "packages/"],
    {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
    },
  );
  const biomeOut = `${biomeResult.stdout || ""}${biomeResult.stderr || ""}`;
  const biomeExit = biomeResult.status ?? 0;
  log(`  biome: ${biomeExit === 0 ? "PASS" : "FAIL"}`);

  const testResult = spawnSync("pnpm", ["test"], {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024,
  });
  const testOut = `${testResult.stdout || ""}${testResult.stderr || ""}`;
  const testExit = testResult.status ?? 0;
  log(`  tests: ${testExit === 0 ? "PASS" : "FAIL"}`);

  return { tscExit, tscOut, biomeExit, biomeOut, testExit, testOut };
}

// ── runSmokeTests() ───────────────────────────────────────────────────────────

/**
 * Runs end-of-phase smoke tests (tsc + biome + pnpm test).
 * Up to 2 attempts, with a Developer fix cycle between them.
 * Writes validation-report.md and tags the git repo on success.
 */
export function runSmokeTests(
  cfg: PipelineConfig,
  tasks: Task[],
): void {
  const maxValAttempts = 2;
  let valAttempts = 0;

  while (true) {
    valAttempts++;
    log(
      `Running tsc, biome, and pnpm test (attempt ${valAttempts}/${maxValAttempts})...`,
    );
    const results = runSmokeChecks(cfg.repoRoot);

    if (
      results.tscExit === 0 &&
      results.biomeExit === 0 &&
      results.testExit === 0
    ) {
      // SUCCESS
      fs.writeFileSync(
        path.join(cfg.pipelineDir, "validation-report.md"),
        `# Phase ${cfg.phase} Validation — PASS\n\n**Verdict: PASS**\n\nAll smoke-test checks passed.\n\n## Results\n\n- tsc --noEmit: PASS\n- biome check packages/: PASS\n- pnpm test: PASS\n\n## Test output\n\n\`\`\`\n${results.testOut}\n\`\`\`\n`,
      );

      // Create git tag
      const tagResult = spawnSync(
        "git",
        ["-C", cfg.repoRoot, "tag", `phase-${cfg.phase}-complete`],
        { encoding: "utf8" },
      );
      if (tagResult.status === 0) {
        log(`Git tag phase-${cfg.phase}-complete created`);
      } else {
        log("Git tag already exists — skipping");
      }

      process.stdout.write("");
      log("");
      log("========================================");
      log(`Phase ${cfg.phase}: COMPLETE`);
      log("========================================");
      return;
    }

    // Build failure summary
    let valFailures = "";
    if (results.tscExit !== 0) valFailures += `=== tsc ===\n${results.tscOut}\n\n`;
    if (results.biomeExit !== 0) valFailures += `=== biome ===\n${results.biomeOut}\n\n`;
    if (results.testExit !== 0) valFailures += `=== pnpm test ===\n${results.testOut}\n\n`;

    fs.writeFileSync(
      path.join(cfg.pipelineDir, "validation-report.md"),
      `# Phase ${cfg.phase} Validation — FAIL\n\n**Verdict: FAIL**\n\nOne or more smoke-test checks failed at the phase level. Every task's individual\nhard gate passed, so this is likely a cross-task integration issue. Fix the\nfailures below — do not modify test files.\n\n## Failures\n\n${valFailures}\n`,
    );

    if (valAttempts >= maxValAttempts) {
      halt(
        `Phase ${cfg.phase} smoke-test gate failed after ${valAttempts} attempt(s)`,
        "validation",
        `See pipeline/phase-${cfg.phase}/validation-report.md for details.`,
      );
    }

    // Developer fix cycle
    log(`Smoke-test gate FAIL — running Developer fix cycle ${valAttempts}...`);

    // Collect all files across all tasks
    const allFiles = [
      ...new Map(
        tasks.flatMap((t) => t.files_in_scope).map((f) => [f, f]),
      ).values(),
    ];
    const allFilesJson = JSON.stringify(allFiles);

    const valFixPrompt = `You are AG-04 Developer for {PROJECT_NAME}.

The phase ${cfg.phase} smoke-test gate failed. Fix every error listed below. These checks
all passed per-task during implementation, so this is likely a cross-task
integration issue.

<gate-failures>
${valFailures}
</gate-failures>

Files in scope across all phase ${cfg.phase} tasks:
${allFilesJson}

Rules:
- Read the failing files before changing anything.
- Fix only source files — never modify test files.
- Run \`pnpm exec tsc --noEmit\`, \`pnpm exec biome check --write <files>\`, and
  \`pnpm test\` yourself before marking done. All three must pass.
- Apply all security rules. Do not introduce new issues.`;

    runAgent(
      "ag-04-developer",
      valFixPrompt,
      path.join(cfg.pipelineDir, `val-fix-dev-${valAttempts}.md`),
      900,
      cfg.pipelineDir,
    );

    const scopeViolations = checkScopeCompliance(allFilesJson, cfg.repoRoot);
    if (scopeViolations) {
      log("Reverting out-of-scope changes from validation fix...");
      revertScopeViolations(scopeViolations, cfg.repoRoot);
    }
  }
}
