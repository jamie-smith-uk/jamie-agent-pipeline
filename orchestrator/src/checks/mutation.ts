import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { log } from "../config.js";

// Security-critical patterns to search for (in priority order)
const SEC_PATTERNS = [
  /ALLOWED_CHAT_ID|allowed_chat|whitelist/,
  /authenticate|authorize|isAuthorized/,
  /\$[0-9]/,
  /validateInput|isValid|sanitize/,
];

// ── runMutationTests() ────────────────────────────────────────────────────────

/**
 * Mutation testing for security-sensitive tasks.
 * Makes targeted mutations to security-critical lines and checks if tests catch them.
 * Results written to $TASK_DIR/mutation-report.md. Warnings only — not a hard FAIL gate.
 */
export function runMutationTests(
  repoRoot: string,
  taskId: string,
  taskDir: string,
  filesInScopeJson: string,
): void {
  const files: string[] = JSON.parse(filesInScopeJson);

  let mutationsTotal = 0;
  let mutationsCaught = 0;
  const survivedList: string[] = [];

  for (const f of files) {
    if (!f) continue;
    const full = path.join(repoRoot, f);
    if (!fs.existsSync(full)) continue;

    let content: string;
    try {
      content = fs.readFileSync(full, "utf8");
    } catch {
      continue;
    }

    const lines = content.split("\n");
    let lineNum: number | null = null;

    // Find first line matching a security-critical pattern (priority order)
    for (const pat of SEC_PATTERNS) {
      for (let i = 0; i < lines.length; i++) {
        if (pat.test(lines[i])) {
          lineNum = i; // 0-indexed
          break;
        }
      }
      if (lineNum !== null) break;
    }

    if (lineNum === null) continue;

    mutationsTotal++;

    // Mutate: comment out the matched line
    const mutated = [...lines];
    mutated[lineNum] = `// MUTATED: ${lines[lineNum]}`;
    fs.writeFileSync(full, mutated.join("\n"));

    const testResult = spawnSync("pnpm", ["test"], {
      cwd: repoRoot,
      encoding: "utf8",
      timeout: 60000,
    });

    if (testResult.status === 0) {
      survivedList.push(`  - ${f} line ${lineNum + 1}`);
      log(`  ⚠ Mutation survived: ${f}:${lineNum + 1}`);
    } else {
      mutationsCaught++;
      log(`  ✓ Mutation caught: ${f}:${lineNum + 1}`);
    }

    // Restore original
    const restored = mutated.map((l) => l.replace("// MUTATED: ", ""));
    fs.writeFileSync(full, restored.join("\n"));
  }

  // Write report
  let reportContent: string;

  if (mutationsTotal === 0) {
    reportContent = `Title: Mutation Report — ${taskId} — WARN\n\nNo security-critical patterns found to mutate.\nVerify that security paths are explicitly tested in __tests__/ files.\n`;
  } else if (mutationsCaught === mutationsTotal) {
    reportContent = `Title: Mutation Report — ${taskId} — PASS\n\nAll ${mutationsTotal} mutation(s) caught by tests. Security paths are covered.\n`;
  } else {
    const survived = mutationsTotal - mutationsCaught;
    reportContent =
      `Title: Mutation Report — ${taskId} — WARN\n\n` +
      `${survived} of ${mutationsTotal} mutation(s) survived — these security paths may lack test coverage:\n\n` +
      survivedList.join("\n") +
      "\n\nAdd tests that verify the security check is enforced when removed.\n";
  }

  fs.writeFileSync(path.join(taskDir, "mutation-report.md"), reportContent);
}
