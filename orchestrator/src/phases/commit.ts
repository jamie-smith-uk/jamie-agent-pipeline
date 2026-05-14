import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { log } from "../config.js";
import type { PipelineConfig, Task } from "../types.js";

// ── commitTask() ──────────────────────────────────────────────────────────────

/**
 * Updates context.md and commits the task's changes to git.
 */
export function commitTask(
  cfg: PipelineConfig,
  task: Task,
  taskDir: string,
): void {
  const filesInScope = task.files_in_scope;
  const filesInScopeJson = JSON.stringify(filesInScope);

  // ── Context accumulation ────────────────────────────────────────────────────
  log("Updating build context...");
  const filesList = filesInScope.join(", ");

  // Extract "Notes for future agents" section from self-assessment.md
  const selfAssessmentPath = path.join(taskDir, "self-assessment.md");
  let notes = `⚠ ${task.id}: self-assessment.md not found or unreadable.`;
  try {
    const selfAssessment = fs.readFileSync(selfAssessmentPath, "utf8");
    const m = selfAssessment.match(
      /## Notes for future agents\n([\s\S]*?)(\n## |\s*$)/,
    );
    if (m) {
      notes = m[1].trim();
    } else {
      notes = `⚠ ${task.id}: self-assessment.md is missing the '## Notes for future agents' section — future tasks will have no context from this task.`;
    }
  } catch {
    // keep default message
  }

  const contextEntry =
    `## ${task.id} — ${task.title}\n\n` +
    `**Files:** ${filesList}\n\n` +
    `${notes}\n\n---\n`;

  fs.appendFileSync(path.join(cfg.pipelineDir, "context.md"), contextEntry);

  // ── Git commit ──────────────────────────────────────────────────────────────
  log(`Committing task ${task.id}...`);

  // Stage in-scope files
  for (const f of filesInScope) {
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

  // Stage test files that match in-scope source files
  for (const f of filesInScope) {
    const base = path.basename(f, ".ts");
    const testResult = spawnSync(
      "find",
      [
        cfg.repoRoot,
        "-path",
        `*/__tests__/${base}*`,
      ],
      { encoding: "utf8" },
    );
    const testFiles = (testResult.stdout || "")
      .split("\n")
      .filter(Boolean);
    for (const tf of testFiles) {
      const rel = tf.replace(`${cfg.repoRoot}/`, "");
      const ignoreCheck = spawnSync(
        "git",
        ["-C", cfg.repoRoot, "check-ignore", "-q", rel],
        { encoding: "utf8" },
      );
      if (ignoreCheck.status !== 0) {
        spawnSync("git", ["-C", cfg.repoRoot, "add", tf], { encoding: "utf8" });
      }
    }
  }

  // Stage pipeline sentinel files
  spawnSync(
    "git",
    ["-C", cfg.repoRoot, "add", `pipeline/phase-${cfg.phase}/${task.id}/`],
    { encoding: "utf8" },
  );
  spawnSync(
    "git",
    ["-C", cfg.repoRoot, "add", `pipeline/phase-${cfg.phase}/task-manifest.json`],
    { encoding: "utf8" },
  );
  spawnSync(
    "git",
    ["-C", cfg.repoRoot, "add", `pipeline/phase-${cfg.phase}/context.md`],
    { encoding: "utf8" },
  );

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
        `feat(${task.id}): ${task.title} [skip ci]`,
      ],
      { encoding: "utf8" },
    );
    // Push immediately so a crash on the next task doesn't lose this work
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
    log(`Committed and pushed: feat(${task.id}): ${task.title}`);
  } else {
    log(`Nothing new to commit for ${task.id}`);
  }

  log(`Task ${task.id}: COMPLETE`);
}
