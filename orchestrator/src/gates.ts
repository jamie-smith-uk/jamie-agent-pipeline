import fs from "node:fs";
import path from "node:path";
import { spawnSync, execSync } from "node:child_process";
import { log } from "./config.js";

// ── reportPasses() ────────────────────────────────────────────────────────────

/**
 * Reads first 10 lines of a report file and checks for a PASS verdict.
 * Accepted formats:
 *   "Title: ... — PASS"
 *   "# ... — PASS"
 *   "**Verdict:** PASS" / "**Result:** PASS" / "**Result: PASS**"
 *   "VERDICT: PASS"
 */
export function reportPasses(filePath: string): boolean {
  try {
    const content = fs.readFileSync(filePath, "utf8");
    const head = content.split("\n").slice(0, 10);
    const pattern =
      /(Title:|#{1,2}\s.+|VERDICT:).*\bPASS\b|\*\*(Verdict|Result)[: ]+PASS(\*\*)?/i;
    return head.some((line) => pattern.test(line));
  } catch {
    return false;
  }
}

// ── verifyImplementation() ────────────────────────────────────────────────────

/**
 * Runs tsc --noEmit, biome/eslint on in-scope files, and pnpm test.
 * Returns failure string (empty = all pass).
 */
export function verifyImplementation(
  filesInScopeJson: string,
  repoRoot: string,
  baselineFile?: string,
): string {
  let failures = "";

  // Resolve existing files from scope
  const allFiles: string[] = JSON.parse(filesInScopeJson);
  const existingFiles = allFiles.filter((f) =>
    fs.existsSync(path.join(repoRoot, f)),
  );

  // Determine linter
  let linter = "eslint";
  try {
    const pkgJson = fs.readFileSync(path.join(repoRoot, "package.json"), "utf8");
    if (pkgJson.includes('"@biomejs/biome"')) linter = "biome";
  } catch {
    // default to eslint
  }

  // Run tsc in background (via sync but interleaved with linter is fine for TS impl)
  const tscResult = spawnSync("pnpm", ["exec", "tsc", "--noEmit"], {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
  });

  if (tscResult.status !== 0) {
    failures += `=== tsc --noEmit ===\n${tscResult.stdout || ""}${tscResult.stderr || ""}\n\n`;
  }

  // Run linter on existing files
  if (existingFiles.length > 0) {
    const absFiles = existingFiles.map((f) => path.join(repoRoot, f));

    if (linter === "biome") {
      // Only biome-processable files
      const biomeFiles = absFiles.filter((f) =>
        /\.(ts|tsx|js|jsx|json|jsonc)$/.test(f),
      );
      if (biomeFiles.length > 0) {
        const biomeResult = spawnSync(
          "pnpm",
          ["exec", "biome", "check", ...biomeFiles],
          {
            cwd: repoRoot,
            encoding: "utf8",
            maxBuffer: 10 * 1024 * 1024,
          },
        );
        if (biomeResult.status !== 0) {
          failures += `=== biome ===\n${biomeResult.stdout || ""}${biomeResult.stderr || ""}\n\n`;
        }
      }
    } else {
      const eslintResult = spawnSync(
        "pnpm",
        ["exec", "eslint", ...absFiles],
        {
          cwd: repoRoot,
          encoding: "utf8",
          maxBuffer: 10 * 1024 * 1024,
        },
      );
      if (eslintResult.status !== 0) {
        failures += `=== eslint ===\n${eslintResult.stdout || ""}${eslintResult.stderr || ""}\n\n`;
      }
    }
  }

  // Determine affected packages
  const pkgFilter = getAffectedPkgFilter(filesInScopeJson);
  const testArgs = pkgFilter ? pkgFilter.split(" ") : [];

  const testResult = spawnSync("pnpm", [...testArgs, "test"], {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024,
  });

  if (testResult.status !== 0) {
    let testOut = `${testResult.stdout || ""}${testResult.stderr || ""}`;

    // Baseline filtering
    if (baselineFile && fs.existsSync(baselineFile)) {
      const filtered = filterBaselineFailures(testOut, baselineFile);
      if (filtered.isAllBaseline) {
        log(
          "pnpm test: non-zero exit but all failures are pre-existing (baseline). Skipping test gate.",
        );
        // All failures were pre-existing — treat as pass
      } else {
        failures += `=== pnpm test ===\n${filtered.output}\n\n`;
      }
    } else {
      failures += `=== pnpm test ===\n${testOut}\n\n`;
    }
  }

  return failures;
}

interface BaselineFilterResult {
  isAllBaseline: boolean;
  output: string;
}

function filterBaselineFailures(
  rawOutput: string,
  baselineFile: string,
): BaselineFilterResult {
  let baseline: Set<string>;
  try {
    const lines = fs.readFileSync(baselineFile, "utf8").split("\n");
    baseline = new Set(lines.map((l) => l.trim()).filter(Boolean));
  } catch {
    baseline = new Set();
  }

  if (baseline.size === 0) {
    return { isAllBaseline: false, output: rawOutput };
  }

  const failFilesNow = new Set(
    [...rawOutput.matchAll(/^\s*FAIL\s+(\S+)/gm)].map((m) => m[1]),
  );
  const failTestsNow = new Set(
    [...rawOutput.matchAll(/^\s*×\s+(.+?)\s+\d+ms/gm)].map((m) => m[1]),
  );
  const allNow = new Set([...failFilesNow, ...failTestsNow]);

  const newFailures = new Set([...allNow].filter((f) => !baseline.has(f)));

  if (newFailures.size === 0) {
    const note =
      "NOTE: pnpm test returned non-zero but ALL failures were pre-existing " +
      "before this task's implementation (recorded in baseline-failures.txt). " +
      "These are infrastructure or unrelated-package failures — not caused by " +
      "this task. Gate treating test step as PASS.\n\n" +
      "Pre-existing failures:\n" +
      [...baseline]
        .sort()
        .map((f) => `  - ${f}`)
        .join("\n");
    return { isAllBaseline: true, output: note };
  }

  const newList = [...newFailures]
    .sort()
    .map((f) => `  - ${f}`)
    .join("\n");
  return {
    isAllBaseline: false,
    output: `NEW failures (not in baseline):\n${newList}\n\nFull test output:\n${rawOutput}`,
  };
}

// ── getAffectedPkgFilter() ────────────────────────────────────────────────────

export function getAffectedPkgFilter(filesInScopeJson: string): string {
  const files: string[] = JSON.parse(filesInScopeJson);
  const pkgs = new Set<string>();
  for (const f of files) {
    const m = f.match(/^packages\/([^/]+)\//);
    if (m) pkgs.add(`@{project-name}/${m[1]}`);
  }
  if (pkgs.size === 0) return "";
  return [...pkgs]
    .sort()
    .map((p) => `--filter ${p}`)
    .join(" ");
}

export function getExpandedFileList(filesInScopeJson: string): string {
  const files: string[] = JSON.parse(filesInScopeJson);
  return files.length > 0 ? files.join(" ") : "packages/";
}

// ── checkScopeCompliance() ────────────────────────────────────────────────────

/**
 * Checks that all git-modified and new files (excluding pipeline/ and __tests__/)
 * are listed in filesInScopeJson. Returns violating paths (empty = none).
 */
export function checkScopeCompliance(
  filesInScopeJson: string,
  repoRoot: string,
): string {
  const filesInScope: string[] = JSON.parse(filesInScopeJson);
  const scopeSet = new Set(filesInScope);

  // Always-allowed support files
  const alwaysAllowed = new Set([
    "packages/shared/src/types.ts",
    "packages/shared/src/env.ts",
  ]);

  // Get modified files from git
  const diffResult = spawnSync(
    "git",
    ["-C", repoRoot, "diff", "--name-only", "HEAD"],
    { encoding: "utf8" },
  );
  const untrackedResult = spawnSync(
    "git",
    ["-C", repoRoot, "ls-files", "--others", "--exclude-standard", repoRoot],
    { encoding: "utf8" },
  );

  const changedFiles = [
    ...(diffResult.stdout || "").split("\n").filter(Boolean),
    ...(untrackedResult.stdout || "")
      .split("\n")
      .filter(Boolean)
      .map((f) => f.replace(`${repoRoot}/`, "")),
  ];

  const violations: string[] = [];
  for (const f of changedFiles) {
    if (!f) continue;
    if (f.startsWith("pipeline/")) continue;
    if (f.includes("__tests__")) continue;
    if (f.endsWith(".tsbuildinfo")) continue;
    if (alwaysAllowed.has(f)) continue;
    if (f.startsWith("packages/shared/dist/")) continue;
    if (!scopeSet.has(f)) {
      violations.push(f);
    }
  }

  return violations.join("\n");
}

// ── revertScopeViolations() ───────────────────────────────────────────────────

/**
 * Reverts files that were changed outside of scope.
 * Tracked files: git checkout HEAD -- <file>
 * New files: rm -f <file>
 */
export function revertScopeViolations(
  violations: string,
  repoRoot: string,
): void {
  const files = violations.split("\n").filter(Boolean);
  for (const vf of files) {
    // Check if tracked
    const tracked = spawnSync(
      "git",
      ["-C", repoRoot, "ls-files", "--error-unmatch", vf],
      { encoding: "utf8" },
    );
    if (tracked.status === 0) {
      const checkout = spawnSync(
        "git",
        ["-C", repoRoot, "checkout", "HEAD", "--", vf],
        { encoding: "utf8" },
      );
      if (checkout.status !== 0) {
        log(
          `  WARNING: could not revert ${vf} via git checkout (index locked?) — using rm fallback`,
        );
        try {
          fs.unlinkSync(path.join(repoRoot, vf));
        } catch {
          // ignore
        }
      }
    } else {
      try {
        fs.unlinkSync(path.join(repoRoot, vf));
      } catch {
        // ignore
      }
    }
    log(`  Reverted out-of-scope: ${vf}`);
  }
}
