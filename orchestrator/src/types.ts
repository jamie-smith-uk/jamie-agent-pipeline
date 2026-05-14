// ── Types ─────────────────────────────────────────────────────────────────────

export interface Task {
  id: string;
  title: string;
  description: string;
  files_in_scope: string[];
  dependencies: string[];
  acceptance_criteria: string[];
  security_sensitive: boolean;
  estimated_complexity: "low" | "medium" | "high";
}

export interface TaskManifest {
  tasks?: Task[];
  task_order?: Task[];
  [key: string]: unknown;
}

export interface PipelineConfig {
  phase: string;
  repoRoot: string;
  pipelineDir: string;
  agentsDir: string;
  phaseStartedAt: string;
  contextMaxChars: number;
  archDocMaxChars: number;
  urgent?: boolean;              // skip refactor + mutation testing
  noIntermediateCommit?: boolean; // skip WIP commit/push between GREEN and SECURITY
}

export interface GateResult {
  passed: boolean;
  failures: string;
}

export interface ApprovalSignal {
  signal: "approve" | "stop" | `changes:${string}`;
  timestamp: string;
  source: string;
  changes?: string;
  approved_at?: string;
}

export interface MetricsData {
  phase: number | string;
  started_at: string;
  tasks: Record<string, TaskMetrics>;
  summary?: MetricsSummary;
  token_log?: TokenLogEntry[];
}

export interface TaskMetrics {
  title: string;
  total_duration_s?: number;
  health?: HealthMetrics;
  health_delta?: string;
  security_findings?: string[];
  [phase: string]: unknown;
}

export interface PhaseMetrics {
  duration_s: number;
  attempts: number;
  result: string;
}

export interface HealthMetrics {
  complex_fn_count: number;
  max_complexity_score: number;
  duplication_pct: number | null;
  coverage_pct: number | null;
}

export interface MetricsSummary {
  completed_at: string;
  total_duration_s: number;
  tasks_completed: number;
  pass_at_1_rate: number;
  high_retry_tasks: string[];
  top_security_findings: string[];
  health: {
    avg_coverage_pct: number | null;
    avg_duplication_pct: number | null;
    total_complex_fns: number;
  };
}

export interface TokenLogEntry {
  agent: string;
  usage: string;
}

export class HaltError extends Error {
  constructor(
    public readonly reason: string,
    public readonly agent: string,
    public readonly detail: string,
  ) {
    super(`HALT: ${reason} (agent: ${agent})`);
    this.name = "HaltError";
  }
}
