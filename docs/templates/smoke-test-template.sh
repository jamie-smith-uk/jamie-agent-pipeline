#!/bin/bash

# Smoke tests for {PROJECT_NAME} — Phase N
# Run by AG-08 Validator as part of phase sign-off.
#
# Copy this file to smoke-tests/phase-N.sh in your project and fill in the tests.
#
# Usage:   ./smoke-tests/phase-1.sh
# Expects: DATABASE_URL set, application dependencies installed
#
# Each check() call runs a command. Exit 0 = pass, non-zero = fail.
# Keep total runtime under 30 seconds. Smoke tests verify integration,
# not unit behaviour — test the seams between components.
#
# Exit code: 0 if all checks pass, 1 if any fail.

set -euo pipefail

PASS=0
FAIL=0

check() {
  local description="$1"
  shift
  if "$@" > /dev/null 2>&1; then
    echo "  ✓ $description"
    PASS=$(( PASS + 1 ))
  else
    echo "  ✗ $description"
    FAIL=$(( FAIL + 1 ))
  fi
}

echo "Smoke tests — {PROJECT_NAME} Phase N"
echo "======================================"

# ── Database ────────────────────────────────────────────────────────────────────
# check "Database is reachable" psql "$DATABASE_URL" -c "SELECT 1"
# check "Migrations applied" psql "$DATABASE_URL" -c "SELECT 1 FROM schema_migrations LIMIT 1"

# ── API / Server ────────────────────────────────────────────────────────────────
# check "Server responds on health endpoint" curl -sf http://localhost:3000/health

# ── Key functionality (add one check per exit criterion) ────────────────────────
# check "Exit criterion description" your-command-here

# ── Results ─────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
