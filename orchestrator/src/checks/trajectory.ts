import fs from "node:fs";
import path from "node:path";
import { log } from "../config.js";

// ── checkTesterTrajectory() ───────────────────────────────────────────────────

/**
 * Verifies the Tester wrote real test files with assertions.
 * Logs warnings — does not halt. Called after RED phase.
 */
export function checkTesterTrajectory(
  repoRoot: string,
  taskDir: string,
  testsWrittenFile: string,
  acCount: number,
): void {
  // Get sentinel mtime
  let sentinelTime = 0;
  try {
    sentinelTime = Math.floor(fs.statSync(testsWrittenFile).mtimeMs / 1000);
  } catch {
    sentinelTime = 0;
  }
  const windowStart = sentinelTime - 600; // 10 minutes before sentinel

  let testCount = 0;
  const filesWithoutAssertions: string[] = [];

  // Find test files
  const testFiles = findTestFiles(repoRoot);

  for (const tf of testFiles) {
    let tfTime = 0;
    try {
      tfTime = Math.floor(fs.statSync(tf).mtimeMs / 1000);
    } catch {
      continue;
    }
    if (tfTime < windowStart) continue;

    testCount++;

    try {
      const content = fs.readFileSync(tf, "utf8");
      if (!/expect\(|it\(|test\(|describe\(/.test(content)) {
        filesWithoutAssertions.push(path.basename(tf));
      }
    } catch {
      // ignore
    }
  }

  const issues: string[] = [];

  if (testCount === 0) {
    issues.push(
      "No test files found after RED phase — Tester may not have written any tests",
    );
  } else {
    if (filesWithoutAssertions.length > 0) {
      issues.push(
        `Test files with no assertions: ${filesWithoutAssertions.join(", ")}`,
      );
    }
    if (acCount > 0 && testCount < acCount) {
      issues.push(
        `${testCount} test file(s) for ${acCount} acceptance criteria — some ACs may be uncovered`,
      );
    }
  }

  if (issues.length > 0) {
    log("  Tester trajectory warnings:");
    for (const issue of issues) {
      log(`    ! ${issue}`);
    }
  }
}

function findTestFiles(repoRoot: string): string[] {
  const results: string[] = [];

  function walk(dir: string): void {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (entry.name === "node_modules") continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else if (
        entry.isFile() &&
        (entry.name.endsWith(".test.ts") || entry.name.endsWith(".spec.ts"))
      ) {
        results.push(full);
      }
    }
  }

  walk(repoRoot);
  return results;
}

// ── checkSecurityTrajectory() ─────────────────────────────────────────────────

/**
 * Verifies the Security PASS report mentions all known rules.
 * Logs warnings — does not halt. Called after security PASS.
 */
export function checkSecurityTrajectory(
  repoRoot: string,
  taskDir: string,
): void {
  const secReport = path.join(taskDir, "security-report.md");
  const rulesFile = path.join(repoRoot, ".opencode", "agents", "security-rules.md");

  if (!fs.existsSync(secReport) || !fs.existsSync(rulesFile)) return;

  let reportContent: string;
  let rulesContent: string;
  try {
    reportContent = fs.readFileSync(secReport, "utf8").toLowerCase();
    rulesContent = fs.readFileSync(rulesFile, "utf8");
  } catch {
    return;
  }

  const ruleNames = [...rulesContent.matchAll(/### ([^\n]+)/g)].map(
    (m) => m[1],
  );
  const missing = ruleNames.filter(
    (r) => !reportContent.includes(r.toLowerCase()),
  );

  if (missing.length > 0) {
    const preview = missing.slice(0, 4).join(", ");
    const ellipsis = missing.length > 4 ? "..." : "";
    log(
      `  Security trajectory warning: ${missing.length} rule(s) not mentioned in security report: ${preview}${ellipsis}`,
    );
  }
}
