import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { log } from "../config.js";
import type { HealthMetrics } from "../types.js";

// ── runCodeHealthChecks() ─────────────────────────────────────────────────────

/**
 * Runs code health checks (duplication, coverage, complexity) on files_in_scope.
 * Optional label "pre-refactor" writes health-report-pre.json for before/after comparison.
 * Informational only — does not gate the pipeline.
 *
 * @param skipTests - if true, reuse existing coverage-summary.json instead of re-running tests
 */
export function runCodeHealthChecks(
  repoRoot: string,
  pipelineDir: string,
  taskId: string,
  taskDir: string,
  filesInScopeJson: string,
  label: "pre-refactor" | "" = "",
  skipTests = false,
): void {
  const metricsFile = path.join(pipelineDir, "metrics.json");
  const reportFile = path.join(
    taskDir,
    label === "pre-refactor" ? "health-report-pre.json" : "health-report.json",
  );

  const allFiles: string[] = JSON.parse(filesInScopeJson);
  const files = allFiles.filter((f) =>
    fs.existsSync(path.join(repoRoot, f)),
  );
  const tsFiles = files
    .filter((f) => f.endsWith(".ts") || f.endsWith(".tsx"))
    .map((f) => path.join(repoRoot, f));

  const report: {
    task_id: string;
    files_checked: string[];
    complex_functions: ComplexFunction[];
    duplication_pct: number | null;
    coverage_pct: number | null;
  } = {
    task_id: taskId,
    files_checked: files,
    complex_functions: [],
    duplication_pct: null,
    coverage_pct: null,
  };

  // ── Complexity: parse Biome JSON output ──────────────────────────────────────
  const complexFns: ComplexFunction[] = [];
  if (tsFiles.length > 0) {
    const biomeResult = spawnSync(
      "pnpm",
      ["exec", "biome", "check", "--reporter=json", ...tsFiles],
      {
        cwd: repoRoot,
        encoding: "utf8",
        maxBuffer: 10 * 1024 * 1024,
        timeout: 60000,
      },
    );

    if (biomeResult.stdout?.trim()) {
      try {
        const biomeOut = JSON.parse(biomeResult.stdout) as BiomeOutput;
        for (const diag of biomeOut.diagnostics ?? []) {
          if (!diag.category?.includes("noExcessiveCognitiveComplexity")) continue;

          const location = diag.location ?? {};
          const fp = location.path?.file ?? "";
          let line = location.span?.[0] ?? 0;
          const msg = diag.message ?? "";
          const scoreMatch = msg.match(/complexity of (\d+)/);
          const score = scoreMatch ? Number.parseInt(scoreMatch[1], 10) : 0;
          const rel = fp ? path.relative(repoRoot, fp) : fp;

          // Convert byte offset to line number if needed
          if (fp && fs.existsSync(fp) && typeof line === "number" && line > 1000) {
            try {
              const content = fs.readFileSync(fp);
              line = content.slice(0, line).reduce(
                (count, byte) => count + (byte === 10 ? 1 : 0),
                0,
              ) + 1;
            } catch {
              // ignore
            }
          }

          complexFns.push({ file: rel, line, score });
        }
      } catch {
        // ignore JSON parse errors
      }
    }
  }
  report.complex_functions = complexFns.slice(0, 10);

  // ── Duplication: run jscpd if available ──────────────────────────────────────
  if (tsFiles.length > 0) {
    const jscpdResult = spawnSync(
      "npx",
      [
        "--yes",
        "jscpd@3.5.10",
        "--min-lines",
        "5",
        "--reporters",
        "json",
        "--output",
        "/tmp/jscpd-out",
        ...tsFiles,
      ],
      {
        cwd: repoRoot,
        encoding: "utf8",
        timeout: 30000,
      },
    );

    const jscpdJson = "/tmp/jscpd-out/jscpd-report.json";
    if (fs.existsSync(jscpdJson)) {
      try {
        const d = JSON.parse(fs.readFileSync(jscpdJson, "utf8")) as JscpdReport;
        const stats = d.statistics?.total ?? {};
        report.duplication_pct = Math.round((stats.percentage ?? 0) * 10) / 10;
      } catch {
        // ignore
      }
    }
  }

  // ── Coverage: read existing summary or run vitest --coverage ─────────────────
  const summaryFile = path.join(repoRoot, "coverage", "coverage-summary.json");
  if (!skipTests) {
    spawnSync(
      "pnpm",
      ["test", "--coverage", "--coverage.reporter=json-summary"],
      {
        cwd: repoRoot,
        encoding: "utf8",
        timeout: 120000,
      },
    );
  }
  if (fs.existsSync(summaryFile)) {
    try {
      const s = JSON.parse(
        fs.readFileSync(summaryFile, "utf8"),
      ) as CoverageSummary;
      const pct = s.total?.lines?.pct;
      if (pct != null) {
        report.coverage_pct = Math.round(pct * 10) / 10;
      }
    } catch {
      // ignore
    }
  }

  // ── Write report ─────────────────────────────────────────────────────────────
  fs.writeFileSync(reportFile, JSON.stringify(report, null, 2));

  // ── Log immediately to terminal ───────────────────────────────────────────────
  const prefix = label === "pre-refactor" ? "pre-refactor: " : "";
  const parts: string[] = [];
  if (report.coverage_pct != null) parts.push(`coverage ${report.coverage_pct}%`);
  if (report.duplication_pct != null) parts.push(`dup ${report.duplication_pct}%`);
  if (report.complex_functions.length > 0) {
    parts.push(`${report.complex_functions.length} complexity violation(s)`);
    for (const fn of report.complex_functions.slice(0, 3)) {
      const scoreStr = fn.score ? ` (score ${fn.score})` : "";
      log(`    ${fn.file}:${fn.line}${scoreStr}`);
    }
  }
  if (parts.length > 0) {
    log(`  ${prefix}${parts.join(" · ")}`);
  } else if (files.length > 0) {
    log(`  ${prefix}(coverage/duplication tools not available)`);
  }

  // ── Record in metrics (final report only, not pre-refactor baseline) ──────────
  if (label === "pre-refactor") return;
  if (!fs.existsSync(metricsFile)) return;

  try {
    const data = JSON.parse(fs.readFileSync(metricsFile, "utf8")) as import("../types.js").MetricsData;
    if (data.tasks?.[taskId]) {
      (data.tasks[taskId] as Record<string, unknown>).health = {
        complex_fn_count: report.complex_functions.length,
        max_complexity_score: Math.max(
          0,
          ...report.complex_functions.map((f) => f.score ?? 0),
        ),
        duplication_pct: report.duplication_pct,
        coverage_pct: report.coverage_pct,
      } satisfies HealthMetrics;
      fs.writeFileSync(metricsFile, JSON.stringify(data, null, 2));
    }
  } catch {
    // ignore
  }
}

// ── writeRefactorDelta() ──────────────────────────────────────────────────────

export function writeRefactorDelta(
  taskDir: string,
  pipelineDir: string,
  taskId: string,
): void {
  const preFile = path.join(taskDir, "health-report-pre.json");
  const postFile = path.join(taskDir, "health-report.json");
  const metricsFile = path.join(pipelineDir, "metrics.json");

  if (!fs.existsSync(preFile) || !fs.existsSync(postFile)) return;

  let pre: HealthReport;
  let post: HealthReport;
  try {
    pre = JSON.parse(fs.readFileSync(preFile, "utf8")) as HealthReport;
    post = JSON.parse(fs.readFileSync(postFile, "utf8")) as HealthReport;
  } catch {
    return;
  }

  const deltas: string[] = [];

  if (pre.coverage_pct != null && post.coverage_pct != null) {
    const d = Math.round((post.coverage_pct - pre.coverage_pct) * 10) / 10;
    if (d !== 0) deltas.push(`coverage ${d > 0 ? "↑" : "↓"}${Math.abs(d)}%`);
  }
  if (pre.duplication_pct != null && post.duplication_pct != null) {
    const d =
      Math.round((post.duplication_pct - pre.duplication_pct) * 10) / 10;
    if (d !== 0) deltas.push(`dup ${d < 0 ? "↓" : "↑"}${Math.abs(d)}%`);
  }
  const preCx = pre.complex_functions?.length ?? 0;
  const postCx = post.complex_functions?.length ?? 0;
  if (preCx !== postCx) deltas.push(`complex fns ${preCx}→${postCx}`);

  const summary = deltas.length > 0 ? deltas.join(" · ") : "no measurable change";
  log(`  Refactor delta: ${summary}`);

  if (fs.existsSync(metricsFile)) {
    try {
      const data = JSON.parse(
        fs.readFileSync(metricsFile, "utf8"),
      ) as import("../types.js").MetricsData;
      if (data.tasks?.[taskId]) {
        (data.tasks[taskId] as Record<string, unknown>).health_delta = summary;
        fs.writeFileSync(metricsFile, JSON.stringify(data, null, 2));
      }
    } catch {
      // ignore
    }
  }
}

// ── Types ─────────────────────────────────────────────────────────────────────

interface ComplexFunction {
  file: string;
  line: number;
  score: number;
}

interface HealthReport {
  complex_functions?: ComplexFunction[];
  duplication_pct?: number | null;
  coverage_pct?: number | null;
}

interface BiomeOutput {
  diagnostics?: Array<{
    category?: string;
    message?: string;
    location?: {
      path?: { file?: string };
      span?: number[];
    };
  }>;
}

interface JscpdReport {
  statistics?: {
    total?: {
      percentage?: number;
    };
  };
}

interface CoverageSummary {
  total?: {
    lines?: {
      pct?: number;
    };
  };
}
