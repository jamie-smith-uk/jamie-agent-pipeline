import fs from "node:fs";
import path from "node:path";
import type { PipelineConfig } from "./types.js";

// ── Env loading ───────────────────────────────────────────────────────────────

/**
 * Loads .env file from the given directory using simple line-by-line parsing.
 * Sets process.env for each KEY=VALUE line found.
 */
export function loadEnv(dir: string): void {
  const envPath = path.join(dir, ".env");
  if (!fs.existsSync(envPath)) return;

  const lines = fs.readFileSync(envPath, "utf8").split("\n");
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eqIdx = trimmed.indexOf("=");
    if (eqIdx === -1) continue;
    const key = trimmed.slice(0, eqIdx).trim();
    let val = trimmed.slice(eqIdx + 1).trim();
    // Strip surrounding quotes
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1);
    }
    if (key && !(key in process.env)) {
      process.env[key] = val;
    }
  }
}

// ── Config construction ───────────────────────────────────────────────────────

export function buildConfig(phase: string): PipelineConfig {
  // Derive REPO_ROOT from this file's location: orchestrator/src/config.ts → ../../
  const scriptDir = path.dirname(new URL(import.meta.url).pathname);
  const repoRoot = path.resolve(scriptDir, "../..");

  loadEnv(repoRoot);

  if (!process.env.ANTHROPIC_API_KEY) {
    throw new Error("ANTHROPIC_API_KEY is not set — check your .env");
  }

  // Construct DATABASE_URL from individual vars if not already set
  if (!process.env.DATABASE_URL && process.env.POSTGRES_USER) {
    const { POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_HOST, POSTGRES_PORT, POSTGRES_DB } =
      process.env;
    process.env.DATABASE_URL = `postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}`;
  }

  const pipelineDir = path.join(repoRoot, "pipeline", `phase-${phase}`);
  const agentsDir = path.join(repoRoot, "agents");

  fs.mkdirSync(pipelineDir, { recursive: true });

  return {
    phase,
    repoRoot,
    pipelineDir,
    agentsDir,
    phaseStartedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    contextMaxChars: 12000,
    archDocMaxChars: 6000,
  };
}

// ── Logging ───────────────────────────────────────────────────────────────────

export function log(msg: string): void {
  const ts = new Date().toTimeString().slice(0, 8);
  console.log(`[${ts}] ${msg}`);
}
