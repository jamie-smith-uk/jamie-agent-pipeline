import fs from "node:fs";
import path from "node:path";
import { log } from "../config.js";
import { runAgent } from "../agent.js";
import { halt } from "../halt.js";
import { reportPasses } from "../gates.js";
import { recordTaskMetrics } from "../metrics.js";
import type { PipelineConfig, Task } from "../types.js";

// ── runMigrationPhase() ───────────────────────────────────────────────────────

/**
 * MIGRATION phase (conditional): AG-05 validates and runs migration files.
 */
export function runMigrationPhase(
  cfg: PipelineConfig,
  task: Task,
  taskDir: string,
): void {
  if (!hasMigration(task.files_in_scope)) {
    return;
  }

  const migrationVerifiedFile = path.join(taskDir, "migration-verified.txt");

  if (fs.existsSync(migrationVerifiedFile)) {
    log("MIGRATION phase already complete — skipping");
    return;
  }

  const migrationStart = Math.floor(Date.now() / 1000);
  log("MIGRATION phase — AG-05 Migration...");

  const taskSpec = `<task-spec>\n${JSON.stringify(task, null, 2)}\n</task-spec>`;

  const migrationPrompt = `You are AG-05 Migration for {PROJECT_NAME}.

The Developer has written migration files for task ${task.id}.
Task spec:
${taskSpec}

Validate every migration file in files_in_scope.
Run the migration and its rollback against the test database.
Write migration-report.md to ${taskDir}/
Follow your system prompt exactly.`;

  runAgent(
    "ag-05-migration",
    migrationPrompt,
    path.join(taskDir, "migration-output.md"),
    0,
    cfg.pipelineDir,
  );

  const migrationReport = path.join(taskDir, "migration-report.md");
  if (!fs.existsSync(migrationReport)) {
    halt(
      "Migration agent did not write migration-report.md",
      "AG-05",
      `Task: ${task.id} — migration-report.md not found`,
    );
  }

  if (!reportPasses(migrationReport)) {
    halt(
      `Migration failed for task ${task.id}`,
      "AG-05",
      fs.readFileSync(migrationReport, "utf8"),
    );
  }

  fs.writeFileSync(migrationVerifiedFile, "migration-verified");
  recordTaskMetrics(
    cfg.pipelineDir,
    task.id,
    task.title,
    "migration",
    Math.floor(Date.now() / 1000) - migrationStart,
    1,
    "pass",
    cfg.phase,
    cfg.phaseStartedAt,
  );
  log("MIGRATION phase: PASS");
}

export function hasMigration(filesInScope: string[]): boolean {
  return filesInScope.some(
    (f) => f.toLowerCase().includes("migration") || f.startsWith("migrations/"),
  );
}
