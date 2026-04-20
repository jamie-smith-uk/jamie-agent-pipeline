#!/bin/bash

set -euo pipefail

# ── Pipeline Sync ─────────────────────────────────────────────────────────────
# Usage: ./orchestrator/sync-pipeline.sh --target /path/to/project

PIPELINE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET=""

# ── Args ─────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --target) TARGET="$2"; shift 2 ;;
    --target=*) TARGET="${1#*=}"; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "Usage: ./orchestrator/sync-pipeline.sh --target /path/to/project"
  exit 1
fi

if [ ! -d "$TARGET" ]; then
  echo "Error: target directory does not exist: $TARGET"
  exit 1
fi

log() { echo "[sync] $*"; }

# ── Detect project name from existing agent files ─────────────────────────────
PROJECT_NAME=""
PROJECT_SLUG=""

for candidate in "$TARGET/agents/ag-01-architect.md" "$TARGET/.opencode/agents/ag-01-architect.md"; do
  if [ -f "$candidate" ]; then
    # Extract name from the "You are the Architect for X" line
    PROJECT_NAME=$(grep -m1 "You are the Architect for" "$candidate" 2>/dev/null | sed 's/.*You are the Architect for \(.*\),.*/\1/' || true)
    if [ -n "$PROJECT_NAME" ]; then
      break
    fi
  fi
done

if [ -z "$PROJECT_NAME" ]; then
  echo "Error: could not detect project name from existing agent files in $TARGET"
  echo "Expected agents/ag-01-architect.md or .opencode/agents/ag-01-architect.md to contain:"
  echo "  \"You are the Architect for <Project Name>,...\""
  exit 1
fi

PROJECT_SLUG=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')

# ── Substitution helper ───────────────────────────────────────────────────────
substitute() {
  local src="$1" dst="$2"
  sed \
    -e "s/{PROJECT_NAME}/$PROJECT_NAME/g" \
    -e "s/{project-name}/$PROJECT_SLUG/g" \
    "$src" > "$dst"
}

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "Pipeline Sync"
echo "========================================"
echo "  Project:  $PROJECT_NAME ($PROJECT_SLUG)"
echo "  Source:   $PIPELINE_REPO"
echo "  Target:   $TARGET"
echo ""
echo "Will update:"
echo "  agents/*.md              → target/agents/ and target/.opencode/agents/"
echo "  .opencode/config.json    → target/.opencode/config.json"
echo "  .opencode/rules/*.md     → target/.opencode/rules/"
echo "  orchestrator/*.sh        → target/orchestrator/ (executable)"
echo ""
echo "Will NOT touch:"
echo "  docs/         (project-specific)"
echo "  .env          (project-specific)"
echo "  pipeline/     (runtime working files)"
echo "  migrations/   (project-specific)"
echo ""

# ── Confirmation ──────────────────────────────────────────────────────────────
read -r -p "Proceed? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

echo ""

# ── Sync agent files ──────────────────────────────────────────────────────────
log "Syncing agent files..."
mkdir -p "$TARGET/agents" "$TARGET/.opencode/agents"

for f in "$PIPELINE_REPO"/agents/*.md; do
  filename="$(basename "$f")"
  substitute "$f" "$TARGET/agents/$filename"
  substitute "$f" "$TARGET/.opencode/agents/$filename"
  log "  → agents/$filename"
done

# ── Sync opencode config and rules ────────────────────────────────────────────
log "Syncing opencode config..."
mkdir -p "$TARGET/.opencode/rules"

cp "$PIPELINE_REPO/.opencode/config.json" "$TARGET/.opencode/config.json"
log "  → .opencode/config.json"

cp "$PIPELINE_REPO/.opencode/rules/security.md" "$TARGET/.opencode/rules/security.md"
log "  → .opencode/rules/security.md"

cp "$PIPELINE_REPO/.opencode/rules/typescript.md" "$TARGET/.opencode/rules/typescript.md"
log "  → .opencode/rules/typescript.md"

# ── Sync orchestrator scripts ─────────────────────────────────────────────────
log "Syncing orchestrator scripts..."
mkdir -p "$TARGET/orchestrator"

substitute "$PIPELINE_REPO/orchestrator/run-phase.sh" "$TARGET/orchestrator/run-phase.sh"
chmod +x "$TARGET/orchestrator/run-phase.sh"
log "  → orchestrator/run-phase.sh"

substitute "$PIPELINE_REPO/orchestrator/telegram-gate.sh" "$TARGET/orchestrator/telegram-gate.sh"
chmod +x "$TARGET/orchestrator/telegram-gate.sh"
log "  → orchestrator/telegram-gate.sh"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "Sync complete"
echo "========================================"
echo ""
echo "Review the changes before committing:"
echo "  cd $TARGET && git diff"
echo ""
