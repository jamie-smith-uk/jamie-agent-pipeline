import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { log } from "../config.js";
import { runAgent } from "../agent.js";
import type { PipelineConfig, Task } from "../types.js";

// ── runSplitterPhase() ────────────────────────────────────────────────────────

export function runSplitterPhase(cfg: PipelineConfig): void {
  const splitterOutput = path.join(cfg.pipelineDir, "splitter-output.md");

  if (fs.existsSync(splitterOutput)) {
    log("Ticket splitter already ran — skipping");
    return;
  }

  const manifestPath = path.join(cfg.pipelineDir, "task-manifest.json");
  const tasks = loadTasks(manifestPath);

  // Identify completed tasks (those with security-report.md that passes)
  const completeTasks = tasks.filter((t) => {
    const secReport = path.join(cfg.pipelineDir, t.id, "security-report.md");
    return fs.existsSync(secReport);
  });
  const completedIds = completeTasks.map((t) => t.id);

  log(
    `Ticket splitter — completed tasks: ${completedIds.length > 0 ? completedIds.join(", ") : "none"}`,
  );

  const incompleteTasks = tasks.filter((t) => !completedIds.includes(t.id));

  // Check if any incomplete task needs splitting
  const needsSplit = incompleteTasks.some(
    (t) =>
      t.estimated_complexity === "high" ||
      (t.acceptance_criteria?.length ?? 0) > 4 ||
      (t.files_in_scope?.length ?? 0) > 3,
  );

  if (!needsSplit) {
    log("Ticket splitter — all tasks already small, skipping");
    fs.writeFileSync(
      splitterOutput,
      "All tasks within size thresholds — no splitting needed.",
    );
    commitSplitterOutput(cfg);
    return;
  }

  log("Ticket splitter — breaking down large tasks...");

  // Write incomplete manifest for the splitter agent
  const incompletePath = path.join(cfg.pipelineDir, "splitter-input.json");
  const completePath = path.join(cfg.pipelineDir, "splitter-complete-tasks.json");

  fs.writeFileSync(incompletePath, JSON.stringify(incompleteTasks, null, 2));
  fs.writeFileSync(completePath, JSON.stringify(completeTasks, null, 2));

  // Read ag01-output for PRD summary (first 3000 chars)
  const ag01Output = path.join(cfg.pipelineDir, "ag01-output.md");
  let prdSummary = "(no architect output)";
  if (fs.existsSync(ag01Output)) {
    prdSummary = fs.readFileSync(ag01Output, "utf8").slice(0, 3000);
  }

  const splitPrompt = `You are AG-09 Ticket Splitter for {PROJECT_NAME}.

Your input manifest (incomplete tasks only): ${incompletePath}
Pipeline directory: ${cfg.pipelineDir}

PRD summary:
${prdSummary}

Read ${incompletePath}. Split any tasks that exceed the thresholds in your system
prompt. Rewrite ${incompletePath} in place with the split tasks.
Write splitter-output.md to ${cfg.pipelineDir}/splitter-output.md.`;

  runAgent(
    "ag-09-splitter",
    splitPrompt,
    path.join(cfg.pipelineDir, "splitter-agent-log.md"),
    300,
    cfg.pipelineDir,
  );

  // Merge complete tasks back at front, split tasks at end
  const updatedIncomplete = loadTasks(incompletePath);
  const merged = [...completeTasks, ...updatedIncomplete];
  fs.writeFileSync(manifestPath, JSON.stringify(merged, null, 2));

  log("Ticket splitter complete");

  commitSplitterOutput(cfg);
}

function loadTasks(manifestPath: string): Task[] {
  const raw = JSON.parse(fs.readFileSync(manifestPath, "utf8")) as
    | Task[]
    | { tasks?: Task[]; task_order?: Task[] };
  const tasks = Array.isArray(raw)
    ? raw
    : (raw.tasks ?? raw.task_order ?? []);
  return tasks.filter((t): t is Task => typeof t === "object" && t !== null);
}

function commitSplitterOutput(cfg: PipelineConfig): void {
  const { repoRoot, pipelineDir, phase } = cfg;

  // Stage splitter output files
  const filesToAdd = [
    `pipeline/phase-${phase}/splitter-output.md`,
    `pipeline/phase-${phase}/splitter-agent-log.md`,
    `pipeline/phase-${phase}/task-manifest.json`,
  ];

  for (const f of filesToAdd) {
    spawnSync("git", ["-C", repoRoot, "add", f], { encoding: "utf8" });
  }

  // Check if there's anything to commit
  const diffResult = spawnSync(
    "git",
    ["-C", repoRoot, "diff", "--cached", "--quiet"],
    { encoding: "utf8" },
  );

  if (diffResult.status !== 0) {
    spawnSync(
      "git",
      [
        "-C",
        repoRoot,
        "commit",
        "-m",
        `chore(pipeline): phase ${phase} splitter output [skip ci]`,
      ],
      { encoding: "utf8" },
    );
    spawnSync(
      "git",
      ["-C", repoRoot, "stash", "push", "--include-untracked", "-m", "pre-rebase stash"],
      { encoding: "utf8" },
    );
    spawnSync("git", ["-C", repoRoot, "fetch", "origin", "main"], {
      encoding: "utf8",
    });
    spawnSync("git", ["-C", repoRoot, "rebase", "origin/main"], {
      encoding: "utf8",
    });
    spawnSync("git", ["-C", repoRoot, "push"], { encoding: "utf8" });
    spawnSync("git", ["-C", repoRoot, "stash", "pop"], { encoding: "utf8" });
    log("Splitter output pushed");
  }
}
