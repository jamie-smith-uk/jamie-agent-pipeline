import fs from "node:fs";
import path from "node:path";
import type { MetricsData, PhaseMetrics, TaskMetrics } from "./types.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function readMetrics(metricsFile: string): MetricsData | null {
  if (!fs.existsSync(metricsFile)) return null;
  try {
    return JSON.parse(fs.readFileSync(metricsFile, "utf8")) as MetricsData;
  } catch {
    return null;
  }
}

function writeMetrics(metricsFile: string, data: MetricsData): void {
  fs.writeFileSync(metricsFile, JSON.stringify(data, null, 2));
}

// ── recordTaskMetrics() ───────────────────────────────────────────────────────

export function recordTaskMetrics(
  pipelineDir: string,
  taskId: string,
  taskTitle: string,
  phaseName: string,
  durationS: number,
  attempts: number,
  result: string,
  rawPhase: string,
  phaseStartedAt: string,
): void {
  const metricsFile = path.join(pipelineDir, "metrics.json");

  let phaseNum: number | string;
  const parsed = Number.parseInt(rawPhase, 10);
  phaseNum = Number.isNaN(parsed) ? rawPhase : parsed;

  let data: MetricsData = readMetrics(metricsFile) ?? {
    phase: phaseNum,
    started_at: phaseStartedAt,
    tasks: {},
  };

  if (!data.tasks[taskId]) {
    data.tasks[taskId] = { title: taskTitle };
  }
  const task = data.tasks[taskId];
  (task as Record<string, unknown>)[phaseName] = {
    duration_s: durationS,
    attempts,
    result,
  } satisfies PhaseMetrics;

  // Recompute total
  let total = 0;
  for (const val of Object.values(task)) {
    if (
      val &&
      typeof val === "object" &&
      "duration_s" in val &&
      typeof (val as PhaseMetrics).duration_s === "number"
    ) {
      total += (val as PhaseMetrics).duration_s;
    }
  }
  task.total_duration_s = total;

  writeMetrics(metricsFile, data);
}

// ── recordSecurityFindings() ──────────────────────────────────────────────────

const RULE_PATTERNS = [
  "Parameterised queries",
  "Prompt injection",
  "Input validation",
  "Cron injection",
  "Secrets in .env",
  "Never log secrets",
  "Agent exposure",
  "secrets in git",
  "Whitelist on every handler",
  "agent-constructed SQL",
  "OAuth tokens",
  "Admin UI",
  "No PII in logs",
  "Label all external content",
  "No stack traces",
  "Statement timeout",
  "Zero high or critical",
  "exact versions",
  "No unjustified",
];

export function recordSecurityFindings(
  pipelineDir: string,
  taskId: string,
  taskDir: string,
): void {
  const metricsFile = path.join(pipelineDir, "metrics.json");
  const data = readMetrics(metricsFile);
  if (!data || !data.tasks[taskId]) return;

  const violated = new Set<string>();

  let entries: string[];
  try {
    entries = fs.readdirSync(taskDir);
  } catch {
    return;
  }

  for (const fname of entries.sort()) {
    if (!fname.startsWith("sec-output-")) continue;
    try {
      const content = fs.readFileSync(path.join(taskDir, fname), "utf8");
      if (!content.includes("FAIL")) continue;
      for (const pattern of RULE_PATTERNS) {
        if (content.toLowerCase().includes(pattern.toLowerCase())) {
          violated.add(pattern);
        }
      }
    } catch {
      // ignore
    }
  }

  if (violated.size > 0) {
    data.tasks[taskId].security_findings = [...violated].sort();
    writeMetrics(metricsFile, data);
  }
}

// ── updateTokenLog() ──────────────────────────────────────────────────────────

export function updateTokenLog(
  pipelineDir: string,
  agentId: string,
  usage: string,
): void {
  const metricsFile = path.join(pipelineDir, "metrics.json");
  const data = readMetrics(metricsFile);
  if (!data) return;

  if (!data.token_log) data.token_log = [];
  data.token_log.push({ agent: agentId, usage });
  writeMetrics(metricsFile, data);
}

// ── writeHealthSummary() ──────────────────────────────────────────────────────

export function writeHealthSummary(
  pipelineDir: string,
  phase: string,
  timestamp: string,
): void {
  const metricsFile = path.join(pipelineDir, "metrics.json");
  const data = readMetrics(metricsFile);
  if (!data || Object.keys(data.tasks).length === 0) return;

  function fmt(v: number | null | undefined, suffix = "%"): string {
    return v != null ? `${v}${suffix}` : "—";
  }

  const rows = Object.entries(data.tasks).map(([tid, t]) => {
    const h = (t.health ?? {}) as Partial<import("./types.js").HealthMetrics>;
    return {
      id: tid,
      title: (t.title ?? tid).slice(0, 35),
      cov: fmt(h.coverage_pct),
      dup: fmt(h.duplication_pct),
      cx: h.complex_fn_count != null ? String(h.complex_fn_count) : "—",
      delta: (t.health_delta as string) ?? "—",
    };
  });

  const tasks = Object.values(data.tasks);
  const covs = tasks
    .map((t) => (t.health as Partial<import("./types.js").HealthMetrics>)?.coverage_pct)
    .filter((v): v is number => v != null);
  const dups = tasks
    .map((t) => (t.health as Partial<import("./types.js").HealthMetrics>)?.duplication_pct)
    .filter((v): v is number => v != null);
  const totalCx = tasks.reduce(
    (s, t) =>
      s + ((t.health as Partial<import("./types.js").HealthMetrics>)?.complex_fn_count ?? 0),
    0,
  );

  const avg = (arr: number[]) =>
    arr.length > 0 ? Math.round((arr.reduce((a, b) => a + b, 0) / arr.length) * 10) / 10 : null;

  const avgCov = fmt(avg(covs));
  const avgDup = fmt(avg(dups));

  const lines = [
    `# Phase ${phase} — Code Health Summary`,
    "",
    `*Generated ${timestamp}*`,
    "",
    "| Task | Coverage | Duplication | Complex Fns | Refactor delta |",
    "|---|---|---|---|---|",
    ...rows.map(
      (r) =>
        `| ${r.id} — ${r.title} | ${r.cov} | ${r.dup} | ${r.cx} | ${r.delta} |`,
    ),
    `| **Phase average** | **${avgCov}** | **${avgDup}** | **${totalCx} total** | |`,
    "",
  ];

  fs.writeFileSync(path.join(pipelineDir, "health-summary.md"), lines.join("\n"));
}

// ── writeMetricsSummary() ─────────────────────────────────────────────────────

export function writeMetricsSummary(pipelineDir: string, completedAt: string): void {
  const metricsFile = path.join(pipelineDir, "metrics.json");
  const data = readMetrics(metricsFile);
  if (!data) return;

  const tasks = data.tasks;
  const total = Object.values(tasks).reduce(
    (s, t) => s + (t.total_duration_s as number ?? 0),
    0,
  );

  const highRetry = Object.entries(tasks)
    .filter(([, t]) =>
      Object.values(t).some(
        (v) =>
          v &&
          typeof v === "object" &&
          "attempts" in v &&
          (v as PhaseMetrics).attempts > 1,
      ),
    )
    .map(([tid]) => tid);

  const allFindings: string[] = [];
  for (const t of Object.values(tasks)) {
    allFindings.push(...(t.security_findings ?? []));
  }

  // Count occurrences
  const findingCounts = new Map<string, number>();
  for (const f of allFindings) {
    findingCounts.set(f, (findingCounts.get(f) ?? 0) + 1);
  }
  const topFindings = [...findingCounts.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 5)
    .map(([r, c]) => `${r} (${c}x)`);

  // pass@1 rate
  const n = Object.keys(tasks).length;
  const passAt1 = Object.values(tasks).filter((t) =>
    Object.values(t).every(
      (v) =>
        !v ||
        typeof v !== "object" ||
        !("attempts" in v) ||
        (v as PhaseMetrics).attempts === 1,
    ),
  ).length;
  const passAt1Rate = n > 0 ? Math.round((100 * passAt1) / n) : 0;

  // Health summary
  const healthVals = Object.values(tasks).map(
    (t) => (t.health ?? {}) as Partial<import("./types.js").HealthMetrics>,
  );
  const avg = (arr: (number | null | undefined)[]) => {
    const v = arr.filter((x): x is number => x != null);
    return v.length > 0 ? Math.round((v.reduce((a, b) => a + b, 0) / v.length) * 10) / 10 : null;
  };

  const healthSummary = {
    avg_coverage_pct: avg(healthVals.map((h) => h.coverage_pct)),
    avg_duplication_pct: avg(healthVals.map((h) => h.duplication_pct)),
    total_complex_fns: healthVals.reduce(
      (s, h) => s + (h.complex_fn_count ?? 0),
      0,
    ),
  };

  data.summary = {
    completed_at: completedAt,
    total_duration_s: total,
    tasks_completed: n,
    pass_at_1_rate: passAt1Rate,
    high_retry_tasks: highRetry,
    top_security_findings: topFindings,
    health: healthSummary,
  };

  writeMetrics(metricsFile, data);
}
