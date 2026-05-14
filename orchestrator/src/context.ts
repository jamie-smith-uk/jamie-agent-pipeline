import fs from "node:fs";
import path from "node:path";

// ── buildContextBlock() ───────────────────────────────────────────────────────

/**
 * Returns accumulated build context, capped at contextMaxChars (most recent tasks).
 * Returns empty string if no context exists yet.
 */
export function buildContextBlock(
  pipelineDir: string,
  contextMaxChars: number,
): string {
  const contextFile = path.join(pipelineDir, "context.md");
  if (!fs.existsSync(contextFile)) return "";

  let content = fs.readFileSync(contextFile, "utf8");
  if (!content.trim()) return "";

  if (content.length > contextMaxChars) {
    const tail = content.slice(-contextMaxChars);
    const idx = tail.indexOf("\n## ");
    content =
      "*(Earlier tasks omitted — see context.md for full history)*\n\n" +
      (idx > 0 ? tail.slice(idx + 1) : tail);
  }

  return `<build-context>\n## Context from completed tasks in this phase\n\n${content}\n</build-context>`;
}

// ── buildArchDocBlock() ───────────────────────────────────────────────────────

/**
 * Returns architecture doc content, filtered for relevance if large.
 * Keywords derived from phase PRD content.
 */
export function buildArchDocBlock(
  repoRoot: string,
  archDocMaxChars: number,
  prdContent: string,
): string {
  const archPath = path.join(repoRoot, "docs", "architecture.md");
  if (!fs.existsSync(archPath)) {
    return "(docs/architecture.md not found — create it before running the pipeline)";
  }

  const content = fs.readFileSync(archPath, "utf8");
  if (content.length <= archDocMaxChars) return content;

  // Extract sections: split on ## headings
  const parts = content.split(/\n(## [^\n]+)/);
  const intro = parts[0];

  const alwaysInclude = new Set([
    "overview",
    "system",
    "component",
    "repository",
    "structure",
    "stack",
    "non-functional",
  ]);

  const skipWords = new Set([
    "this",
    "that",
    "with",
    "from",
    "have",
    "will",
    "each",
    "must",
    "should",
    "phase",
    "task",
    "file",
    "code",
    "test",
    "spec",
  ]);

  const keywords = new Set(
    [...prdContent.toLowerCase().matchAll(/\b[a-z][a-z0-9/_-]{3,}\b/g)]
      .map((m) => m[0])
      .filter((w) => !skipWords.has(w)),
  );

  const included: string[] = [];
  if (intro.trim()) included.push(intro);

  for (let i = 1; i < parts.length - 1; i += 2) {
    const heading = parts[i];
    const body = parts[i + 1] || "";
    const headingLower = heading.toLowerCase();
    const bodySnippet = body.slice(0, 400).toLowerCase();

    const shouldInclude =
      [...alwaysInclude].some((kw) => headingLower.includes(kw)) ||
      [...keywords].some(
        (kw) => headingLower.includes(kw) || bodySnippet.includes(kw),
      );

    if (shouldInclude) {
      included.push(heading + body);
    }
  }

  const result = included.join("\n");
  if (result.length < content.length) {
    return (
      "*(Architecture doc filtered for relevance — full doc at docs/architecture.md)*\n\n" +
      result
    );
  }
  return result;
}

// ── extractPhasePrd() ─────────────────────────────────────────────────────────

/**
 * Extracts the relevant phase section + related epics from docs/prd.md.
 */
export function extractPhasePrd(repoRoot: string, phase: string): string {
  const prdPath = path.join(repoRoot, "docs", "prd.md");
  if (!fs.existsSync(prdPath)) {
    return "(docs/prd.md not found — create it before running the pipeline)";
  }

  const content = fs.readFileSync(prdPath, "utf8");

  const phaseMatch = content.match(
    new RegExp(
      `(## Phase ${phase}[^\\n]*\\n[\\s\\S]*?)(?=\\n## Phase \\d+|$)`,
    ),
  );
  const phaseSection = phaseMatch ? phaseMatch[1] : "";

  // Extract unique epic IDs from the phase section
  const epicIds = [...new Set([...phaseSection.matchAll(/EP-\d+/g)].map((m) => m[0]))];

  const stories: string[] = [];
  for (const ep of epicIds) {
    const epMatch = content.match(
      new RegExp(`(### ${ep}[^\\n]*\\n[\\s\\S]*?)(?=\\n### |\\n---|$)`),
    );
    if (epMatch) stories.push(epMatch[1]);
  }

  let result = phaseSection;
  if (stories.length > 0) {
    result += "\n\n## User stories for this phase\n\n" + stories.join("\n\n");
  }

  return result.trim() || content;
}

// ── buildRepoFileTree() ───────────────────────────────────────────────────────

/**
 * Produces a compact repo file tree for the Architect (max 300 lines).
 */
export function buildRepoFileTree(repoRoot: string): string {
  const skipDirs = new Set([
    "node_modules",
    ".git",
    "dist",
    "build",
    "coverage",
    "pipeline",
    ".turbo",
    ".next",
    "__pycache__",
    ".cache",
  ]);

  const lines: string[] = [];

  function walk(dir: string, depth: number): void {
    if (lines.length > 300) return;

    const rel = path.relative(repoRoot, dir);
    const indent = "  ".repeat(depth);
    const folderName = depth === 0 ? "." : path.basename(dir);
    lines.push(`${indent}${folderName}/`);

    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }

    const dirs = entries
      .filter(
        (e) =>
          e.isDirectory() &&
          !skipDirs.has(e.name) &&
          !e.name.startsWith("."),
      )
      .sort((a, b) => a.name.localeCompare(b.name));

    const files = entries
      .filter((e) => e.isFile())
      .sort((a, b) => a.name.localeCompare(b.name));

    for (const f of files) {
      lines.push(`${indent}  ${f.name}`);
    }

    for (const d of dirs) {
      if (lines.length > 300) {
        lines.push("  ... (truncated)");
        return;
      }
      walk(path.join(dir, d.name), depth + 1);
    }
  }

  walk(repoRoot, 0);
  return lines.slice(0, 300).join("\n");
}
