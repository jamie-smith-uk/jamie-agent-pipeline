#!/bin/bash

set -euo pipefail

# ── {PROJECT_NAME} Pipeline Runner ──────────────────────────────────────────────────
# Usage: ./orchestrator/run-phase.sh --phase 1
# Requires: opencode CLI, ANTHROPIC_API_KEY, TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_CHAT_ID

# ── Args ─────────────────────────────────────────────────────────────────────
PHASE=""
for arg in "$@"; do
  case $arg in
    --phase=*) PHASE="${arg#*=}" ;;
    --phase) PHASE="${2}" ; shift ;;
  esac
done

if [ -z "$PHASE" ]; then
  echo "Usage: ./orchestrator/run-phase.sh --phase 1"
  exit 1
fi

# ── Paths ────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPELINE_DIR="$REPO_ROOT/pipeline/phase-$PHASE"
AGENTS_DIR="$REPO_ROOT/agents"

# Load .env if present (exports all vars so they're available to child processes)
if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  # shellcheck source=../.env
  source "$REPO_ROOT/.env"
  set +a
fi

# Construct DATABASE_URL from individual vars if not already set
if [ -z "${DATABASE_URL:-}" ]; then
  DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
  export DATABASE_URL
fi

mkdir -p "$PIPELINE_DIR"

# ── Helpers ──────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] $*"; }

halt() {
  local reason="$1" agent="$2" detail="$3"
  cat > "$REPO_ROOT/HALT.md" <<EOF
# HALT

**Reason:** $reason
**Agent:** $agent
**Phase:** $PHASE
**Time:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Detail

$detail
EOF
  telegram_notify "❌ Pipeline halted — Phase $PHASE\n\nReason: $reason\nAgent: $agent\n\nSee HALT.md for detail."
  log "PIPELINE HALTED: $reason"
  exit 1
}

telegram_notify() {
  local message="$1"
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_ALLOWED_CHAT_ID}" \
    -d "text=${message}" \
    -d "parse_mode=Markdown" > /dev/null
}

run_agent() {
  local agent_id="$1" prompt="$2" output_file="$3"
  log "[$agent_id] Starting..."

  opencode run --agent "$agent_id" "$prompt" > "$output_file" 2>&1
  local exit_code=$?

  if [ $exit_code -ne 0 ]; then
    halt "Agent invocation failed (exit $exit_code)" "$agent_id" "$(cat "$output_file")"
  fi

  log "[$agent_id] Complete"
}

wait_for_approval() {
  local approval_file="$PIPELINE_DIR/approval.json"
  local deadline=$(( $(date +%s) + 86400 )) # 24 hours

  log "Waiting for your approval via Telegram..."
  log "Reply 'approve', 'changes: [what to change]', or 'stop'"

  # Launch telegram gate in background to write approval.json
  "$REPO_ROOT/orchestrator/telegram-gate.sh" --phase "$PHASE" &
  GATE_PID=$!

  # Wait for approval.json to appear
  while [ $(date +%s) -lt $deadline ] && kill -0 $GATE_PID 2>/dev/null; do
    if [ -f "$approval_file" ]; then
      wait $GATE_PID 2>/dev/null || true
      local signal
      signal=$(python3 -c "import json; print(json.load(open('$approval_file'))['signal'])")
      log "Approval received: $signal"
      echo "$signal"
      return 0
    fi
    sleep 2
  done

  kill $GATE_PID 2>/dev/null || true
  halt "Approval timeout" "human-gate" "No approval signal received within 24 hours"
}

report_contains() {
  local file="$1" word="$2"
  grep -q "$word" "$file" 2>/dev/null
}

# ── Phase gate ───────────────────────────────────────────────────────────────
if [ "$PHASE" -gt 1 ]; then
  PREV_PHASE=$(( PHASE - 1 ))
  PREV_REPORT="$REPO_ROOT/pipeline/phase-$PREV_PHASE/validation-report.md"

  if [ ! -f "$PREV_REPORT" ]; then
    halt "Phase $PREV_PHASE not complete" "orchestrator" "validation-report.md not found for phase $PREV_PHASE"
  fi

  if ! report_contains "$PREV_REPORT" "PASS"; then
    halt "Phase $PREV_PHASE did not pass validation" "orchestrator" "validation-report.md for phase $PREV_PHASE does not contain PASS"
  fi
fi

# ── Header ───────────────────────────────────────────────────────────────────
log "========================================"
log "{PROJECT_NAME} Pipeline — Phase $PHASE"
log "========================================"

# ── AG-01 Architect ──────────────────────────────────────────────────────────
log ""
log "AG-01 Architect — producing task manifest..."

ARCH_PROMPT="You are running as AG-01 Architect for {PROJECT_NAME}.

Read the PRD at docs/prd.md and the Architecture doc at docs/architecture.md.
Produce the task manifest for Phase $PHASE.

Write two files to pipeline/phase-$PHASE/:
1. task-manifest.json
2. manifest-summary.md

Follow your system prompt exactly."

if [ ! -f "$PIPELINE_DIR/task-manifest.json" ]; then
  run_agent "ag-01-architect" "$ARCH_PROMPT" "$PIPELINE_DIR/ag01-output.md"
else
  log "task-manifest.json already exists — skipping AG-01"
fi

if [ ! -f "$PIPELINE_DIR/task-manifest.json" ]; then
  halt "task-manifest.json not produced" "AG-01" "Architect did not write task-manifest.json"
fi

log "Manifest produced. Tasks:"
python3 -c "
import json
data = json.load(open('$PIPELINE_DIR/task-manifest.json'))
tasks = data if isinstance(data, list) else data.get('tasks', data.get('task_order', []))
if tasks and isinstance(tasks[0], str):
    tasks = data.get('tasks', [])
for t in tasks:
    if isinstance(t, dict):
        flag = ' [SECURITY]' if t.get('security_sensitive') else ''
        print(f\"  {t['id']}: {t['title']}{flag}\")
"

# ── AG-02 Reviewer ───────────────────────────────────────────────────────────
log ""
log "AG-02 Reviewer — preparing human review..."

REVIEW_PROMPT="You are running as AG-02 Reviewer for {PROJECT_NAME}.

Read pipeline/phase-$PHASE/task-manifest.json and pipeline/phase-$PHASE/manifest-summary.md.

Write reviewer-summary.md to pipeline/phase-$PHASE/ using the format defined in your system prompt.

Do not send any Telegram messages. Do not make any API calls. Just write the file and stop."

run_agent "ag-02-reviewer" "$REVIEW_PROMPT" "$PIPELINE_DIR/ag02-output.md"

# Read the reviewer summary and send it via Telegram
SUMMARY_FILE="$PIPELINE_DIR/reviewer-summary.md"
if [ ! -f "$SUMMARY_FILE" ]; then
  halt "reviewer-summary.md not produced" "AG-02" "Reviewer did not write the summary file"
fi

SUMMARY_TEXT=$(head -c 3000 "$SUMMARY_FILE")

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "text=🔍 {PROJECT_NAME} Pipeline — Phase ${PHASE} Review

${SUMMARY_TEXT}

Reply with: approve | changes: [what to change] | stop" \
  -d "chat_id=${TELEGRAM_ALLOWED_CHAT_ID}" > /dev/null

log "Reviewer summary sent to Telegram"

# ── Human gate ───────────────────────────────────────────────────────────────
log ""
log "========================================"
log "HUMAN GATE — waiting for your reply..."
log "========================================"

APPROVAL=$(wait_for_approval)

if [ "$APPROVAL" = "stop" ]; then
  halt "User stopped the pipeline" "human-gate" "User replied 'stop'"
fi

if [[ "$APPROVAL" == changes:* ]]; then
  CHANGES="${APPROVAL#changes: }"
  log "Changes requested: $CHANGES"
  log "Re-running Architect with feedback..."

  ARCH_PROMPT_REVISED="$ARCH_PROMPT

The user has reviewed the manifest and requested these changes: $CHANGES

Revise the manifest accordingly and rewrite task-manifest.json and manifest-summary.md."

  run_agent "ag-01-architect" "$ARCH_PROMPT_REVISED" "$PIPELINE_DIR/ag01-output-revised.md"
  run_agent "ag-02-reviewer" "$REVIEW_PROMPT" "$PIPELINE_DIR/ag02-output-revised.md"

  rm -f "$PIPELINE_DIR/approval.json"
  APPROVAL=$(wait_for_approval)

  if [ "$APPROVAL" != "approve" ]; then
    halt "User did not approve after revision" "human-gate" "Signal received: $APPROVAL"
  fi
fi

log "Approved. Starting implementation..."
python3 -c "
import json
with open('$PIPELINE_DIR/approval.json', 'r') as f:
    data = json.load(f)
data['approved_at'] = '$(date -u +"%Y-%m-%dT%H:%M:%SZ")'
with open('$PIPELINE_DIR/approval.json', 'w') as f:
    json.dump(data, f, indent=2)
"

# ── Task loop ────────────────────────────────────────────────────────────────
TASKS=$(python3 -c "
import json
data = json.load(open('$PIPELINE_DIR/task-manifest.json'))
tasks = data if isinstance(data, list) else data.get('tasks', [])
for t in tasks:
    if isinstance(t, dict):
        print(t['id'])
")

for TASK_ID in $TASKS; do
  TASK_DIR="$PIPELINE_DIR/$TASK_ID"
  mkdir -p "$TASK_DIR"

  # Skip if already fully complete (both security and test reports show PASS)
  SEC_REPORT="$TASK_DIR/security-report.md"
  TEST_REPORT="$TASK_DIR/test-report.md"

  if [ -f "$SEC_REPORT" ] && report_contains "$SEC_REPORT" "PASS" && \
     [ -f "$TEST_REPORT" ] && report_contains "$TEST_REPORT" "PASS"; then
    log "Task $TASK_ID already complete — skipping"
    continue
  fi

  TASK_JSON=$(python3 -c "
import json
data = json.load(open('$PIPELINE_DIR/task-manifest.json'))
tasks = data if isinstance(data, list) else data.get('tasks', [])
task = next(t for t in tasks if isinstance(t, dict) and t['id'] == '$TASK_ID')
print(json.dumps(task, indent=2))
")

  TASK_TITLE=$(python3 -c "
import json
data = json.load(open('$PIPELINE_DIR/task-manifest.json'))
tasks = data if isinstance(data, list) else data.get('tasks', [])
task = next(t for t in tasks if isinstance(t, dict) and t['id'] == '$TASK_ID')
print(task['title'])
")

  log ""
  log "========================================"
  log "Task: $TASK_ID — $TASK_TITLE"
  log "========================================"

  # ── Developer + Security loop ─────────────────────────────────────────────
  SECURITY_PASSED=false
  SECURITY_ATTEMPTS=0

  while [ "$SECURITY_PASSED" = false ] && [ "$SECURITY_ATTEMPTS" -lt 3 ]; do
    SECURITY_ATTEMPTS=$(( SECURITY_ATTEMPTS + 1 ))
    log "Developer attempt $SECURITY_ATTEMPTS/3..."

    DEV_PROMPT="You are AG-03 Developer for {PROJECT_NAME}.

Implement this task:
$TASK_JSON

Write self-assessment.md to pipeline/phase-$PHASE/$TASK_ID/
Follow your system prompt exactly. Apply all security rules.

## Environment
Do not read .env directly. Database connection details will be provided to the tester separately. Use process.env.DATABASE_URL for any database connections in the implementation code."

    run_agent "ag-03-developer" "$DEV_PROMPT" "$TASK_DIR/dev-output.md"

    # Check for BLOCKED
    if [ -f "$TASK_DIR/BLOCKED.md" ]; then
      halt "Developer blocked on $TASK_ID" "AG-03" "$(cat "$TASK_DIR/BLOCKED.md")"
    fi

    log "Running Security Agent..."

    SEC_PROMPT="You are AG-04 Security Agent for {PROJECT_NAME}.

Review all code written for task $TASK_ID.
Task spec:
$TASK_JSON

Apply every rule in agents/security-rules.md to every file in files_in_scope.
Write security-report.md to pipeline/phase-$PHASE/$TASK_ID/
Return PASS or FAIL with specific findings.

## Environment reference
DATABASE_URL=$DATABASE_URL
POSTGRES_HOST=$POSTGRES_HOST
POSTGRES_PORT=$POSTGRES_PORT
POSTGRES_USER=$POSTGRES_USER
POSTGRES_DB=$POSTGRES_DB"

    run_agent "ag-04-security" "$SEC_PROMPT" "$TASK_DIR/sec-output.md"

    if [ -f "$TASK_DIR/security-report.md" ] && report_contains "$TASK_DIR/security-report.md" "PASS"; then
      SECURITY_PASSED=true
      log "Security: PASS"
    else
      log "Security: FAIL (attempt $SECURITY_ATTEMPTS/3)"
      if [ "$SECURITY_ATTEMPTS" -eq 3 ]; then
        halt "Security could not be resolved after 3 attempts" "AG-04" "Task: $TASK_ID — see $TASK_DIR/security-report.md"
      fi
    fi
  done

  # ── Tester loop ───────────────────────────────────────────────────────────
  TEST_PASSED=false
  TEST_ATTEMPTS=0

  while [ "$TEST_PASSED" = false ] && [ "$TEST_ATTEMPTS" -lt 3 ]; do
    TEST_ATTEMPTS=$(( TEST_ATTEMPTS + 1 ))
    log "Tester attempt $TEST_ATTEMPTS/3..."

    TEST_PROMPT="You are AG-05 Tester for {PROJECT_NAME}.

Write and run tests for task $TASK_ID.
Task spec:
$TASK_JSON

Every acceptance criterion must have at least one passing test.
Write test-report.md to pipeline/phase-$PHASE/$TASK_ID/
Return PASS or FAIL with full test output.

## Environment for testing
Use these values for database connections in tests — do not read .env:
DATABASE_URL=$DATABASE_URL
POSTGRES_HOST=$POSTGRES_HOST
POSTGRES_PORT=$POSTGRES_PORT
POSTGRES_USER=$POSTGRES_USER
POSTGRES_DB=$POSTGRES_DB

For tests requiring a database connection, use DATABASE_URL directly.
Mock the Telegram API, Anthropic API, Google Calendar MCP, and Gmail MCP — do not make real calls to these services in tests."

    run_agent "ag-05-tester" "$TEST_PROMPT" "$TASK_DIR/test-output.md"

    if [ -f "$TASK_DIR/test-report.md" ] && report_contains "$TASK_DIR/test-report.md" "PASS"; then
      TEST_PASSED=true
      log "Tests: PASS"
    else
      log "Tests: FAIL (attempt $TEST_ATTEMPTS/3)"
      if [ "$TEST_ATTEMPTS" -eq 3 ]; then
        halt "Tests could not pass after 3 attempts" "AG-05" "Task: $TASK_ID — see $TASK_DIR/test-report.md"
      fi
    fi
  done

  log "Task $TASK_ID: COMPLETE"
done

# ── AG-06 Validator ──────────────────────────────────────────────────────────
log ""
log "========================================"
log "AG-06 Validator — end-to-end phase check"
log "========================================"

VALIDATION_PASSED=false
VALIDATION_ATTEMPTS=0

while [ "$VALIDATION_PASSED" = false ] && [ "$VALIDATION_ATTEMPTS" -lt 2 ]; do
  VALIDATION_ATTEMPTS=$(( VALIDATION_ATTEMPTS + 1 ))
  log "Validation attempt $VALIDATION_ATTEMPTS/2..."

  VAL_PROMPT="You are AG-06 Validator for {PROJECT_NAME}.

Validate the full Phase $PHASE implementation against the PRD exit criteria in docs/prd.md.

1. Check every exit criterion for Phase $PHASE explicitly
2. Run the smoke tests for this phase
3. Read every task's security-report.md and test-report.md in pipeline/phase-$PHASE/
4. Write validation-report.md to pipeline/phase-$PHASE/

On PASS:
- Run: git tag phase-$PHASE-complete
- Write the validation-report.md with PASS, changelog, and full sign-off

On FAIL:
- List exactly which exit criteria failed and why
- Do not create a git tag

Do not send any Telegram messages. The shell script handles notifications."

  run_agent "ag-06-validator" "$VAL_PROMPT" "$PIPELINE_DIR/val-output.md"

  if [ -f "$PIPELINE_DIR/validation-report.md" ] && report_contains "$PIPELINE_DIR/validation-report.md" "PASS"; then
    VALIDATION_PASSED=true

    # Send Telegram notification on phase PASS
    VAL_TEXT=$(head -c 3000 "$PIPELINE_DIR/validation-report.md")
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "text=✅ {PROJECT_NAME} — Phase ${PHASE} Complete

${VAL_TEXT}" \
      -d "chat_id=${TELEGRAM_ALLOWED_CHAT_ID}" > /dev/null

    log ""
    log "========================================"
    log "Phase $PHASE: COMPLETE"
    log "Git tag: phase-$PHASE-complete created"
    log "Telegram notification sent"
    log "========================================"
  else
    log "Validation: FAIL (attempt $VALIDATION_ATTEMPTS/2)"
    if [ "$VALIDATION_ATTEMPTS" -eq 2 ]; then
      halt "Phase validation failed after 2 attempts" "AG-06" "See pipeline/phase-$PHASE/validation-report.md"
    fi
  fi
done

# Clean up HALT.md if present from a previous run
rm -f "$REPO_ROOT/HALT.md"

exit 0
