#!/bin/bash

# Pre-flight check for jamie-agent-pipeline
# Verifies the environment is correctly configured before running a phase.
#
# Usage:
#   ./orchestrator/check-pipeline.sh             — environment checks only
#   ./orchestrator/check-pipeline.sh --calibrate — also runs a live agent call
#
# Run this after setup-pipeline.sh and before ./orchestrator/run-phase.sh --phase 1

set -euo pipefail

CALIBRATE=false
for arg in "$@"; do
  [[ "$arg" == "--calibrate" ]] && CALIBRATE=true
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  source "$REPO_ROOT/.env"
  set +a
fi

PASS=0
FAIL=0
WARN=0

ok()   { echo "  ✓ $*"; PASS=$(( PASS + 1 )); }
fail() { echo "  ✗ $*"; FAIL=$(( FAIL + 1 )); }
warn() { echo "  ! $*"; WARN=$(( WARN + 1 )); }

echo ""
echo "Pipeline pre-flight check"
echo "========================="
echo ""

# ── Required tools ────────────────────────────────────────────────────────────
echo "Tools:"
command -v opencode > /dev/null 2>&1 && ok "opencode installed" \
  || fail "opencode not found — install from https://opencode.ai"
command -v python3  > /dev/null 2>&1 && ok "python3 installed" \
  || fail "python3 not found"
command -v pnpm     > /dev/null 2>&1 && ok "pnpm installed" \
  || fail "pnpm not found — install with: npm install -g pnpm"
command -v git      > /dev/null 2>&1 && ok "git installed" \
  || fail "git not found"
command -v curl     > /dev/null 2>&1 && ok "curl installed" \
  || fail "curl not found"

# ── Environment variables ─────────────────────────────────────────────────────
echo ""
echo "Environment:"
[ -f "$REPO_ROOT/.env" ] && ok ".env file exists" || warn ".env not found — run setup-pipeline.sh"

[ -n "${ANTHROPIC_API_KEY:-}" ]       && ok "ANTHROPIC_API_KEY set"       || fail "ANTHROPIC_API_KEY not set"
[ -n "${TELEGRAM_BOT_TOKEN:-}" ]      && ok "TELEGRAM_BOT_TOKEN set"      || fail "TELEGRAM_BOT_TOKEN not set"
[ -n "${TELEGRAM_ALLOWED_CHAT_ID:-}" ] && ok "TELEGRAM_ALLOWED_CHAT_ID set" || fail "TELEGRAM_ALLOWED_CHAT_ID not set"
[ -n "${POSTGRES_USER:-}" ]           && ok "POSTGRES_USER set"           || warn "POSTGRES_USER not set (needed for DB tasks)"
[ -n "${DATABASE_URL:-}" ] || [ -n "${POSTGRES_HOST:-}" ] \
  && ok "Database config present" || warn "No database config (needed for DB tasks)"

# ── Project docs ──────────────────────────────────────────────────────────────
echo ""
echo "Project docs:"
[ -f "$REPO_ROOT/docs/prd.md" ]          && ok "docs/prd.md exists"          || fail "docs/prd.md not found — create it before running the pipeline"
[ -f "$REPO_ROOT/docs/architecture.md" ] && ok "docs/architecture.md exists" || fail "docs/architecture.md not found"

# Check PRD has at least one phase defined
if [ -f "$REPO_ROOT/docs/prd.md" ]; then
  if grep -q "## Phase" "$REPO_ROOT/docs/prd.md"; then
    ok "PRD contains at least one phase"
  else
    fail "PRD has no phase sections — add '## Phase 1 — ...' sections"
  fi
fi

# Check smoke tests
[ -f "$REPO_ROOT/smoke-tests/phase-1.sh" ] \
  && ok "smoke-tests/phase-1.sh exists" \
  || warn "smoke-tests/phase-1.sh not found — AG-08 Validator will note its absence"

# ── Telegram connectivity ─────────────────────────────────────────────────────
echo ""
echo "Telegram:"
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  TELE_RESPONSE=$(curl -sf "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null || echo "")
  if echo "$TELE_RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
    BOT_NAME=$(echo "$TELE_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['username'])" 2>/dev/null || echo "unknown")
    ok "Bot token valid (@$BOT_NAME)"
  else
    fail "Bot token invalid or Telegram unreachable"
  fi
else
  warn "Skipping Telegram check (TELEGRAM_BOT_TOKEN not set)"
fi

# ── Git state ─────────────────────────────────────────────────────────────────
echo ""
echo "Git:"
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  ok "Inside a git repository"
  if git -C "$REPO_ROOT" diff --quiet && git -C "$REPO_ROOT" diff --cached --quiet; then
    ok "Working tree is clean"
  else
    warn "Uncommitted changes present — consider committing before running the pipeline"
  fi
else
  fail "Not inside a git repository"
fi

# ── opencode agents ───────────────────────────────────────────────────────────
echo ""
echo "Agents:"
AGENT_COUNT=$(ls "$REPO_ROOT/.opencode/agents/"ag-*.md 2>/dev/null | wc -l | tr -d ' ')
if [ "$AGENT_COUNT" -ge 8 ]; then
  ok "$AGENT_COUNT agent files found in .opencode/agents/"
else
  fail "Expected 8+ agent files, found $AGENT_COUNT — run sync-pipeline.sh"
fi

# ── Agent calibration (--calibrate only) ─────────────────────────────────────
if [ "$CALIBRATE" = true ]; then
  echo ""
  echo "Agent calibration:"
  if [ "$FAIL" -gt 0 ]; then
    warn "Skipping calibration — fix failed checks above first"
  elif ! command -v opencode > /dev/null 2>&1; then
    warn "Skipping calibration — opencode not installed"
  else
    echo "  Running test agent call (AG-02 Reviewer with minimal prompt)..."
    CAL_OUTPUT=$(mktemp)
    CAL_EXIT=0
    timeout 60 opencode run \
      --agent "ag-02-reviewer" \
      "Reply with the single word READY and nothing else. Do not write any files." \
      > "$CAL_OUTPUT" 2>&1 || CAL_EXIT=$?

    if [ $CAL_EXIT -eq 0 ] && grep -qi "READY" "$CAL_OUTPUT" 2>/dev/null; then
      ok "Agent responded correctly — pipeline is calibrated"
    elif [ $CAL_EXIT -eq 0 ]; then
      warn "Agent responded but output did not contain READY — check agent config"
      warn "Output: $(head -3 "$CAL_OUTPUT")"
    else
      fail "Agent call failed (exit $CAL_EXIT) — check opencode config and API key"
      echo "    Output: $(head -5 "$CAL_OUTPUT")"
    fi
    rm -f "$CAL_OUTPUT"
  fi
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "========================="
echo "Results: $PASS passed, $WARN warnings, $FAIL failed"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "Fix the failed checks before running the pipeline."
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo "Pipeline can run but review the warnings above."
  exit 0
else
  if [ "$CALIBRATE" = true ]; then
    echo "All checks passed and agent is calibrated — ready to run:"
  else
    echo "All checks passed — ready to run (or use --calibrate for a live agent test):"
  fi
  echo "  ./orchestrator/run-phase.sh --phase 1"
  exit 0
fi
