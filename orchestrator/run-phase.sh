#!/bin/bash

set -euo pipefail

# ── {PROJECT_NAME} Pipeline Runner ───────────────────────────────────────────
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

# ── Paths ─────────────────────────────────────────────────────────────────────
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

# ── Validate required env vars ────────────────────────────────────────────────
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY is not set — check your .env}"
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is not set — check your .env}"
: "${TELEGRAM_ALLOWED_CHAT_ID:?TELEGRAM_ALLOWED_CHAT_ID is not set — check your .env}"

# Construct DATABASE_URL from individual vars if not already set
if [ -z "${DATABASE_URL:-}" ]; then
  DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
  export DATABASE_URL
fi

mkdir -p "$PIPELINE_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────────
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

# Checks that a report file contains a PASS title line as written by the agents.
# Matches "Title: ... — PASS" or "# ... — PASS" — avoids false positives from
# body text that happens to contain the word PASS.
report_passes() {
  local file="$1"
  grep -qE "(Title:|##? .+).*— PASS" "$file" 2>/dev/null
}

# Runs tsc --noEmit, ESLint on files that exist from files_in_scope, and pnpm test.
# Prints combined failure output to stdout (empty on full pass).
# Returns 0 if all checks pass, 1 if any fail.
verify_implementation() {
  local files_in_scope_json="$1"
  local failures="" out rc

  out=$(cd "$REPO_ROOT" && pnpm exec tsc --noEmit 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    failures+="=== tsc --noEmit ===
${out}

"
  fi

  mapfile -t existing_files < <(python3 -c "
import json, os, sys
files = json.loads(sys.argv[1])
for f in files:
    full = os.path.join('$REPO_ROOT', f)
    if os.path.isfile(full):
        print(full)
" "$files_in_scope_json" 2>/dev/null)

  if [ ${#existing_files[@]} -gt 0 ]; then
    out=$(cd "$REPO_ROOT" && pnpm exec eslint "${existing_files[@]}" 2>&1); rc=$?
    if [ $rc -ne 0 ]; then
      failures+="=== eslint ===
${out}

"
    fi
  fi

  out=$(cd "$REPO_ROOT" && pnpm test --run 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    failures+="=== pnpm test --run ===
${out}

"
  fi

  printf "%s" "$failures"
  [ -z "$failures" ]
}

# ── Phase gate ────────────────────────────────────────────────────────────────
if [ "$PHASE" -gt 1 ]; then
  PREV_PHASE=$(( PHASE - 1 ))
  PREV_REPORT="$REPO_ROOT/pipeline/phase-$PREV_PHASE/validation-report.md"

  if [ ! -f "$PREV_REPORT" ]; then
    halt "Phase $PREV_PHASE not complete" "orchestrator" "validation-report.md not found for phase $PREV_PHASE"
  fi

  if ! report_passes "$PREV_REPORT"; then
    halt "Phase $PREV_PHASE did not pass validation" "orchestrator" "validation-report.md for phase $PREV_PHASE does not contain a PASS title"
  fi
fi

# ── Header ────────────────────────────────────────────────────────────────────
log "========================================"
log "{PROJECT_NAME} Pipeline — Phase $PHASE"
log "========================================"

# ── AG-01 Architect ───────────────────────────────────────────────────────────
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

# ── AG-02 Reviewer ────────────────────────────────────────────────────────────
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

# ── Human gate ────────────────────────────────────────────────────────────────
log ""
log "========================================"
log "HUMAN GATE — waiting for your reply..."
log "========================================"

APPROVAL=$(wait_for_approval)

if [ "$APPROVAL" = "stop" ]; then
  halt "User stopped the pipeline" "human-gate" "User replied 'stop'"
fi

MAX_REVISIONS=3
REVISION=0

while [[ "$APPROVAL" == changes:* ]]; do
  REVISION=$(( REVISION + 1 ))
  if [ "$REVISION" -gt "$MAX_REVISIONS" ]; then
    halt "Manifest revised $MAX_REVISIONS times without approval" "human-gate" "Too many revision rounds — stopping pipeline"
  fi

  CHANGES="${APPROVAL#changes:}"
  CHANGES="${CHANGES# }"
  log "Changes requested (round $REVISION/$MAX_REVISIONS): $CHANGES"
  log "Re-running Architect with feedback..."

  ARCH_PROMPT_REVISED="$ARCH_PROMPT

The user has reviewed the manifest and requested these changes: $CHANGES

Revise the manifest accordingly and rewrite task-manifest.json and manifest-summary.md."

  run_agent "ag-01-architect" "$ARCH_PROMPT_REVISED" "$PIPELINE_DIR/ag01-output-revised-$REVISION.md"
  run_agent "ag-02-reviewer" "$REVIEW_PROMPT" "$PIPELINE_DIR/ag02-output-revised-$REVISION.md"

  rm -f "$PIPELINE_DIR/approval.json"
  APPROVAL=$(wait_for_approval)

  if [ "$APPROVAL" = "stop" ]; then
    halt "User stopped the pipeline" "human-gate" "User replied 'stop' during revision"
  fi
done

if [ "$APPROVAL" != "approve" ]; then
  halt "Unexpected approval signal" "human-gate" "Signal received: $APPROVAL"
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

# ── Task loop ─────────────────────────────────────────────────────────────────
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

  SEC_REPORT="$TASK_DIR/security-report.md"

  # Task is fully complete once security has passed (green gate is a prerequisite)
  if [ -f "$SEC_REPORT" ] && report_passes "$SEC_REPORT"; then
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

  FILES_IN_SCOPE_JSON=$(python3 -c "
import json
data = json.load(open('$PIPELINE_DIR/task-manifest.json'))
tasks = data if isinstance(data, list) else data.get('tasks', [])
task = next(t for t in tasks if isinstance(t, dict) and t['id'] == '$TASK_ID')
print(json.dumps(task.get('files_in_scope', [])))
")

  log ""
  log "========================================"
  log "Task: $TASK_ID — $TASK_TITLE"
  log "========================================"

  # ── RED phase: Tester writes failing tests ────────────────────────────────
  TESTS_WRITTEN_FILE="$TASK_DIR/tests-written.txt"

  if [ ! -f "$TESTS_WRITTEN_FILE" ]; then
    # Guard against a corrupted prior run: sentinel exists but no test files written
    : # sentinel check happens after agent run below
  fi

  if [ ! -f "$TESTS_WRITTEN_FILE" ]; then
    log "RED phase — Tester writing failing tests..."

    RED_PROMPT="You are AG-03 Tester for {PROJECT_NAME}.

This is the RED phase of TDD. The Developer has not yet written implementation code.

Write the test suite for task $TASK_ID that defines the expected behaviour.
Task spec:
$TASK_JSON

Write test files to the __tests__/ directories as normal.
Tests will fail right now because there is no implementation — that is correct and expected.

Do NOT write implementation code.
Do NOT write test-report.md — the orchestrator writes that.
After writing all test files, write the single line 'tests-written' to:
  pipeline/phase-$PHASE/$TASK_ID/tests-written.txt

Follow your system prompt exactly."

    run_agent "ag-03-tester" "$RED_PROMPT" "$TASK_DIR/tester-red-output.md"

    if [ ! -f "$TESTS_WRITTEN_FILE" ]; then
      halt "Tester did not confirm tests written" "AG-03" \
        "Task: $TASK_ID — tests-written.txt not found after RED phase"
    fi

    # Informational: verify tests fail before implementation (expect non-zero exit)
    log "Confirming tests fail before implementation (RED check)..."
    if (cd "$REPO_ROOT" && pnpm test --run > "$TASK_DIR/test-red-output.txt" 2>&1); then
      log "WARNING: Tests pass before implementation — verify tests have meaningful assertions"
    else
      log "RED confirmed — tests fail as expected"
    fi
  else
    log "RED phase already complete — skipping"
  fi

  # ── GREEN phase: Developer implements until hard gate passes ───────────────
  GREEN_VERIFIED_FILE="$TASK_DIR/green-verified.txt"

  if [ ! -f "$GREEN_VERIFIED_FILE" ]; then
    DEV_ATTEMPTS=0
    GREEN_PASSED=false
    GATE_FAILURES=""

    while [ "$GREEN_PASSED" = false ] && [ "$DEV_ATTEMPTS" -lt 3 ]; do
      DEV_ATTEMPTS=$(( DEV_ATTEMPTS + 1 ))
      log "GREEN phase — Developer attempt $DEV_ATTEMPTS/3..."

      DEV_PROMPT="You are AG-04 Developer for {PROJECT_NAME}.

Implement this task to make the failing tests pass:
$TASK_JSON

The Tester has already written failing tests in the __tests__/ directories.
Your job is to write implementation code that makes every test pass.
Do not modify the test files.

Write self-assessment.md to pipeline/phase-$PHASE/$TASK_ID/
Follow your system prompt exactly. Apply all security rules.
Use process.env.DATABASE_URL for any database connections — do not read .env directly."

      if [ -n "$GATE_FAILURES" ]; then
        DEV_PROMPT="$DEV_PROMPT

## Previous attempt failed the hard gate — fix every item below before marking done:

$GATE_FAILURES"
      fi

      run_agent "ag-04-developer" "$DEV_PROMPT" "$TASK_DIR/dev-output-$DEV_ATTEMPTS.md"

      if [ -f "$TASK_DIR/BLOCKED.md" ]; then
        halt "Developer blocked on $TASK_ID" "AG-04" "$(cat "$TASK_DIR/BLOCKED.md")"
      fi

      log "Running hard gate (tsc + eslint + pnpm test)..."
      GATE_FAILURES=$(verify_implementation "$FILES_IN_SCOPE_JSON") || true

      if [ -z "$GATE_FAILURES" ]; then
        GREEN_PASSED=true
        echo "green-verified" > "$GREEN_VERIFIED_FILE"
        cat > "$TASK_DIR/test-report.md" <<REPORT
Title: Test Report — $TASK_ID — PASS

Verified by orchestrator hard gate after Developer attempt $DEV_ATTEMPTS.

- tsc --noEmit: PASS
- eslint (files_in_scope): PASS
- pnpm test --run: PASS

$(cat "$TASK_DIR/test-red-output.txt" 2>/dev/null | head -20 || true)
REPORT
        log "GREEN phase: PASS"
      else
        log "Hard gate: FAIL (attempt $DEV_ATTEMPTS/3)"
        printf "%s" "$GATE_FAILURES" > "$TASK_DIR/gate-failures-$DEV_ATTEMPTS.txt"
        if [ "$DEV_ATTEMPTS" -eq 3 ]; then
          halt "Developer could not pass hard gate after 3 attempts" "AG-04" \
            "Task: $TASK_ID — see $TASK_DIR/gate-failures-3.txt"
        fi
      fi
    done
  else
    log "GREEN phase already complete — skipping"

    # Ensure test-report.md exists even on resume (may have been lost if script was killed)
    if [ ! -f "$TASK_DIR/test-report.md" ]; then
      cat > "$TASK_DIR/test-report.md" <<REPORT
Title: Test Report — $TASK_ID — PASS

Verified by orchestrator hard gate (restored on resume).

- tsc --noEmit: PASS
- eslint (files_in_scope): PASS
- pnpm test --run: PASS
REPORT
    fi
  fi

  # ── Security phase ────────────────────────────────────────────────────────
  SECURITY_PASSED=false
  SECURITY_ATTEMPTS=0

  while [ "$SECURITY_PASSED" = false ] && [ "$SECURITY_ATTEMPTS" -lt 3 ]; do
    SECURITY_ATTEMPTS=$(( SECURITY_ATTEMPTS + 1 ))
    log "Security attempt $SECURITY_ATTEMPTS/3..."

    SEC_PROMPT="You are AG-05 Security Agent for {PROJECT_NAME}.

Review all code written for task $TASK_ID.
Task spec:
$TASK_JSON

Apply every rule in .opencode/agents/security-rules.md to every file in files_in_scope.
Write security-report.md to pipeline/phase-$PHASE/$TASK_ID/
Return PASS or FAIL with specific findings."

    run_agent "ag-05-security" "$SEC_PROMPT" "$TASK_DIR/sec-output-$SECURITY_ATTEMPTS.md"

    if [ -f "$SEC_REPORT" ] && report_passes "$SEC_REPORT"; then
      SECURITY_PASSED=true
      log "Security: PASS"
    else
      log "Security: FAIL (attempt $SECURITY_ATTEMPTS/3)"
      if [ "$SECURITY_ATTEMPTS" -eq 3 ]; then
        halt "Security could not be resolved after 3 attempts" "AG-05" \
          "Task: $TASK_ID — see $SEC_REPORT"
      fi

      # Developer fixes security findings, then re-run hard gate to ensure fix didn't break tests
      log "Security fix needed — re-running Developer..."

      SEC_FIX_PROMPT="You are AG-04 Developer for {PROJECT_NAME}.

The Security Agent has rejected task $TASK_ID. Fix every finding below.

$(cat "$SEC_REPORT")

Task spec for context:
$TASK_JSON

Do not introduce new issues. Do not modify test files.
Update self-assessment.md after fixing.
Use process.env.DATABASE_URL for any database connections."

      run_agent "ag-04-developer" "$SEC_FIX_PROMPT" \
        "$TASK_DIR/dev-secfix-$SECURITY_ATTEMPTS.md"

      log "Re-running hard gate after security fix..."
      POST_SEC_FAILURES=$(verify_implementation "$FILES_IN_SCOPE_JSON") || true
      if [ -n "$POST_SEC_FAILURES" ]; then
        # Delete green sentinel so a resume restarts from GREEN, not security
        rm -f "$GREEN_VERIFIED_FILE"
        halt "Security fix broke tsc or tests on task $TASK_ID" "AG-04" \
          "Task: $TASK_ID
$POST_SEC_FAILURES"
      fi
      log "Post-security hard gate: PASS"
    fi
  done

  log "Task $TASK_ID: COMPLETE"
done

# ── AG-06 Validator ───────────────────────────────────────────────────────────
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

  if [ -f "$PIPELINE_DIR/validation-report.md" ] && report_passes "$PIPELINE_DIR/validation-report.md"; then
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
