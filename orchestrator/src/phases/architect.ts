import fs from "node:fs";
import path from "node:path";
import https from "node:https";
import { log } from "../config.js";
import { runAgent } from "../agent.js";
import { halt } from "../halt.js";
import { reportPasses } from "../gates.js";
import {
  buildArchDocBlock,
  buildRepoFileTree,
  extractPhasePrd,
} from "../context.js";
import type { PipelineConfig, Task } from "../types.js";

// ── Manifest parsing ──────────────────────────────────────────────────────────

export function loadManifest(pipelineDir: string): Task[] {
  const manifestPath = path.join(pipelineDir, "task-manifest.json");
  const raw = JSON.parse(fs.readFileSync(manifestPath, "utf8")) as
    | Task[]
    | { tasks?: Task[]; task_order?: Task[] };
  const tasks = Array.isArray(raw)
    ? raw
    : (raw.tasks ?? raw.task_order ?? []);
  return tasks.filter((t): t is Task => typeof t === "object" && t !== null);
}

// ── Schema validation ─────────────────────────────────────────────────────────

export function validateManifestSchema(pipelineDir: string): string {
  const manifestPath = path.join(pipelineDir, "task-manifest.json");
  const errors: string[] = [];

  let data: unknown;
  try {
    data = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  } catch (e) {
    return `Invalid JSON: ${e}`;
  }

  const raw = data as Task[] | { tasks?: Task[]; task_order?: Task[] };
  const tasks = Array.isArray(raw)
    ? raw
    : ((raw as { tasks?: Task[] }).tasks ??
      (raw as { task_order?: Task[] }).task_order ??
      []);

  const filteredTasks = tasks.filter(
    (t): t is Task => typeof t === "object" && t !== null,
  );

  if (filteredTasks.length === 0) {
    return "Manifest contains no tasks";
  }

  const required = [
    "id",
    "title",
    "description",
    "files_in_scope",
    "acceptance_criteria",
    "security_sensitive",
    "estimated_complexity",
  ] as const;
  const validComplexity = new Set(["low", "medium", "high"]);
  const allIds = filteredTasks.map((t) => t.id);

  for (const t of filteredTasks) {
    const tid = t.id || "(missing id)";
    for (const field of required) {
      if (!(field in t)) {
        errors.push(`${tid}: missing required field '${field}'`);
      }
    }
    if (Array.isArray(t.acceptance_criteria) && t.acceptance_criteria.length === 0) {
      errors.push(`${tid}: acceptance_criteria is empty`);
    }
    if (Array.isArray(t.files_in_scope) && t.files_in_scope.length === 0) {
      errors.push(`${tid}: files_in_scope is empty`);
    }
    if (!validComplexity.has(t.estimated_complexity)) {
      errors.push(
        `${tid}: estimated_complexity must be low/medium/high, got '${t.estimated_complexity}'`,
      );
    }
    for (const dep of t.dependencies ?? []) {
      if (!allIds.includes(dep)) {
        errors.push(`${tid}: dependency '${dep}' is not a valid task id`);
      }
    }
  }

  // Check for duplicates
  const idCounts = new Map<string, number>();
  for (const id of allIds) {
    idCounts.set(id, (idCounts.get(id) ?? 0) + 1);
  }
  const dupes = [...idCounts.entries()]
    .filter(([, c]) => c > 1)
    .map(([id]) => id);
  if (dupes.length > 0) {
    errors.push(`Duplicate task ids: ${dupes.join(", ")}`);
  }

  return errors.join("\n");
}

// ── AC quality gate ───────────────────────────────────────────────────────────

const VAGUE_PATTERN =
  /\b(works?(?: correctly| properly| as expected)?|is (?:done|complete|working|functional)|functions?(?: properly| correctly)|it works|should work|is (?:implemented|added|created))\b/i;

export async function checkAcQuality(
  pipelineDir: string,
  apiKey: string,
): Promise<string> {
  const tasks = loadManifest(pipelineDir);
  const issues: string[] = [];
  const criteriaForLlm: string[] = [];

  for (const t of tasks) {
    const tid = t.id ?? "?";
    for (let i = 0; i < (t.acceptance_criteria ?? []).length; i++) {
      const c = t.acceptance_criteria[i].trim();
      if (c.length < 10) {
        issues.push(`${tid} AC-${i + 1}: too short to be testable — '${c}'`);
      } else if (VAGUE_PATTERN.test(c)) {
        issues.push(
          `${tid} AC-${i + 1}: vague language — '${c.slice(0, 80)}'`,
        );
      } else {
        criteriaForLlm.push(`${tid} AC-${i + 1}: ${c}`);
      }
    }
  }

  // LLM judge via Claude Haiku
  if (criteriaForLlm.length > 0 && apiKey) {
    try {
      const llmIssues = await callHaikuJudge(criteriaForLlm, apiKey);
      issues.push(...llmIssues);
    } catch {
      // LLM unavailable — structural check is sufficient
    }
  }

  return issues.join("\n");
}

async function callHaikuJudge(
  criteria: string[],
  apiKey: string,
): Promise<string[]> {
  const criteriaText = criteria.join("\n");
  const prompt =
    `Review these software acceptance criteria for testability.\n` +
    `A criterion is testable if it describes a specific, verifiable outcome ` +
    `with no ambiguity about how to confirm it passed or failed.\n\n` +
    `Criteria:\n${criteriaText}\n\n` +
    `Reply with ONLY a JSON array of non-testable criteria. ` +
    `Each entry: {"id": "task-1 AC-2", "issue": "reason"}. ` +
    `If all are testable, reply with: []`;

  const body = JSON.stringify({
    model: "claude-haiku-4-5-20251001",
    max_tokens: 600,
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
        res.on("data", (chunk: Buffer) => {
          data += chunk.toString();
        });
        res.on("end", () => {
          try {
            const parsed = JSON.parse(data) as {
              content: Array<{ text: string }>;
            };
            const text = parsed.content[0].text.trim();
            // Extract JSON array even if surrounded by markdown fences
            const m = text.match(/\[[\s\S]*\]/);
            if (m) {
              const arr = JSON.parse(m[0]) as Array<{
                id?: string;
                issue?: string;
              }>;
              resolve(arr.map((item) => `${item.id ?? "?"}: ${item.issue ?? "?"}`));
            } else {
              resolve([]);
            }
          } catch {
            resolve([]);
          }
        });
      },
    );

    req.on("error", reject);
    req.setTimeout(20000, () => {
      req.destroy();
      reject(new Error("timeout"));
    });
    req.write(body);
    req.end();
  });
}

// ── runArchitectPhase() ───────────────────────────────────────────────────────

export async function runArchitectPhase(
  cfg: PipelineConfig,
  phasePrdContent: string,
  archDoc: string,
): Promise<void> {
  const manifestPath = path.join(cfg.pipelineDir, "task-manifest.json");

  const repoFileTree = buildRepoFileTree(cfg.repoRoot);

  const archPrompt = `You are running as AG-01 Architect for {PROJECT_NAME}.

Here is the PRD content for Phase ${cfg.phase}:
<prd-phase>
${phasePrdContent}
</prd-phase>

Here is the Architecture document:
<architecture>
${archDoc}
</architecture>

Here is the current repository file tree (use this to assign real, existing paths in files_in_scope):
<repo-file-tree>
${repoFileTree}
</repo-file-tree>

Produce the task manifest for Phase ${cfg.phase}.

Write two files to pipeline/phase-${cfg.phase}/:
1. task-manifest.json
2. manifest-summary.md

STRICT SCHEMA REQUIREMENT — every task object in task-manifest.json MUST have ALL of these fields
with EXACTLY these types and allowed values. The manifest will be machine-validated and will be
rejected if any field is missing or uses a non-allowed value:

  {
    "id":                   string   — e.g. "task-1" (sequential, no other format)
    "title":                string
    "description":          string
    "files_in_scope":       string[] — MUST be non-empty; use exact repo paths from the file tree above
    "dependencies":         string[] — task ids; use [] if none
    "acceptance_criteria":  string[] — MUST be non-empty; each item must be a specific testable statement
    "security_sensitive":   boolean  — true or false (REQUIRED — never omit this field)
    "estimated_complexity": string   — MUST be exactly one of: "low", "medium", "high"
                                       DO NOT use XS, S, M, L, XL, or any other value
  }

Follow your system prompt exactly.`;

  if (!fs.existsSync(manifestPath)) {
    runAgent(
      "ag-01-architect",
      archPrompt,
      path.join(cfg.pipelineDir, "ag01-output.md"),
      0,
      cfg.pipelineDir,
    );
  } else {
    log("task-manifest.json already exists — skipping AG-01");
  }

  if (!fs.existsSync(manifestPath)) {
    halt(
      "task-manifest.json not produced",
      "AG-01",
      "Architect did not write task-manifest.json",
    );
  }

  // Schema validation
  const schemaErrors = validateManifestSchema(cfg.pipelineDir);
  if (schemaErrors) {
    const debugInfo = `=== SCHEMA VALIDATION ERRORS ===\n${schemaErrors}\n\n=== RAW MANIFEST ===\n${
      fs.existsSync(manifestPath)
        ? fs.readFileSync(manifestPath, "utf8")
        : "(manifest file not found)"
    }`;
    fs.writeFileSync(
      path.join(cfg.pipelineDir, "schema-errors.txt"),
      debugInfo,
    );
    halt(
      "task-manifest.json failed schema validation",
      "AG-01",
      `Fix these issues in the manifest before proceeding:\n${schemaErrors}`,
    );
  }

  // Log tasks
  log("Manifest produced. Tasks:");
  const tasks = loadManifest(cfg.pipelineDir);
  for (const t of tasks) {
    const flag = t.security_sensitive ? " [SECURITY]" : "";
    log(`  ${t.id}: ${t.title}${flag}`);
  }

  // AC quality gate
  const acIssues = await checkAcQuality(
    cfg.pipelineDir,
    process.env.ANTHROPIC_API_KEY ?? "",
  );
  if (acIssues) {
    log("Acceptance criteria quality warnings:");
    for (const issue of acIssues.split("\n")) {
      log(`  ! ${issue}`);
    }
  }

  // ── AG-02 Reviewer ──────────────────────────────────────────────────────────
  log("");
  log("AG-02 Reviewer — preparing human review...");

  let reviewPrompt = `You are running as AG-02 Reviewer for {PROJECT_NAME}.

Read pipeline/phase-${cfg.phase}/task-manifest.json and pipeline/phase-${cfg.phase}/manifest-summary.md.

Write reviewer-summary.md to pipeline/phase-${cfg.phase}/ using the format defined in your system prompt.

Do not make any API calls. Just write the file and stop.`;

  if (acIssues) {
    reviewPrompt += `\n\nThe orchestrator detected acceptance criteria quality issues — surface these in 'Concerns or risks':\n${acIssues}`;
  }

  runAgent(
    "ag-02-reviewer",
    reviewPrompt,
    path.join(cfg.pipelineDir, "ag02-output.md"),
    0,
    cfg.pipelineDir,
  );

  const summaryFile = path.join(cfg.pipelineDir, "reviewer-summary.md");
  if (!fs.existsSync(summaryFile)) {
    halt(
      "reviewer-summary.md not produced",
      "AG-02",
      "Reviewer did not write the summary file",
    );
  }

  // Check ARCHITECT_ONLY env
  if (process.env.ARCHITECT_ONLY === "1") {
    log("ARCHITECT_ONLY=1 — planning complete, exiting before human gate");
    log(`Manifest and reviewer summary written to ${cfg.pipelineDir}/`);
    process.exit(0);
  }

  // ── Human gate ──────────────────────────────────────────────────────────────
  let approval = await waitForApproval(cfg);

  if (approval === "stop") {
    halt("User stopped the pipeline", "human-gate", "User replied 'stop'");
  }

  const maxRevisions = 3;
  let revision = 0;

  while (approval.startsWith("changes:")) {
    revision++;
    if (revision >= maxRevisions) {
      halt(
        `Manifest revised ${maxRevisions} times without approval`,
        "human-gate",
        "Too many revision rounds — stopping pipeline",
      );
    }

    const changes = approval.replace(/^changes:\s*/, "");
    log(`Changes requested (round ${revision}/${maxRevisions}): ${changes}`);
    log("Re-running Architect with feedback...");

    const archPromptRevised = `${archPrompt}

The user has reviewed the manifest and requested these changes: ${changes}

Revise the manifest accordingly and rewrite task-manifest.json and manifest-summary.md.`;

    runAgent(
      "ag-01-architect",
      archPromptRevised,
      path.join(cfg.pipelineDir, `ag01-output-revised-${revision}.md`),
      0,
      cfg.pipelineDir,
    );

    const reviewPromptRevised = `You are running as AG-02 Reviewer for {PROJECT_NAME}.

This is revision ${revision} of the manifest. The user requested: ${changes}

Read pipeline/phase-${cfg.phase}/task-manifest.json and pipeline/phase-${cfg.phase}/manifest-summary.md.
Also read the previous pipeline/phase-${cfg.phase}/reviewer-summary.md to identify what changed.

Write a revised reviewer-summary.md to pipeline/phase-${cfg.phase}/ using the revision format from
your system prompt — put the 'What changed' section first, then the standard summary.

Do not make any API calls. Just write the file and stop.`;

    runAgent(
      "ag-02-reviewer",
      reviewPromptRevised,
      path.join(cfg.pipelineDir, `ag02-output-revised-${revision}.md`),
      0,
      cfg.pipelineDir,
    );

    if (!fs.existsSync(summaryFile)) {
      halt(
        "reviewer-summary.md not produced on revision",
        "AG-02",
        "Reviewer did not write the summary file",
      );
    }

    approval = await waitForApproval(cfg);

    if (approval === "stop") {
      halt(
        "User stopped the pipeline",
        "human-gate",
        "User replied 'stop' during revision",
      );
    }
  }

  if (approval !== "approve") {
    halt(
      "Unexpected approval signal",
      "human-gate",
      `Signal received: ${approval}`,
    );
  }

  log("Approved. Starting implementation...");

  // Record approved_at timestamp
  const approvalFile = path.join(cfg.pipelineDir, "approval.json");
  try {
    const approvalData = JSON.parse(
      fs.readFileSync(approvalFile, "utf8"),
    ) as Record<string, unknown>;
    approvalData.approved_at = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
    fs.writeFileSync(approvalFile, JSON.stringify(approvalData, null, 2));
  } catch {
    // ignore
  }
}

// ── waitForApproval() ─────────────────────────────────────────────────────────

async function waitForApproval(cfg: PipelineConfig): Promise<string> {
  const approvalFile = path.join(cfg.pipelineDir, "approval.json");
  const deadline = Date.now() + 86400 * 1000; // 24 hours

  process.stderr.write(`[${new Date().toTimeString().slice(0, 8)}] ========================================\n`);
  process.stderr.write(`[${new Date().toTimeString().slice(0, 8)}] HUMAN GATE — review the manifest above\n`);
  process.stderr.write(
    `[${new Date().toTimeString().slice(0, 8)}] To approve:  ./orchestrator/approve.sh --phase ${cfg.phase}\n`,
  );
  process.stderr.write(
    `[${new Date().toTimeString().slice(0, 8)}] To stop:     ./orchestrator/approve.sh --phase ${cfg.phase} --stop\n`,
  );
  process.stderr.write(
    `[${new Date().toTimeString().slice(0, 8)}] To request changes: ./orchestrator/approve.sh --phase ${cfg.phase} --changes "describe changes"\n`,
  );
  process.stderr.write(`[${new Date().toTimeString().slice(0, 8)}] ========================================\n`);

  while (Date.now() < deadline) {
    if (fs.existsSync(approvalFile)) {
      try {
        const data = JSON.parse(
          fs.readFileSync(approvalFile, "utf8"),
        ) as { signal?: string; changes?: string };
        const signal = data.signal;
        if (!signal) {
          await sleep(2000);
          continue;
        }
        const result =
          signal === "changes" && data.changes
            ? `changes: ${data.changes}`
            : signal;
        log(`Approval received: ${result}`);
        return result;
      } catch {
        // file not yet fully written, wait
      }
    }
    await sleep(2000);
  }

  halt(
    "Approval timeout",
    "human-gate",
    "No approval signal received within 24 hours",
  );
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
