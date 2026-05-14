import { spawnSync } from "node:child_process";
import fs from "node:fs";
import { log } from "./config.js";
import { halt } from "./halt.js";
import { updateTokenLog } from "./metrics.js";

// ── runAgent() ────────────────────────────────────────────────────────────────

/**
 * Runs `opencode run --agent <agentId> <prompt>` and streams output to outputFile.
 * Returns 124 on timeout, throws HaltError on non-zero exit.
 */
export function runAgent(
  agentId: string,
  prompt: string,
  outputFile: string,
  timeoutSecs = 0,
  pipelineDir?: string,
): number {
  log(`[${agentId}] Starting...`);

  const args = ["run", "--agent", agentId, prompt];
  const opts: Parameters<typeof spawnSync>[2] = {
    stdio: ["ignore", "pipe", "pipe"],
    encoding: "buffer",
    maxBuffer: 100 * 1024 * 1024,
    ...(timeoutSecs > 0 ? { timeout: timeoutSecs * 1000 } : {}),
  };

  const result = spawnSync("opencode", args, opts);

  // Combine stdout and stderr into the output file
  const stdoutBuf = result.stdout instanceof Buffer ? result.stdout : Buffer.alloc(0);
  const stderrBuf = result.stderr instanceof Buffer ? result.stderr : Buffer.alloc(0);
  const combined = Buffer.concat([stdoutBuf, stderrBuf]);
  fs.writeFileSync(outputFile, combined);

  // Handle timeout (spawnSync signals this via error.code === 'ETIMEDOUT' or signal)
  if (result.signal === "SIGTERM" || result.error?.message?.includes("ETIMEDOUT")) {
    log(`[${agentId}] TIMEOUT after ${timeoutSecs}s`);
    return 124;
  }

  if (result.error) {
    halt(`Agent invocation failed: ${result.error.message}`, agentId, combined.toString("utf8"));
  }

  const exitCode = result.status ?? 0;

  if (exitCode === 124) {
    log(`[${agentId}] TIMEOUT after ${timeoutSecs}s`);
    return 124;
  }

  if (exitCode !== 0) {
    halt(
      `Agent invocation failed (exit ${exitCode})`,
      agentId,
      combined.toString("utf8"),
    );
  }

  // Opportunistic token cost capture
  if (pipelineDir) {
    const output = combined.toString("utf8");
    const usageMatch = output.match(
      /tokens?[: ]+\d+|input[_: ]+\d+.*output[_: ]+\d+/i,
    );
    if (usageMatch) {
      updateTokenLog(pipelineDir, agentId, usageMatch[0]);
    }
  }

  log(`[${agentId}] Complete`);
  return 0;
}
