#!/usr/bin/env node

/**
 * {PROJECT_NAME} Pipeline Orchestrator — TypeScript implementation.
 *
 * Usage: npx tsx orchestrator/src/index.ts --phase 1
 *
 * This is the canonical orchestrator. orchestrator/run-phase.sh is deprecated.
 */

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

import { buildConfig, log } from "./config.js";
import { HaltError } from "./types.js";
import { writeHaltAndExit } from "./halt.js";
import { reportPasses } from "./gates.js";
import { halt } from "./halt.js";
import { buildContextBlock, buildArchDocBlock, extractPhasePrd } from "./context.js";
import { runArchitectPhase, loadManifest } from "./phases/architect.js";
import { runSplitterPhase } from "./phases/splitter.js";
import { runTesterPhase } from "./phases/tester.js";
import { runDeveloperPhase } from "./phases/developer.js";
import { runMigrationPhase } from "./phases/migration.js";
import { runRefactorPhase } from "./phases/refactor.js";
import { runSecurityPhase } from "./phases/security.js";
import { commitTask } from "./phases/commit.js";
import { runSmokeTests } from "./smoke.js";
import { writeHealthSummary, writeMetricsSummary } from "./metrics.js";

// ── Arg parsing ───────────────────────────────────────────────────────────────

function parseArgs(): { phase: string } {
  const args = process.argv.slice(2);

  if (args.includes("--help") || args.includes("-h")) {
    console.log("Usage: npx tsx orchestrator/src/index.ts --phase <N>");
    console.log("");
    console.log("Options:");
    console.log("  --phase N        Phase number to run");
    console.log("");
    console.log("Environment variables:");
    console.log("  SKIP_ARCHITECT=1   Skip AG-01, AG-02, and human gate");
    console.log("  ARCHITECT_ONLY=1   Run only AG-01 and AG-02, then exit");
    process.exit(0);
  }

  let phase = "";
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--phase" && args[i + 1]) {
      phase = args[i + 1];
      i++;
    } else if (args[i]?.startsWith("--phase=")) {
      phase = args[i].slice("--phase=".length);
    }
  }

  if (!phase) {
    console.error("Usage: npx tsx orchestrator/src/index.ts --phase 1");
    process.exit(1);
  }

  return { phase };
}

// ── Pre-flight biome check ────────────────────────────────────────────────────

function runPreflightBiomeCheck(repoRoot: string): void {
  log("Pre-flight: pnpm exec biome check packages/...");
  const result = spawnSync("pnpm", ["exec", "biome", "check", "packages/"], {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
  });
  if (result.status !== 0) {
    console.error("Pre-flight biome check failed:");
    console.error(result.stdout);
    console.error(result.stderr);
    process.exit(1);
  }
  log("Pre-flight: biome OK");
}

// ── Phase gate (previous phase must pass) ─────────────────────────────────────

function checkPreviousPhase(repoRoot: string, phase: string): void {
  const phaseNum = Number.parseInt(phase, 10);
  if (Number.isNaN(phaseNum) || phaseNum <= 1) return;

  const prevPhase = phaseNum - 1;
  const prevReport = path.join(
    repoRoot,
    "pipeline",
    `phase-${prevPhase}`,
    "validation-report.md",
  );

  if (!fs.existsSync(prevReport)) {
    halt(
      `Phase ${prevPhase} not complete`,
      "orchestrator",
      `validation-report.md not found for phase ${prevPhase}`,
    );
  }

  if (!reportPasses(prevReport)) {
    halt(
      `Phase ${prevPhase} did not pass validation`,
      "orchestrator",
      `validation-report.md for phase ${prevPhase} does not contain a PASS title`,
    );
  }
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const { phase } = parseArgs();
  const cfg = buildConfig(phase);

  log("========================================");
  log(`{PROJECT_NAME} Pipeline — Phase ${phase}`);
  log("========================================");

  // Phase gate check
  checkPreviousPhase(cfg.repoRoot, phase);

  // Extract PRD content for this phase
  const phasePrdContent = extractPhasePrd(cfg.repoRoot, phase);
  const archDoc = buildArchDocBlock(
    cfg.repoRoot,
    cfg.archDocMaxChars,
    phasePrdContent,
  );

  // ── Architect phase ─────────────────────────────────────────────────────────
  if (process.env.SKIP_ARCHITECT === "1") {
    log("SKIP_ARCHITECT=1 — skipping AG-01, AG-02, and human gate");
    const manifestPath = path.join(cfg.pipelineDir, "task-manifest.json");
    if (!fs.existsSync(manifestPath)) {
      halt(
        "task-manifest.json not found",
        "orchestrator",
        `SKIP_ARCHITECT=1 requires task-manifest.json to already exist in ${cfg.pipelineDir}/`,
      );
    }
    log("task-manifest.json found — proceeding to task execution");
  } else {
    await runArchitectPhase(cfg, phasePrdContent, archDoc);
  }

  // ── Splitter phase ──────────────────────────────────────────────────────────
  runSplitterPhase(cfg);

  // ── Task loop ───────────────────────────────────────────────────────────────
  const tasks = loadManifest(cfg.pipelineDir);

  for (const task of tasks) {
    const taskDir = path.join(cfg.pipelineDir, task.id);
    fs.mkdirSync(taskDir, { recursive: true });

    const secReport = path.join(taskDir, "security-report.md");

    // Task is fully complete once security has passed
    if (fs.existsSync(secReport) && reportPasses(secReport)) {
      log(`Task ${task.id} already complete — skipping`);
      continue;
    }

    log("");
    log("========================================");
    log(`Task: ${task.id} — ${task.title}`);
    log("========================================");

    // Build context snapshot for this task's agents
    const contextBlock = buildContextBlock(cfg.pipelineDir, cfg.contextMaxChars);

    // ── RED phase ─────────────────────────────────────────────────────────────
    runTesterPhase(cfg, task, taskDir, contextBlock);

    // ── GREEN phase ───────────────────────────────────────────────────────────
    runDeveloperPhase(cfg, task, taskDir, contextBlock, archDoc);

    // ── MIGRATION phase (conditional) ─────────────────────────────────────────
    runMigrationPhase(cfg, task, taskDir);

    // ── REFACTOR phase ────────────────────────────────────────────────────────
    runRefactorPhase(cfg, task, taskDir, contextBlock);

    // ── SECURITY phase (includes mutation testing for security-sensitive tasks)
    runSecurityPhase(cfg, task, taskDir, contextBlock);

    // ── Context + commit ──────────────────────────────────────────────────────
    commitTask(cfg, task, taskDir);

    // ── Record task metrics ───────────────────────────────────────────────────
    // (individual phase metrics already recorded; task total is updated by recordTaskMetrics)
  }

  // ── Health summary ──────────────────────────────────────────────────────────
  const completedAt = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
  writeHealthSummary(cfg.pipelineDir, phase, completedAt);
  if (fs.existsSync(path.join(cfg.pipelineDir, "health-summary.md"))) {
    log(`Health summary written to pipeline/phase-${phase}/health-summary.md`);
  }

  // ── Smoke tests ─────────────────────────────────────────────────────────────
  log("");
  log("========================================");
  log(`Phase ${phase} validation — smoke-test gate`);
  log("========================================");

  runSmokeTests(cfg, tasks);

  // ── Phase metrics summary ───────────────────────────────────────────────────
  writeMetricsSummary(cfg.pipelineDir, completedAt);

  const metricsFile = path.join(cfg.pipelineDir, "metrics.json");
  if (fs.existsSync(metricsFile) && fs.statSync(metricsFile).size > 0) {
    printMetricsSummary(metricsFile);
  }

  // Clean up HALT.md from previous runs
  const haltFile = path.join(cfg.repoRoot, "HALT.md");
  if (fs.existsSync(haltFile)) {
    fs.unlinkSync(haltFile);
  }
}

function printMetricsSummary(metricsFile: string): void {
  try {
    const data = JSON.parse(fs.readFileSync(metricsFile, "utf8")) as {
      summary?: {
        total_duration_s?: number;
        tasks_completed?: number;
        pass_at_1_rate?: number;
        high_retry_tasks?: string[];
        top_security_findings?: string[];
        health?: {
          avg_coverage_pct?: number | null;
          avg_duplication_pct?: number | null;
          total_complex_fns?: number;
        };
      };
    };

    const s = data.summary ?? {};
    log("Metrics summary:");
    log(`  Total time : ${s.total_duration_s ?? 0}s`);
    log(`  Tasks done : ${s.tasks_completed ?? 0}`);
    log(`  Pass@1 rate: ${s.pass_at_1_rate ?? 0}%  ← % of tasks needing no retries`);

    if ((s.high_retry_tasks?.length ?? 0) > 0) {
      log(`  High-retry : ${s.high_retry_tasks?.join(", ")}  ← review task specs`);
    }

    if ((s.top_security_findings?.length ?? 0) > 0) {
      log("  Top security findings:");
      for (const finding of s.top_security_findings ?? []) {
        log(`    - ${finding}`);
      }
    }

    const h = s.health ?? {};
    if (h.avg_coverage_pct != null || h.avg_duplication_pct != null || (h.total_complex_fns ?? 0) > 0) {
      log("  Code health:");
      if (h.avg_coverage_pct != null) {
        log(`    Coverage   : ${h.avg_coverage_pct}% avg`);
      }
      if (h.avg_duplication_pct != null) {
        log(`    Duplication: ${h.avg_duplication_pct}% avg`);
      }
      if ((h.total_complex_fns ?? 0) > 0) {
        log(`    Complex fns: ${h.total_complex_fns} functions > 20 lines`);
      }
    }
  } catch {
    // ignore
  }
}

// ── Run ───────────────────────────────────────────────────────────────────────

// Build a minimal config for error reporting (phase may not yet be known)
let currentPhase = "?";
let currentRepoRoot = "";

try {
  const { phase } = parseArgs();
  currentPhase = phase;
  const scriptDir = path.dirname(new URL(import.meta.url).pathname);
  currentRepoRoot = path.resolve(scriptDir, "../..");
} catch {
  // ignore — will fail properly in main()
}

main().catch((err: unknown) => {
  if (err instanceof HaltError) {
    writeHaltAndExit(err, currentRepoRoot, currentPhase);
  }
  console.error("Unexpected error:", err);
  process.exit(1);
});
