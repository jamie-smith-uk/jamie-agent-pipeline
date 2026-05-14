import fs from "node:fs";
import path from "node:path";
import { HaltError } from "./types.js";
import { log } from "./config.js";

// ── halt() ────────────────────────────────────────────────────────────────────

/**
 * Throws a HaltError. The top-level index.ts catches it, writes HALT.md, and exits 1.
 */
export function halt(reason: string, agent: string, detail: string): never {
  throw new HaltError(reason, agent, detail);
}

/**
 * Writes HALT.md to repoRoot and exits the process with code 1.
 * Called only from the top-level catch in index.ts.
 */
export function writeHaltAndExit(
  err: HaltError,
  repoRoot: string,
  phase: string,
): never {
  const content = `# HALT

**Reason:** ${err.reason}
**Agent:** ${err.agent}
**Phase:** ${phase}
**Time:** ${new Date().toISOString().replace(/\.\d{3}Z$/, "Z")}

## Detail

${err.detail}
`;
  try {
    fs.writeFileSync(path.join(repoRoot, "HALT.md"), content);
  } catch {
    // Best-effort
  }

  // Terminal bell
  process.stdout.write("");

  log(`PIPELINE HALTED: ${err.reason} (agent: ${err.agent})`);
  process.stderr.write("=== HALT DETAIL ===\n");
  process.stderr.write(`${err.detail}\n`);
  process.stderr.write("===================\n");

  process.exit(1);
}
