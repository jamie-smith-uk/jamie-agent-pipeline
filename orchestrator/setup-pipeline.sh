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
  "$TARGET/agents" \
  "$TARGET/.opencode/agents" \
  "$TARGET/.opencode/rules" \
  "$TARGET/orchestrator" \
  "$TARGET/docs" \
  "$TARGET/pipeline" \
  "$TARGET/migrations"

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
substitute "$PIPELINE_REPO/orchestrator/run-phase.sh" "$TARGET/orchestrator/run-phase.sh"
substitute "$PIPELINE_REPO/orchestrator/telegram-gate.sh" "$TARGET/orchestrator/telegram-gate.sh"
chmod +x "$TARGET/orchestrator/run-phase.sh"
chmod +x "$TARGET/orchestrator/telegram-gate.sh"

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

# ── Telegram and API key setup ────────────────────────────────────────────────
echo ""
read -r -p "Do you want to configure Telegram and API keys now? (y/n) " configure_keys

if [[ "$configure_keys" =~ ^[Yy]$ ]]; then
  echo ""
  # Use silent read (-s) so tokens don't appear in terminal scrollback
  read -rs -p "  TELEGRAM_BOT_TOKEN:       " TELEGRAM_BOT_TOKEN;       echo
  read -rs -p "  TELEGRAM_ALLOWED_CHAT_ID: " TELEGRAM_ALLOWED_CHAT_ID; echo
  read -rs -p "  ANTHROPIC_API_KEY:         " ANTHROPIC_API_KEY;        echo
  echo ""

  if [ -f "$TARGET/.env" ]; then
    log ".env already exists — skipping (edit it manually to add these values)"
  else
    cat > "$TARGET/.env" <<EOF
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY

TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_ALLOWED_CHAT_ID=$TELEGRAM_ALLOWED_CHAT_ID

TODOIST_API_TOKEN=

POSTGRES_USER=
POSTGRES_PASSWORD=
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_DB=$PROJECT_SLUG
EOF
    log "Created .env"
  fi
else
  echo ""
  echo "  To create a Telegram bot:"
  echo "    1. Open Telegram and search for @BotFather"
  echo "    2. Send: /newbot"
  echo "    3. Follow the prompts — BotFather will give you a TELEGRAM_BOT_TOKEN"
  echo "    4. Message your new bot, then visit:"
  echo "       https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates"
  echo "       Your chat ID is in result[0].message.chat.id"
  echo "    5. Add both values to $TARGET/.env"
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
  echo "       TELEGRAM_BOT_TOKEN="
  echo "       TELEGRAM_ALLOWED_CHAT_ID="
  echo "       TODOIST_API_TOKEN="
  echo "       POSTGRES_USER= / POSTGRES_PASSWORD= / POSTGRES_HOST= / POSTGRES_PORT= / POSTGRES_DB="
  echo ""
else
  echo "  2. Fill in the remaining .env values:"
  echo "       TODOIST_API_TOKEN="
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
