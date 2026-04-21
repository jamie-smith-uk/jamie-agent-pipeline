#!/bin/bash

set -euo pipefail

# ── {PROJECT_NAME} Pipeline Setup ────────────────────────────────────────────
# Usage: ./orchestrator/setup-pipeline.sh --project "My Project" --target /path/to/project

PIPELINE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME=""
TARGET=""

# ── Args ─────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --project) PROJECT_NAME="$2"; shift 2 ;;
    --project=*) PROJECT_NAME="${1#*=}"; shift ;;
    --target) TARGET="$2"; shift 2 ;;
    --target=*) TARGET="${1#*=}"; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [ -z "$PROJECT_NAME" ] || [ -z "$TARGET" ]; then
  echo "Usage: ./orchestrator/setup-pipeline.sh --project \"My Project\" --target /path/to/project"
  exit 1
fi

# ── Derive slug ───────────────────────────────────────────────────────────────
PROJECT_SLUG=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')

log() { echo "[setup] $*"; }

log "Project:  $PROJECT_NAME"
log "Slug:     $PROJECT_SLUG"
log "Target:   $TARGET"
echo ""

# ── Create directories ────────────────────────────────────────────────────────
log "Creating directory structure..."
mkdir -p \
  "$TARGET/.opencode/agents" \
  "$TARGET/.opencode/rules" \
  "$TARGET/orchestrator" \
  "$TARGET/docs" \
  "$TARGET/pipeline" \
  "$TARGET/migrations" \
  "$TARGET/smoke-tests"

# ── Substitution helper ───────────────────────────────────────────────────────
# Use | as delimiter so project names containing / don't break sed
substitute() {
  local src="$1" dst="$2"
  sed \
    -e "s|{PROJECT_NAME}|$PROJECT_NAME|g" \
    -e "s|{project-name}|$PROJECT_SLUG|g" \
    "$src" > "$dst"
}

# ── Copy agent files ──────────────────────────────────────────────────────────
log "Copying agent files..."
for f in "$PIPELINE_REPO"/.opencode/agents/*.md; do
  filename="$(basename "$f")"
  substitute "$f" "$TARGET/.opencode/agents/$filename"
done

# ── Copy opencode config and rules ───────────────────────────────────────────
log "Copying opencode config..."
cp "$PIPELINE_REPO/.opencode/config.json" "$TARGET/.opencode/config.json"
cp "$PIPELINE_REPO/.opencode/rules/security.md" "$TARGET/.opencode/rules/security.md"
cp "$PIPELINE_REPO/.opencode/rules/typescript.md" "$TARGET/.opencode/rules/typescript.md"

# ── Copy orchestrator scripts ─────────────────────────────────────────────────
log "Copying orchestrator scripts..."
for script in run-phase.sh run-task.sh check-pipeline.sh; do
  substitute "$PIPELINE_REPO/orchestrator/$script" "$TARGET/orchestrator/$script"
  chmod +x "$TARGET/orchestrator/$script"
done

mkdir -p "$TARGET/backlog"
cp "$PIPELINE_REPO/backlog/README.md" "$TARGET/backlog/README.md" 2>/dev/null || true

# ── Copy doc templates ────────────────────────────────────────────────────────
log "Copying doc templates..."
TMPL="$PIPELINE_REPO/docs/templates"

if [ -f "$TMPL/prd-template.md" ]; then
  substitute "$TMPL/prd-template.md" "$TARGET/docs/prd.md"
  log "  → docs/prd.md"
else
  log "  ! docs/templates/prd-template.md not found — skipping docs/prd.md"
fi

if [ -f "$TMPL/architecture-template.md" ]; then
  substitute "$TMPL/architecture-template.md" "$TARGET/docs/architecture.md"
  log "  → docs/architecture.md"
else
  log "  ! docs/templates/architecture-template.md not found — skipping docs/architecture.md"
fi

if [ -f "$TMPL/env-example.txt" ]; then
  if [ ! -f "$TARGET/.env.example" ]; then
    substitute "$TMPL/env-example.txt" "$TARGET/.env.example"
    log "  → .env.example"
  else
    log "  ! .env.example already exists — skipping"
  fi
else
  log "  ! docs/templates/env-example.txt not found — skipping .env.example"
fi

if [ -f "$TMPL/smoke-test-template.sh" ]; then
  substitute "$TMPL/smoke-test-template.sh" "$TARGET/smoke-tests/phase-1.sh"
  chmod +x "$TARGET/smoke-tests/phase-1.sh"
  log "  → smoke-tests/phase-1.sh"
else
  log "  ! docs/templates/smoke-test-template.sh not found — skipping smoke-tests/phase-1.sh"
fi

# ── Create .gitignore ─────────────────────────────────────────────────────────
if [ ! -f "$TARGET/.gitignore" ]; then
  log "Creating .gitignore..."
  cat > "$TARGET/.gitignore" <<'EOF'
# Environment
.env
.env.*
!.env.example

# Dependencies
node_modules/

# Build output
dist/
build/

# Pipeline working files
pipeline/

# Logs
*.log

# OS
.DS_Store
Thumbs.db
EOF
fi

# ── API key setup ─────────────────────────────────────────────────────────────
echo ""
read -r -p "Do you want to set your Anthropic API key now? (y/n) " configure_keys

if [[ "$configure_keys" =~ ^[Yy]$ ]]; then
  echo ""
  read -rs -p "  ANTHROPIC_API_KEY: " ANTHROPIC_API_KEY; echo
  echo ""

  if [ -f "$TARGET/.env" ]; then
    log ".env already exists — skipping (add ANTHROPIC_API_KEY manually)"
  else
    cat > "$TARGET/.env" <<EOF
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY

POSTGRES_USER=
POSTGRES_PASSWORD=
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_DB=$PROJECT_SLUG
EOF
    log "Created .env"
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "Pipeline set up for: $PROJECT_NAME"
echo "Target: $TARGET"
echo "========================================"
echo ""
echo "Next steps:"
echo ""
echo "  1. cd $TARGET"
if [[ ! "$configure_keys" =~ ^[Yy]$ ]]; then
  echo "  2. Create .env and fill in your values:"
  echo "       ANTHROPIC_API_KEY="
  echo "       POSTGRES_USER= / POSTGRES_PASSWORD= / POSTGRES_HOST= / POSTGRES_PORT= / POSTGRES_DB="
  echo ""
else
  echo "  2. Fill in the remaining .env values:"
  echo "       POSTGRES_USER= / POSTGRES_PASSWORD= / POSTGRES_HOST= / POSTGRES_PORT= / POSTGRES_DB="
  echo ""
fi
if [ ! -f "$TARGET/docs/prd.md" ]; then
  echo "  3. Create docs/prd.md with your product requirements"
else
  echo "  3. Fill in docs/prd.md with your product requirements"
fi
if [ ! -f "$TARGET/docs/architecture.md" ]; then
  echo "  4. Create docs/architecture.md with your architecture decisions"
else
  echo "  4. Fill in docs/architecture.md with your architecture decisions"
fi
echo "  5. Run: ./orchestrator/run-phase.sh --phase 1"
echo ""
