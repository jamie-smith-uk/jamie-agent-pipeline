#!/bin/bash

# run-task.sh — Run a single task through the agent pipeline.
# For bug fixes, backlog items, hotfixes, and small features that don't
# warrant a full PRD phase. Uses the same quality gates as run-phase.sh.
#
# Usage:
#   ./orchestrator/run-task.sh backlog/fix-crash.md   — task file
#   ./orchestrator/run-task.sh --quick "Fix the crash on long messages"
#   ./orchestrator/run-task.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Args ──────────────────────────────────────────────────────────────────────
TASK_FILE=""
QUICK_DESC=""
JSON_INLINE=""
OPT_REVIEW=false
OPT_NO_SECURITY=false
OPT_URGENT=false
OPT_DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --review)      OPT_REVIEW=true;      shift ;;
    --no-security) OPT_NO_SECURITY=true; shift ;;
    --urgent)      OPT_URGENT=true;      shift ;;
    --dry-run)     OPT_DRY_RUN=true;     shift ;;
    --quick)       QUICK_DESC="$2";      shift 2 ;;
    --json)        JSON_INLINE="$2";     shift 2 ;;
    --help|-h)
      cat <<'HELP'
Usage: ./orchestrator/run-task.sh [OPTIONS] [task-file.md]

Inputs (one required):
  task-file.md              Task file with YAML front matter (see backlog/)
  --quick "description"     Natural language — Architect generates the spec
  --json '{...}'            Inline task JSON

Options:
  --review       Show task spec in terminal and ask for approval before running
  --no-security  Skip AG-07 Security (for non-code changes, docs, config)
  --urgent       Skip Refactor and Mutation testing (hotfix mode)
  --dry-run      Print the manifest and exit without running agents

Task file format (backlog/my-task.md):
  ---
  title: Fix message handler crash on long input
  security_sensitive: false
  files:
    - src/handlers/message.ts
  criteria:
    - Messages over 4000 chars are truncated cleanly
    - A warning is logged when truncation occurs
  ---
  ## Context (optional)
  ...
HELP
      exit 0 ;;
    -*) echo "Unknown option: $1"; exit 1 ;;
    *)  TASK_FILE="$1"; shift ;;
  esac
done

# ── Environment ───────────────────────────────────────────────────────────────
if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY is not set — check your .env}"

if [ -z "${DATABASE_URL:-}" ] && [ -n "${POSTGRES_USER:-}" ]; then
  DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
  export DATABASE_URL
fi

# Source shared functions from run-phase.sh without running its main code
PIPELINE_LIB_ONLY=1 source "$SCRIPT_DIR/run-phase.sh"

# Globals the shared functions expect
PHASE="task"
PHASE_STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CONTEXT_MAX_CHARS=4000

# ── Task input helpers ────────────────────────────────────────────────────────
parse_task_file() {
  python3 - "$1" <<'PYEOF'
import json, re, sys

content = open(sys.argv[1]).read()
m = re.match(r'^---\n(.*?)\n---\n?(.*)', content, re.DOTALL)
if not m:
    print(json.dumps({"error": "No YAML front matter found in task file"}), file=sys.stderr)
    sys.exit(1)

fm_text, body = m.group(1), m.group(2).strip()

result = {}
current_list = None
for line in fm_text.split('\n'):
    if re.match(r'^  - ', line):
        if current_list is not None:
            current_list.append(line[4:].strip())
    elif ':' in line:
        k, _, v = line.partition(':')
        k, v = k.strip(), v.strip()
        if v == '':
            result[k] = []; current_list = result[k]
        elif v.lower() == 'true':
            result[k] = True; current_list = None
        elif v.lower() == 'false':
            result[k] = False; current_list = None
        else:
            result[k] = v; current_list = None

slug = re.sub(r'[^a-z0-9]+', '-', result.get('title', 'task').lower()).strip('-')[:40]
task = {
    'id': slug,
    'title': result.get('title', 'Unnamed task'),
    'description': body[:500] if body else result.get('title', ''),
    'files_in_scope': result.get('files', result.get('files_in_scope', [])),
    'dependencies': [],
    'acceptance_criteria': result.get('criteria', result.get('acceptance_criteria', [])),
    'security_sensitive': result.get('security_sensitive', False),
    'estimated_complexity': result.get('complexity', 'medium'),
}
print(json.dumps(task, indent=2))
PYEOF
}

generate_task_from_description() {
  local description="$1"
  log "Generating task manifest from description..."
  # Pass API key via environment, not as process arg (S-03 fix — args visible in ps aux)
  python3 - "$description" "$REPO_ROOT" <<'PYEOF'
import json, os, re, subprocess, sys, urllib.request

desc, repo_root = sys.argv[1], sys.argv[2]
api_key = os.environ.get('ANTHROPIC_API_KEY', '')

try:
    listing = subprocess.run(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard'],
        capture_output=True, text=True, cwd=repo_root, timeout=5
    ).stdout[:2000]
except Exception:
    listing = '(unavailable)'

prompt = (
    f"You are a software architect. Given this task description and repo file listing, "
    f"produce a task manifest JSON object.\n\n"
    f"Task: {desc}\n\nRepo files:\n{listing}\n\n"
    f"Reply with ONLY valid JSON:\n"
    f'{{"id":"kebab-slug","title":"Short title","description":"What to build",'
    f'"files_in_scope":["path/to/file.ts"],"dependencies":[],'
    f'"acceptance_criteria":["Specific testable criterion"],'
    f'"security_sensitive":false,"estimated_complexity":"low|medium|high"}}'
)

try:
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps({
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 800,
            "messages": [{"role": "user", "content": prompt}]
        }).encode(),
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        }
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        text = json.load(resp)["content"][0]["text"].strip()
        m = re.search(r'\{.*\}', text, re.DOTALL)
        if m:
            print(m.group(0))
        else:
            raise ValueError("No JSON in Architect response")
except Exception as e:
    print(f"Error generating manifest: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ── Resolve task manifest ─────────────────────────────────────────────────────
if [ -n "$QUICK_DESC" ]; then
  TASK_JSON=$(generate_task_from_description "$QUICK_DESC")
elif [ -n "$JSON_INLINE" ]; then
  TASK_JSON="$JSON_INLINE"
elif [ -n "$TASK_FILE" ]; then
  [ -f "$TASK_FILE" ] || { echo "Task file not found: $TASK_FILE"; exit 1; }
  TASK_JSON=$(parse_task_file "$TASK_FILE")
else
  echo "Error: provide a task file, --quick description, or --json payload."
  echo "Run with --help for usage."
  exit 1
fi

python3 -c "import json, sys; json.load(sys.stdin)" <<< "$TASK_JSON" \
  || { echo "Error: task manifest is not valid JSON"; exit 1; }

TASK_ID=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$TASK_JSON")
TASK_TITLE=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['title'])" "$TASK_JSON")
FILES_IN_SCOPE_JSON=$(python3 -c "import json,sys; print(json.dumps(json.loads(sys.argv[1]).get('files_in_scope',[])))" "$TASK_JSON")
SECURITY_SENSITIVE=$(python3 -c "import json,sys; print('true' if json.loads(sys.argv[1]).get('security_sensitive') else 'false')" "$TASK_JSON")
HAS_MIGRATION=$(python3 -c "
import json,sys
files=json.loads(sys.argv[1])
print('true' if any('migration' in f.lower() or f.startswith('migrations/') for f in files) else 'false')
" "$FILES_IN_SCOPE_JSON")
AC_COUNT=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1]).get('acceptance_criteria',[])))" "$TASK_JSON")

AFFECTED_PKGS=$(python3 -c "
import json, sys, re
files = json.loads(sys.argv[1])
pkgs = set()
for f in files:
    m = re.match(r'packages/([^/]+)/', f)
    if m: pkgs.add('@lifeos/' + m.group(1))
print(' '.join('--filter ' + p for p in sorted(pkgs)) if pkgs else '')
" "$FILES_IN_SCOPE_JSON" 2>/dev/null)

FILES_IN_SCOPE_JSON_EXPANDED=$(python3 -c "
import json, sys
files = json.loads(sys.argv[1])
print(' '.join(files) if files else 'packages/')
" "$FILES_IN_SCOPE_JSON" 2>/dev/null)

# ── Setup task directory ──────────────────────────────────────────────────────
SLUG=$(echo "$TASK_ID" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g')
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
TASK_DIR="$REPO_ROOT/pipeline/tasks/$SLUG-$TIMESTAMP"
PIPELINE_DIR="$TASK_DIR"  # shared functions reference $PIPELINE_DIR

mkdir -p "$TASK_DIR"
echo "$TASK_JSON" > "$TASK_DIR/task.json"

TASK_SPEC="<task-spec>
$TASK_JSON
</task-spec>"

# ── Dry run ───────────────────────────────────────────────────────────────────
if [ "$OPT_DRY_RUN" = true ]; then
  echo ""
  echo "Task manifest:"
  python3 -m json.tool <<< "$TASK_JSON"
  echo ""
  printf "Pipeline: RED → GREEN"
  [ "$HAS_MIGRATION" = "true" ]                            && printf " → MIGRATION"
  [ "$OPT_URGENT" != "true" ]                              && printf " → REFACTOR"
  [ "$SECURITY_SENSITIVE" = "true" ] && [ "$OPT_URGENT" != "true" ] && printf " → MUTATION"
  [ "$OPT_NO_SECURITY" != "true" ]                         && printf " → SECURITY"
  printf " → COMMIT\n"
  exit 0
fi

log "========================================"
log "{PROJECT_NAME} — Task: $TASK_TITLE"
log "========================================"
log "Mode:$([ "$OPT_URGENT" = "true" ] && echo " URGENT") $([ "$OPT_NO_SECURITY" = "true" ] && echo " NO-SECURITY")"
log "Dir:  $TASK_DIR"

# ── Optional review gate (terminal prompt) ───────────────────────────────────
if [ "$OPT_REVIEW" = true ]; then
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo "  TASK REVIEW"
  echo "════════════════════════════════════════════════════════"
  echo "  Title:    $TASK_TITLE"
  echo "  Files:    $(python3 -c "import json,sys; print(', '.join(json.loads(sys.argv[1])))" "$FILES_IN_SCOPE_JSON")"
  echo "  Security: $SECURITY_SENSITIVE"
  echo ""
  echo "  Criteria:"
  python3 -c "import json,sys; [print(f'    • {c}') for c in json.loads(sys.argv[1]).get('acceptance_criteria',[])]" "$TASK_JSON"
  echo ""
  printf "  approve | stop > "
  read -r REVIEW_RESPONSE
  case "$REVIEW_RESPONSE" in
    approve|yes|y) log "Approved — starting implementation..." ;;
    *) log "Task stopped by user"; exit 0 ;;
  esac
fi

# ── RED phase ─────────────────────────────────────────────────────────────────
TESTS_WRITTEN_FILE="$TASK_DIR/tests-written.txt"
if [ ! -f "$TESTS_WRITTEN_FILE" ]; then
  RED_START=$(date +%s)
  log "RED phase — Tester writing failing tests..."
  CONTEXT_BLOCK=$(build_context_block)

  RED_PROMPT="You are AG-03 Tester for {PROJECT_NAME}.
RED phase of TDD — no implementation exists yet.
Write the test suite for this task:
$TASK_SPEC
${CONTEXT_BLOCK:+
$CONTEXT_BLOCK}
Time budget: complete the RED phase in under 5 minutes. Read only the files
directly listed in files_in_scope and their immediate imports. Do not explore
the entire codebase — the task spec and build context contain everything needed.

Write test files to __tests__/ directories.
After writing all tests, write 'tests-written' to: $TASK_DIR/tests-written.txt
Do NOT write implementation code. Do NOT write test-report.md."

  run_agent "ag-03-tester" "$RED_PROMPT" "$TASK_DIR/tester-red-output.md"
  [ ! -f "$TESTS_WRITTEN_FILE" ] && halt "Tester did not write tests" "AG-03" "tests-written.txt not found"

  log "Confirming tests fail before implementation..."
  if (cd "$REPO_ROOT" && pnpm test > "$TASK_DIR/test-red-output.txt" 2>&1); then
    log "WARNING: Tests pass before implementation — verify assertions are meaningful"
  else
    log "RED confirmed — tests fail as expected"
  fi
  check_tester_trajectory "$TASK_DIR" "$TESTS_WRITTEN_FILE" "$AC_COUNT"
  record_task_metrics "$TASK_ID" "$TASK_TITLE" "red" $(( $(date +%s) - RED_START )) 1 "pass"
else
  log "RED already complete — skipping"
fi

# ── GREEN phase ───────────────────────────────────────────────────────────────
GREEN_VERIFIED_FILE="$TASK_DIR/green-verified.txt"
if [ ! -f "$GREEN_VERIFIED_FILE" ]; then
  GREEN_START=$(date +%s)
  DEV_ATTEMPTS=0
  GREEN_PASSED=false
  GATE_FAILURES=""

  while [ "$GREEN_PASSED" = false ] && [ "$DEV_ATTEMPTS" -lt 5 ]; do
    DEV_ATTEMPTS=$(( DEV_ATTEMPTS + 1 ))
    log "GREEN phase — Developer attempt $DEV_ATTEMPTS/5..."

    CONTEXT_BLOCK=$(build_context_block)
    DEV_PROMPT="You are AG-04 Developer for {PROJECT_NAME}.
Implement this task to make the failing tests pass:
$TASK_SPEC
${CONTEXT_BLOCK:+
$CONTEXT_BLOCK}

## Step 1 — Read the in-scope source files FIRST
Read the current content of every file listed in files_in_scope. Understand what is
already implemented before writing anything. Do not duplicate or conflict with existing code.

## Step 2 — Read the tests
Read every \`.test.ts\` file in the __tests__/ directories of the in-scope packages.
The tests define the exact function signatures, exported names, and interfaces you
must implement. If in doubt, the tests are the source of truth.

## Biome lint rules — violations will fail the gate
- **noExplicitAny** (error): Never use \`any\` type. Define a typed interface for the
  data shape, or use \`unknown\` with a type guard.
- **noExcessiveCognitiveComplexity** (error, max 10): Break complex logic into small
  focused helper functions. If a function genuinely must exceed 10 (e.g. a parser),
  add \`// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: <reason>\`
  on the line immediately above the function declaration.
- **noConsole** (warning, won't block gate): Avoid \`console.log\` — use the logger
  from \`packages/shared/src/logger.ts\`.
- **Formatter**: Run \`biome check --write\` (step 3 below) to auto-fix spacing/quotes/commas.

## Validation commands (run in order before marking done)

\`\`\`bash
pnpm exec tsc --noEmit
pnpm exec biome check --write ${FILES_IN_SCOPE_JSON_EXPANDED:-packages/}
pnpm exec biome check ${FILES_IN_SCOPE_JSON_EXPANDED:-packages/}
pnpm${AFFECTED_PKGS:+ $AFFECTED_PKGS} test
\`\`\`

Step 2 (\`biome check --write\`) auto-fixes formatting. Step 3 confirms the result is clean.
You are not done until all four pass with zero errors and all tests passing.

Write self-assessment.md to $TASK_DIR/
Apply all security rules. Use process.env.DATABASE_URL for DB connections."

    if [ -n "$GATE_FAILURES" ]; then
      PREV_DIFF=$(git -C "$REPO_ROOT" diff HEAD -- \
        $(python3 -c "
import json, sys
files = json.loads(sys.argv[1])
print(' '.join(files))
" "$FILES_IN_SCOPE_JSON" 2>/dev/null) 2>/dev/null | head -c 8000 || true)

      DEV_PROMPT="$DEV_PROMPT

## Previous attempt failed the hard gate — fix every item below before marking done:

<gate-failures>
$GATE_FAILURES
</gate-failures>
${PREV_DIFF:+
<previous-attempt-diff>
The following diff shows exactly what your previous attempt wrote to the in-scope files.
Use this to understand what you already changed and avoid repeating the same mistakes:

$PREV_DIFF
</previous-attempt-diff>}"
    fi

    run_agent "ag-04-developer" "$DEV_PROMPT" "$TASK_DIR/dev-output-$DEV_ATTEMPTS.md"
    [ -f "$TASK_DIR/BLOCKED.md" ] && halt "Developer blocked" "AG-04" "$(cat "$TASK_DIR/BLOCKED.md")"

    # Silently remove common temp/debug patterns before scope check.
    find "$REPO_ROOT" -maxdepth 2 \( \
      -name "debug-*.js" -o -name "debug-*.ts" -o \
      -name "test-*.js" -o -name "test-*.ts" -o \
      -name "*.debug.js" -o -name "*.debug.ts" -o \
      -name "*.tmp" -o -name "*.scratch.*" \
    \) -not -path "*/node_modules/*" -not -path "*/__tests__/*" \
       -not -path "*/pipeline/*" \
       -delete 2>/dev/null || true

    log "Checking files_in_scope compliance..."
    SCOPE_VIOLATIONS=$(check_scope_compliance "$FILES_IN_SCOPE_JSON") || true
    SCOPE_GATE=""
    if [ -n "$SCOPE_VIOLATIONS" ]; then
      log "Scope violation — reverting..."
      revert_scope_violations <<< "$SCOPE_VIOLATIONS"
      SCOPE_GATE="=== files_in_scope violation (reverted) ===
$SCOPE_VIOLATIONS
Only write to files listed in files_in_scope."
    fi

    # Auto-fix biome formatting on in-scope files before the gate so trivial
    # whitespace/comma/quote issues don't consume a developer attempt.
    if grep -q '"@biomejs/biome"' "$REPO_ROOT/package.json" 2>/dev/null; then
      mapfile -t _fmt_files < <(python3 -c "
import json, os, sys
files = json.loads(sys.argv[1])
for f in files:
    full = os.path.join('$REPO_ROOT', f)
    if os.path.isfile(full):
        print(full)
" "$FILES_IN_SCOPE_JSON" 2>/dev/null)
      if [ ${#_fmt_files[@]} -gt 0 ]; then
        log "Auto-fixing biome formatting on in-scope files..."
        (cd "$REPO_ROOT" && pnpm exec biome format --write "${_fmt_files[@]}" 2>/dev/null) || true
      fi
    fi

    log "Running hard gate (tsc + biome check + pnpm test)..."
    IMPL_FAILURES=$(verify_implementation "$FILES_IN_SCOPE_JSON") || true
    # Only surface scope violations if implementation also failed (L-04 fix).
    # Scope violations alone are already reverted — penalising a passing attempt
    # for already-corrected violations causes an infinite retry loop.
    if [ -n "$IMPL_FAILURES" ]; then
      GATE_FAILURES="${SCOPE_GATE:+$SCOPE_GATE
}${IMPL_FAILURES}"
    else
      GATE_FAILURES=""
    fi

    # False-GREEN guard: if all changes were reverted as scope violations but no
    # in-scope file was actually written, the developer produced no real implementation.
    if [ -z "$GATE_FAILURES" ] && [ -n "$SCOPE_VIOLATIONS" ]; then
      IN_SCOPE_CHANGED=$(python3 -c "
import json, subprocess, sys
files = json.loads(sys.argv[1])
repo  = sys.argv[2]
result = subprocess.run(
    ['git', '-C', repo, 'diff', '--name-only', 'HEAD'],
    capture_output=True, text=True
)
changed = set(result.stdout.splitlines())
print('yes' if any(f in changed for f in files) else 'no')
" "$FILES_IN_SCOPE_JSON" "$REPO_ROOT" 2>/dev/null || echo "no")
      if [ "$IN_SCOPE_CHANGED" = "no" ]; then
        GATE_FAILURES="${SCOPE_GATE}
=== No in-scope files were modified ===
All of your changes were in files outside files_in_scope and have been reverted.
You MUST write implementation code to the files listed in files_in_scope."
      fi
    fi

    if [ -z "$GATE_FAILURES" ]; then
      GREEN_PASSED=true
      echo "green-verified" > "$GREEN_VERIFIED_FILE"
      cat > "$TASK_DIR/test-report.md" <<REPORT
Title: Test Report — $TASK_ID — PASS

Verified by orchestrator hard gate after Developer attempt $DEV_ATTEMPTS.

- tsc --noEmit: PASS
- eslint (files_in_scope): PASS
- pnpm test: PASS
REPORT
      record_task_metrics "$TASK_ID" "$TASK_TITLE" "green" $(( $(date +%s) - GREEN_START )) "$DEV_ATTEMPTS" "pass"
      log "Code health (pre-refactor baseline):"
      run_code_health_checks "$TASK_ID" "$TASK_DIR" "$FILES_IN_SCOPE_JSON" "pre-refactor"
      log "GREEN phase: PASS"
    else
      log "Hard gate: FAIL (attempt $DEV_ATTEMPTS/5)"
      printf "%s" "$GATE_FAILURES" > "$TASK_DIR/gate-failures-$DEV_ATTEMPTS.txt"
      [ "$DEV_ATTEMPTS" -eq 5 ] && halt "Developer could not pass hard gate" "AG-04" \
        "See $TASK_DIR/gate-failures-5.txt"
    fi
  done
else
  log "GREEN already complete — skipping"
  [ ! -f "$TASK_DIR/test-report.md" ] && printf "Title: Test Report — %s — PASS\n\nRestored on resume.\n" \
    "$TASK_ID" > "$TASK_DIR/test-report.md"
fi

# ── MIGRATION (conditional) ───────────────────────────────────────────────────
MIGRATION_VERIFIED_FILE="$TASK_DIR/migration-verified.txt"
if [ "$HAS_MIGRATION" = "true" ] && [ ! -f "$MIGRATION_VERIFIED_FILE" ]; then
  MIGRATION_START=$(date +%s)
  log "MIGRATION phase..."
  run_agent "ag-05-migration" "You are AG-05 Migration for {PROJECT_NAME}.
Validate migration files for: $TASK_SPEC
Run the migration and rollback. Write migration-report.md to $TASK_DIR/" \
    "$TASK_DIR/migration-output.md"
  [ ! -f "$TASK_DIR/migration-report.md" ] && halt "Migration report not written" "AG-05" ""
  report_passes "$TASK_DIR/migration-report.md" \
    || halt "Migration failed" "AG-05" "$(cat "$TASK_DIR/migration-report.md")"
  echo "migration-verified" > "$MIGRATION_VERIFIED_FILE"
  record_task_metrics "$TASK_ID" "$TASK_TITLE" "migration" $(( $(date +%s) - MIGRATION_START )) 1 "pass"
  log "MIGRATION: PASS"
elif [ "$HAS_MIGRATION" = "true" ]; then
  log "MIGRATION already complete — skipping"
fi

# ── REFACTOR (skipped with --urgent) ─────────────────────────────────────────
REFACTOR_VERIFIED_FILE="$TASK_DIR/refactor-verified.txt"
if [ "$OPT_URGENT" != "true" ] && [ ! -f "$REFACTOR_VERIFIED_FILE" ]; then
  REFACTOR_START=$(date +%s)
  log "REFACTOR phase..."
  CONTEXT_BLOCK=$(build_context_block)

  # Pre-check: skip the agent if health metrics are already within thresholds
  COMPLEX_COUNT=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(len(d.get('complex_functions', [])))
except Exception:
    print(99)
" "$TASK_DIR/health-report-pre.json" 2>/dev/null || echo 99)

  DUP_PCT=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('duplication_pct', 99))
except Exception:
    print(99)
" "$TASK_DIR/health-report-pre.json" 2>/dev/null || echo 99)

  METRICS_CLEAN=false
  if [ "$COMPLEX_COUNT" -lt 5 ] \
     && python3 -c "import sys; exit(0 if float('$DUP_PCT') < 8.0 else 1)" 2>/dev/null; then
    METRICS_CLEAN=true
  fi

  if [ "$METRICS_CLEAN" = "true" ]; then
    log "REFACTOR phase: metrics clean (complex_fns=${COMPLEX_COUNT}, dup=${DUP_PCT}%) — skipping agent"
    cat > "$TASK_DIR/refactor-report.md" <<REFACTOR_EOF
# Refactor Report — $TASK_ID

Skipped: health metrics within thresholds.
- Complex functions above threshold: ${COMPLEX_COUNT} (limit: 5)
- Code duplication: ${DUP_PCT}% (limit: 8%)

No refactoring needed.
REFACTOR_EOF
  else
    run_agent "ag-06-refactor" "You are AG-06 Refactor for {PROJECT_NAME}.
Improve without changing behaviour: $TASK_SPEC
${CONTEXT_BLOCK:+
$CONTEXT_BLOCK}

Files in scope: ${FILES_IN_SCOPE_JSON_EXPANDED:-packages/}

## Required: run validation before writing the report
\`\`\`bash
pnpm exec tsc --noEmit
pnpm exec biome check --write ${FILES_IN_SCOPE_JSON_EXPANDED:-packages/}
pnpm exec biome check ${FILES_IN_SCOPE_JSON_EXPANDED:-packages/}
pnpm${AFFECTED_PKGS:+ $AFFECTED_PKGS} test
\`\`\`
Do not write refactor-report.md until all four pass.
Write refactor-report.md to $TASK_DIR/
Follow your system prompt exactly." "$TASK_DIR/refactor-output.md"
    [ ! -f "$TASK_DIR/refactor-report.md" ] && halt "Refactor report not written" "AG-06" ""
  fi

  # Hard gate runs regardless of whether the agent ran
  REFACTOR_FAILURES=$(verify_implementation "$FILES_IN_SCOPE_JSON") || true
  [ -n "$REFACTOR_FAILURES" ] && halt "Refactor broke tests" "AG-06" "$REFACTOR_FAILURES"
  echo "refactor-verified" > "$REFACTOR_VERIFIED_FILE"
  record_task_metrics "$TASK_ID" "$TASK_TITLE" "refactor" $(( $(date +%s) - REFACTOR_START )) 1 "pass"
  log "Code health (post-refactor):"
  run_code_health_checks "$TASK_ID" "$TASK_DIR" "$FILES_IN_SCOPE_JSON"
  if [ -f "$TASK_DIR/health-report-pre.json" ] && [ -f "$TASK_DIR/health-report.json" ]; then
    python3 - "$TASK_DIR/health-report-pre.json" "$TASK_DIR/health-report.json" <<'PYEOF'
import json, sys
pre, post = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
deltas = []
for k, label, up in [('coverage_pct','coverage',True),('duplication_pct','dup',False)]:
    if pre.get(k) is not None and post.get(k) is not None:
        d = round(post[k] - pre[k], 1)
        if d != 0:
            good = (d > 0) == up
            arrow = ('↑' if d > 0 else '↓')
            deltas.append(f"{label} {arrow}{abs(d)}%")
if deltas:
    print(f"  Refactor delta: {' · '.join(deltas)}")
else:
    print("  Refactor delta: no measurable change")
PYEOF
  fi
  log "REFACTOR: PASS"
elif [ "$OPT_URGENT" = "true" ]; then
  log "REFACTOR skipped (--urgent)"
else
  log "REFACTOR already complete — skipping"
fi

# ── MUTATION TESTING (security-sensitive tasks only) ──────────────────────────
if [ "$SECURITY_SENSITIVE" = "true" ] && [ "$OPT_URGENT" != "true" ] \
   && [ ! -f "$TASK_DIR/mutation-report.md" ]; then
  MUTATION_START=$(date +%s)
  log "MUTATION TESTING..."
  run_mutation_tests "$TASK_ID" "$TASK_DIR" "$FILES_IN_SCOPE_JSON"
  record_task_metrics "$TASK_ID" "$TASK_TITLE" "mutation" $(( $(date +%s) - MUTATION_START )) 1 "pass"
  log "Mutation testing complete"
fi

# ── SECURITY ──────────────────────────────────────────────────────────────────
SEC_REPORT="$TASK_DIR/security-report.md"
if [ "$OPT_NO_SECURITY" != "true" ] && ! ([ -f "$SEC_REPORT" ] && report_passes "$SEC_REPORT"); then
  SECURITY_PASSED=false
  SECURITY_ATTEMPTS=0
  SECURITY_START=$(date +%s)

  while [ "$SECURITY_PASSED" = false ] && [ "$SECURITY_ATTEMPTS" -lt 3 ]; do
    SECURITY_ATTEMPTS=$(( SECURITY_ATTEMPTS + 1 ))
    log "Security attempt $SECURITY_ATTEMPTS/3..."

    run_agent "ag-07-security" "You are AG-07 Security Agent for {PROJECT_NAME}.

Review the code written for this task.
Task spec: $TASK_SPEC

Files to review (read every one before writing findings):
$(python3 -c "import json,sys; print('\n'.join('  - ' + f for f in json.loads(sys.argv[1])))" "$FILES_IN_SCOPE_JSON")

Apply every rule in .opencode/agents/security-rules.md to every file listed above.
Write security-report.md to $TASK_DIR/
Return PASS or FAIL with specific findings." "$TASK_DIR/sec-output-$SECURITY_ATTEMPTS.md"

    if [ -f "$SEC_REPORT" ] && report_passes "$SEC_REPORT"; then
      SECURITY_PASSED=true
      record_task_metrics "$TASK_ID" "$TASK_TITLE" "security" \
        $(( $(date +%s) - SECURITY_START )) "$SECURITY_ATTEMPTS" "pass"
      record_security_findings "$TASK_ID" "$TASK_DIR"
      check_security_trajectory "$TASK_DIR"
      log "Security: PASS"
    else
      log "Security: FAIL (attempt $SECURITY_ATTEMPTS/3)"
      [ "$SECURITY_ATTEMPTS" -eq 3 ] && halt "Security failed after 3 attempts" "AG-07" \
        "$(cat "$SEC_REPORT")"

      run_agent "ag-04-developer" "You are AG-04 Developer for {PROJECT_NAME}.

The Security Agent has rejected this task. Fix every finding below, then run all
validation commands before marking done.

<security-findings>
$(cat "$SEC_REPORT")
</security-findings>

Task spec for context: $TASK_SPEC

Files in scope (only modify these):
$(python3 -c "import json,sys; print('\n'.join('  - ' + f for f in json.loads(sys.argv[1])))" "$FILES_IN_SCOPE_JSON")

Do not modify test files.

## Validation commands — run all four before marking done
\`\`\`bash
pnpm exec tsc --noEmit
pnpm exec biome check --write ${FILES_IN_SCOPE_JSON_EXPANDED:-packages/}
pnpm exec biome check ${FILES_IN_SCOPE_JSON_EXPANDED:-packages/}
pnpm${AFFECTED_PKGS:+ $AFFECTED_PKGS} test
\`\`\`
Use process.env.DATABASE_URL for DB connections." \
        "$TASK_DIR/dev-secfix-$SECURITY_ATTEMPTS.md"

      SCOPE_VIOLATIONS=$(check_scope_compliance "$FILES_IN_SCOPE_JSON") || true
      [ -n "$SCOPE_VIOLATIONS" ] && revert_scope_violations <<< "$SCOPE_VIOLATIONS"

      POST_SEC_FAILURES=$(verify_implementation "$FILES_IN_SCOPE_JSON") || true
      if [ -n "$POST_SEC_FAILURES" ]; then
        rm -f "$GREEN_VERIFIED_FILE" "$REFACTOR_VERIFIED_FILE"
        halt "Security fix broke tests" "AG-07" "$POST_SEC_FAILURES"
      fi
      log "Post-security hard gate: PASS"
    fi
  done
elif [ "$OPT_NO_SECURITY" = "true" ]; then
  log "Security skipped (--no-security)"
else
  log "Security already passed — skipping"
fi

# ── Git commit ────────────────────────────────────────────────────────────────
log "Committing $TASK_ID..."

while IFS= read -r f; do
  [ -e "$REPO_ROOT/$f" ] && git -C "$REPO_ROOT" add "$f"
done < <(python3 -c "import json,sys; [print(f) for f in json.loads(sys.argv[1])]" "$FILES_IN_SCOPE_JSON")

while IFS= read -r f; do
  base=$(basename "${f%.ts}")
  while IFS= read -r tf; do git -C "$REPO_ROOT" add "$tf"; done \
    < <(find "$REPO_ROOT" -path "*/__tests__/${base}*" 2>/dev/null)
done < <(python3 -c "import json,sys; [print(f) for f in json.loads(sys.argv[1])]" "$FILES_IN_SCOPE_JSON")

if ! git -C "$REPO_ROOT" diff --cached --quiet; then
  git -C "$REPO_ROOT" commit -m "feat($TASK_ID): $TASK_TITLE"
  log "Committed: feat($TASK_ID): $TASK_TITLE"
else
  log "Nothing new to commit"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL_S=$(python3 -c "
import json, os
f = '$TASK_DIR/metrics.json'
if not os.path.exists(f):
    print('—')
else:
    data = json.load(open(f))
    total = sum(t.get('total_duration_s', 0) for t in data.get('tasks', {}).values())
    print(f'{total}s')
")

printf "\a"  # terminal bell
log ""
log "========================================"
log "✅ Task complete: $TASK_TITLE"
log "Duration     : $TOTAL_S"
log "Output       : $TASK_DIR"
log "========================================"
