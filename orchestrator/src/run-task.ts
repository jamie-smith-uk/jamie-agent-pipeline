#!/usr/bin/env node

/**
 * run-task.ts — Run a single ad-hoc task through the agent pipeline.
 *
 * For bug fixes, backlog items, hotfixes, and small features that don't
 * warrant a full PRD phase. Uses the same quality gates as the phase pipeline.
 *
 * Usage:
 *   pnpm exec tsx orchestrator/src/run-task.ts backlog/fix.md
 *   pnpm exec tsx orchestrator/src/run-task.ts --quick "Fix the crash"
 *   pnpm exec tsx orchestrator/src/run-task.ts --help
 */

import fs from "node:fs";
import https from "node:https";
import path from "node:path";
import readline from "node:readline";
import { spawnSync } from "node:child_process";

import { loadEnv, log } from "./config.js";
import { runTesterPhase } from "./phases/tester.js";
import { runDeveloperPhase } from "./phases/developer.js";
import { runMigrationPhase, hasMigration } from "./phases/migration.js";
import { runRefactorPhase } from "./phases/refactor.js";
import { runSecurityPhase } from "./phases/security.js";
import type { PipelineConfig, Task } from "./types.js";

// ── Arg parsing ───────────────────────────────────────────────────────────────

interface TaskRunnerOptions {
  taskFile: string;
  quickDesc: string;
  jsonInline: string;
  review: boolean;
  noSecurity: boolean;
  urgent: boolean;
  dryRun: boolean;
}

function parseArgs(): TaskRunnerOptions {
  const args = process.argv.slice(2);
  const opts: TaskRunnerOptions = {
    taskFile: "",
    quickDesc: "",
    jsonInline: "",
    review: false,
    noSecurity: false,
    urgent: false,
    dryRun: false,
  };

  if (args.includes("--help") || args.includes("-h")) {
    console.log(`Usage: tsx orchestrator/src/run-task.ts [OPTIONS] [task-file.md]

Inputs (one required):
  task-file.md              Task file with YAML front matter (see backlog/)
  --quick "description"     Natural language — AI generates the spec
  --json '{...}'            Inline task JSON

Options:
  --review       Show task spec and ask for approval before running
  --no-security  Skip AG-07 Security (for non-code changes, docs, config)
  --urgent       Skip Refactor and Mutation testing (hotfix mode)
  --dry-run      Print the manifest and exit without running agents

Task file format (backlog/my-task.md):
  ---
  title: Fix message handler crash on long input
  security_sensitive: false
  files:
    - src/handlers/message.ts
  criteria:
    - Messages over 4000 chars are truncated cleanly
    - A warning is logged when truncation occurs
  ---
  ## Context (optional)
  ...`);
    process.exit(0);
  }

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "--review":      opts.review = true; break;
      case "--no-security": opts.noSecurity = true; break;
      case "--urgent":      opts.urgent = true; break;
      case "--dry-run":     opts.dryRun = true; break;
      case "--quick":       opts.quickDesc = args[++i] ?? ""; break;
      case "--json":        opts.jsonInline = args[++i] ?? ""; break;
      default:
        if (args[i].startsWith("-")) {
          console.error(`Unknown option: ${args[i]}`);
          process.exit(1);
        }
        opts.taskFile = args[i];
    }
  }

  return opts;
}

// ── Task input resolution ─────────────────────────────────────────────────────

function parseTaskFile(filePath: string): Task {
  const content = fs.readFileSync(filePath, "utf8");
  const match = content.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)/);
  if (!match) throw new Error(`No YAML front matter found in ${filePath}`);

  const [, frontmatter, body] = match;
  const result: Record<string, unknown> = {};
  let currentList: string[] | null = null;

  for (const line of frontmatter.split("\n")) {
    if (/^  - /.test(line)) {
      currentList?.push(line.slice(4).trim());
    } else if (line.includes(":")) {
      const colonIdx = line.indexOf(":");
      const k = line.slice(0, colonIdx).trim();
      const v = line.slice(colonIdx + 1).trim();
      if (v === "") {
        result[k] = [];
        currentList = result[k] as string[];
      } else if (v.toLowerCase() === "true") {
        result[k] = true; currentList = null;
      } else if (v.toLowerCase() === "false") {
        result[k] = false; currentList = null;
      } else {
        result[k] = v; currentList = null;
      }
    }
  }

  const title = String(result.title ?? "Unnamed task");
  const slug = title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 40);

  return {
    id: slug,
    title,
    description: body?.trim().slice(0, 500) || title,
    files_in_scope: (result.files ?? result.files_in_scope ?? []) as string[],
    dependencies: [],
    acceptance_criteria: (result.criteria ?? result.acceptance_criteria ?? []) as string[],
    security_sensitive: Boolean(result.security_sensitive),
    estimated_complexity: (result.complexity as Task["estimated_complexity"]) ?? "medium",
  };
}

async function generateTaskFromDescription(description: string, repoRoot: string): Promise<Task> {
  log("Generating task manifest from description...");

  const listingResult = spawnSync(
    "git",
    ["ls-files", "--cached", "--others", "--exclude-standard"],
    { cwd: repoRoot, encoding: "utf8", timeout: 5000 },
  );
  const listing = (listingResult.stdout ?? "").slice(0, 2000);

  const prompt =
    `You are a software architect. Given this task description and repo file listing, ` +
    `produce a task manifest JSON object.\n\n` +
    `Task: ${description}\n\nRepo files:\n${listing}\n\n` +
    `Reply with ONLY valid JSON:\n` +
    `{"id":"kebab-slug","title":"Short title","description":"What to build",` +
    `"files_in_scope":["path/to/file.ts"],"dependencies":[],` +
    `"acceptance_criteria":["Specific testable criterion"],` +
    `"security_sensitive":false,"estimated_complexity":"low|medium|high"}`;

  const apiKey = process.env.ANTHROPIC_API_KEY ?? "";
  const body = JSON.stringify({
    model: "claude-haiku-4-5-20251001",
    max_tokens: 800,
    messages: [{ role: "user", content: prompt }],
  });

  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        hostname: "api.anthropic.com",
        path: "/v1/messages",
        method: "POST",
        headers: {
          "x-api-key": apiKey,
          "anthropic-version": "2023-06-01",
          "content-type": "application/json",
          "content-length": Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = "";
        res.on("data", (chunk) => { data += chunk; });
        res.on("end", () => {
          try {
            const parsed = JSON.parse(data) as { content: Array<{ text: string }> };
            const text = parsed.content[0].text.trim();
            const jsonMatch = text.match(/\{[\s\S]*\}/);
            if (!jsonMatch) throw new Error("No JSON in response");
            resolve(JSON.parse(jsonMatch[0]) as Task);
          } catch (e) {
            reject(new Error(`Failed to parse Architect response: ${e}`));
          }
        });
      },
    );
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

// ── Review gate ───────────────────────────────────────────────────────────────

async function promptReview(task: Task): Promise<boolean> {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n════════════════════════════════════════════════════════");
  console.log("  TASK REVIEW");
  console.log("════════════════════════════════════════════════════════");
  console.log(`  Title:    ${task.title}`);
  console.log(`  Files:    ${task.files_in_scope.join(", ")}`);
  console.log(`  Security: ${task.security_sensitive}`);
  console.log("");
  console.log("  Criteria:");
  for (const c of task.acceptance_criteria) {
    console.log(`    • ${c}`);
  }
  console.log("");

  return new Promise((resolve) => {
    rl.question("  approve | stop > ", (answer) => {
      rl.close();
      resolve(/^(approve|yes|y)$/i.test(answer.trim()));
    });
  });
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const opts = parseArgs();

  const scriptDir = path.dirname(new URL(import.meta.url).pathname);
  const repoRoot = path.resolve(scriptDir, "../..");

  loadEnv(repoRoot);

  if (!process.env.ANTHROPIC_API_KEY) {
    throw new Error("ANTHROPIC_API_KEY is not set — check your .env");
  }

  if (!process.env.DATABASE_URL && process.env.POSTGRES_USER) {
    const { POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_HOST, POSTGRES_PORT, POSTGRES_DB } = process.env;
    process.env.DATABASE_URL = `postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}`;
  }

  // ── Resolve task ────────────────────────────────────────────────────────────
  let task: Task;
  if (opts.quickDesc) {
    task = await generateTaskFromDescription(opts.quickDesc, repoRoot);
  } else if (opts.jsonInline) {
    task = JSON.parse(opts.jsonInline) as Task;
  } else if (opts.taskFile) {
    if (!fs.existsSync(opts.taskFile)) {
      console.error(`Task file not found: ${opts.taskFile}`);
      process.exit(1);
    }
    task = parseTaskFile(opts.taskFile);
  } else {
    console.error("Error: provide a task file, --quick description, or --json payload.");
    console.error("Run with --help for usage.");
    process.exit(1);
  }

  // ── Task directory ──────────────────────────────────────────────────────────
  const slug = task.id.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
  const taskDir = path.join(repoRoot, "pipeline", "tasks", `${slug}-${timestamp}`);
  fs.mkdirSync(taskDir, { recursive: true });
  fs.writeFileSync(path.join(taskDir, "task.json"), JSON.stringify(task, null, 2));

  const cfg: PipelineConfig = {
    phase: "tasks",
    repoRoot,
    pipelineDir: taskDir,
    agentsDir: path.join(repoRoot, ".opencode", "agents"),
    phaseStartedAt: new Date().toISOString(),
    contextMaxChars: 4000,
    archDocMaxChars: 6000,
    urgent: opts.urgent,
    noIntermediateCommit: true,
  };

  // ── Dry run ─────────────────────────────────────────────────────────────────
  if (opts.dryRun) {
    console.log("\nTask manifest:");
    console.log(JSON.stringify(task, null, 2));
    const pipeline = ["RED", "GREEN"];
    if (hasMigration(task.files_in_scope)) pipeline.push("MIGRATION");
    if (!opts.urgent) pipeline.push("REFACTOR");
    if (task.security_sensitive && !opts.urgent) pipeline.push("MUTATION");
    if (!opts.noSecurity) pipeline.push("SECURITY");
    pipeline.push("COMMIT");
    console.log(`\nPipeline: ${pipeline.join(" → ")}`);
    return;
  }

  log("========================================");
  log(`{PROJECT_NAME} — Task: ${task.title}`);
  log("========================================");
  const modeFlags = [opts.urgent && "URGENT", opts.noSecurity && "NO-SECURITY"].filter(Boolean);
  log(`Mode: ${modeFlags.length ? modeFlags.join(" ") : "standard"}`);
  log(`Dir:  ${taskDir}`);

  // ── Review gate ─────────────────────────────────────────────────────────────
  if (opts.review) {
    const approved = await promptReview(task);
    if (!approved) { log("Task stopped by user"); return; }
    log("Approved — starting implementation...");
  }

  // ── Pipeline phases ─────────────────────────────────────────────────────────
  runTesterPhase(cfg, task, taskDir, "");
  runDeveloperPhase(cfg, task, taskDir, "", "");
  runMigrationPhase(cfg, task, taskDir);
  if (!opts.urgent) runRefactorPhase(cfg, task, taskDir, "");
  if (!opts.noSecurity) runSecurityPhase(cfg, task, taskDir, "");

  // ── Git commit ──────────────────────────────────────────────────────────────
  log(`Committing ${task.id}...`);

  for (const f of task.files_in_scope) {
    const full = path.join(repoRoot, f);
    if (!fs.existsSync(full)) continue;
    const ignoreCheck = spawnSync("git", ["-C", repoRoot, "check-ignore", "-q", f], { encoding: "utf8" });
    if (ignoreCheck.status !== 0) {
      spawnSync("git", ["-C", repoRoot, "add", f], { encoding: "utf8" });
    }
  }

  for (const f of task.files_in_scope) {
    const base = path.basename(f, ".ts");
    const findResult = spawnSync("find", [repoRoot, "-path", `*/__tests__/${base}*`], { encoding: "utf8" });
    for (const tf of (findResult.stdout ?? "").split("\n").filter(Boolean)) {
      spawnSync("git", ["-C", repoRoot, "add", tf], { encoding: "utf8" });
    }
  }

  spawnSync("git", ["-C", repoRoot, "add", taskDir], { encoding: "utf8" });

  const diffCheck = spawnSync("git", ["-C", repoRoot, "diff", "--cached", "--quiet"], { encoding: "utf8" });
  if (diffCheck.status !== 0) {
    spawnSync("git", ["-C", repoRoot, "commit", "-m", `feat(${task.id}): ${task.title} [skip ci]`], { encoding: "utf8" });
    log(`Committed: feat(${task.id}): ${task.title}`);
  } else {
    log("Nothing new to commit");
  }

  // ── Summary ─────────────────────────────────────────────────────────────────
  process.stdout.write("\x07");
  log("");
  log("========================================");
  log(`Task complete: ${task.title}`);
  log(`Output: ${taskDir}`);
  log("========================================");
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
