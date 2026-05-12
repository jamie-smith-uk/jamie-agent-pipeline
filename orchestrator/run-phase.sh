#!/bin/bash

set -euo pipefail

# ── {PROJECT_NAME} Pipeline Runner ───────────────────────────────────────────
# Usage: ./orchestrator/run-phase.sh --phase 1
# Requires: opencode CLI, ANTHROPIC_API_KEY

# ── Args ─────────────────────────────────────────────────────────────────────
PHASE=""
for arg in "$@"; do
  case $arg in
    --phase=*) PHASE="${arg#*=}" ;;
    --phase) PHASE="${2}" ; shift ;;
  esac
done

if [[ "${PIPELINE_LIB_ONLY:-}" != "1" ]] && [ -z "$PHASE" ]; then
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

# Construct DATABASE_URL from individual vars if not already set
if [ -z "${DATABASE_URL:-}" ]; then
  DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
  export DATABASE_URL
fi

mkdir -p "$PIPELINE_DIR"
PHASE_STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CONTEXT_MAX_CHARS=12000  # max context.md chars injected into agent prompts (~3k tokens)
ARCH_DOC_MAX_CHARS=6000  # include full architecture doc below this size; tier above it

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
  printf "\a"  # terminal bell
  log "PIPELINE HALTED: $reason (agent: $agent)"
  echo "=== HALT DETAIL ===" >&2
  echo "$detail" >&2
  echo "===================" >&2
  exit 1
}

run_agent() {
  local agent_id="$1" prompt="$2" output_file="$3" timeout_secs="${4:-0}"
  log "[$agent_id] Starting..."

  if [ "$timeout_secs" -gt 0 ] 2>/dev/null; then
    timeout "$timeout_secs" opencode run --agent "$agent_id" "$prompt" > "$output_file" 2>&1
  else
    opencode run --agent "$agent_id" "$prompt" > "$output_file" 2>&1
  fi
  local exit_code=$?

  # exit code 124 = timeout — return it to the caller for graceful handling
  if [ $exit_code -eq 124 ]; then
    log "[$agent_id] TIMEOUT after ${timeout_secs}s"
    return 124
  fi

  if [ $exit_code -ne 0 ]; then
    halt "Agent invocation failed (exit $exit_code)" "$agent_id" "$(cat "$output_file")"
  fi

  # Opportunistic token cost capture — records if opencode emits usage data.
  # Format varies by opencode version; extend this pattern as needed.
  local usage_line
  usage_line=$(grep -iE "tokens?[: ]+[0-9]|input[_: ]+[0-9]+.*output[_: ]+[0-9]+" \
    "$output_file" 2>/dev/null | tail -1 || true)
  if [ -n "$usage_line" ] && [ -f "$PIPELINE_DIR/metrics.json" ]; then
    python3 -c "
import json, sys, re
f, agent, usage = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(f))
token_log = data.setdefault('token_log', [])
token_log.append({'agent': agent, 'usage': usage})
with open(f, 'w') as fp:
    json.dump(data, fp, indent=2)
" "$PIPELINE_DIR/metrics.json" "$agent_id" "$usage_line" 2>/dev/null || true
  fi

  log "[$agent_id] Complete"
}

wait_for_approval() {
  local approval_file="$PIPELINE_DIR/approval.json"
  local deadline=$(( $(date +%s) + 86400 )) # 24 hours

  log "========================================" >&2
  log "HUMAN GATE — review the manifest above" >&2
  log "To approve:  ./orchestrator/approve.sh --phase $PHASE" >&2
  log "To stop:     ./orchestrator/approve.sh --phase $PHASE --stop" >&2
  log "To request changes: ./orchestrator/approve.sh --phase $PHASE --changes \"describe changes\"" >&2
  log "========================================" >&2

  while [ $(date +%s) -lt $deadline ]; do
    if [ -f "$approval_file" ]; then
      local signal
      # Pass path as argv[1] — never interpolate filesystem paths into Python source code
      signal=$(python3 - "$approval_file" <<'PYEOF'
import json, sys
try:
    print(json.load(open(sys.argv[1]))['signal'])
except Exception as e:
    print(f"error:{e}", end="")
PYEOF
)
      log "Approval received: $signal" >&2
      echo "$signal"
      return 0
    fi
    sleep 2
  done

  halt "Approval timeout" "human-gate" "No approval signal received within 24 hours"
}

# Checks that a report file contains a PASS verdict in its opening lines.
# Only inspects the first 10 lines so that references to earlier PASS reports
# in the body cannot create a false positive.
# Accepted formats (all must appear in lines 1-10):
#   "Title: ... — PASS"
#   "# ... — PASS"
#   "**Verdict:** PASS"  /  "**Result:** PASS"  /  "**Result: PASS**"
#   "VERDICT: PASS"  (machine-readable sentinel)
report_passes() {
  local file="$1"
  python3 - "$file" <<'PYEOF'
import re, sys
try:
    with open(sys.argv[1]) as fh:
        head = [next(fh, '') for _ in range(10)]
except Exception:
    sys.exit(1)
pattern = re.compile(
    r'(Title:|#{1,2}\s.+|VERDICT:).*\bPASS\b'
    r'|\*\*(Verdict|Result)[: ]+PASS(\*\*)?',
    re.IGNORECASE
)
sys.exit(0 if any(pattern.search(line) for line in head) else 1)
PYEOF
}

# Returns accumulated build context, capped at CONTEXT_MAX_CHARS (most recent tasks).
# Output is empty if no context exists yet (first task in phase).
build_context_block() {
  local context_file="$PIPELINE_DIR/context.md"
  [ -f "$context_file" ] && [ -s "$context_file" ] || return 0

  local content
  content=$(cat "$context_file")

  if [ ${#content} -gt "$CONTEXT_MAX_CHARS" ]; then
    content=$(python3 -c "
import sys
content = sys.stdin.read()
tail = content[-$CONTEXT_MAX_CHARS:]
idx = tail.find('\n## ')
if idx > 0:
    tail = tail[idx+1:]
print('*(Earlier tasks omitted — see context.md for full history)*\n\n' + tail)
" <<< "$content")
  fi

  printf "<build-context>\n## Context from completed tasks in this phase\n\n%s\n</build-context>\n" "$content"
}

# Appends one phase entry to pipeline/phase-N/metrics.json (creates file if absent).
# Args: task_id task_title phase duration_s attempts result
record_task_metrics() {
  local task_id="$1" task_title="$2" phase="$3" duration_s="$4" attempts="$5" result="$6"
  python3 - "$PIPELINE_DIR/metrics.json" \
    "$task_id" "$task_title" "$phase" "$duration_s" "$attempts" "$result" \
    "$PHASE" "$PHASE_STARTED_AT" <<'PYEOF'
import json, os, sys
f = sys.argv[1]
task_id, title, phase = sys.argv[2], sys.argv[3], sys.argv[4]
duration, attempts, result = int(sys.argv[5]), int(sys.argv[6]), sys.argv[7]
raw_phase, started_at = sys.argv[8], sys.argv[9]
try:
    phase_num = int(raw_phase)
except ValueError:
    phase_num = raw_phase

data = json.load(open(f)) if os.path.exists(f) else {
    'phase': phase_num, 'started_at': started_at, 'tasks': {}
}
task = data['tasks'].setdefault(task_id, {'title': title})
task[phase] = {'duration_s': duration, 'attempts': attempts, 'result': result}
task['total_duration_s'] = sum(
    v['duration_s'] for v in task.values()
    if isinstance(v, dict) and 'duration_s' in v
)
with open(f, 'w') as fp:
    json.dump(data, fp, indent=2)
PYEOF
}

# Mutation testing for security-sensitive tasks. Makes targeted mutations to
# security-critical lines and checks if tests catch them. Results written to
# $TASK_DIR/mutation-report.md. Warnings only — not a hard FAIL gate.
run_mutation_tests() {
  local task_id="$1" task_dir="$2" files_in_scope_json="$3"
  local mutations_total=0 mutations_caught=0
  local survived_list=""

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local full="$REPO_ROOT/$f"
    [[ -f "$full" ]] || continue

    # Find first line matching a security-critical pattern (priority order)
    local line_num=""
    for pat in "ALLOWED_CHAT_ID\|allowed_chat\|whitelist" \
               "authenticate\|authorize\|isAuthorized" \
               '\$[0-9]' \
               "validateInput\|isValid\|sanitize"; do
      line_num=$(grep -nm1 "$pat" "$full" 2>/dev/null | cut -d: -f1 || true)
      [[ -n "$line_num" ]] && break
    done
    [[ -z "$line_num" ]] && continue

    mutations_total=$(( mutations_total + 1 ))

    # Mutate: comment out the matched line (Python handles cross-platform)
    python3 -c "
import sys
fp, n = sys.argv[1], int(sys.argv[2])
lines = open(fp).readlines()
lines[n-1] = '// MUTATED: ' + lines[n-1]
open(fp, 'w').writelines(lines)
" "$full" "$line_num"

    if timeout 60 bash -c "cd '$REPO_ROOT' && pnpm test" > /dev/null 2>&1; then
      survived_list+="  - $f line $line_num\n"
      log "  ⚠ Mutation survived: $f:$line_num"
    else
      mutations_caught=$(( mutations_caught + 1 ))
      log "  ✓ Mutation caught: $f:$line_num"
    fi

    # Restore original
    python3 -c "
import sys
fp, n = sys.argv[1], int(sys.argv[2])
lines = open(fp).readlines()
lines[n-1] = lines[n-1].replace('// MUTATED: ', '', 1)
open(fp, 'w').writelines(lines)
" "$full" "$line_num"

  done < <(python3 -c "import json,sys; [print(f) for f in json.loads(sys.argv[1])]" \
    "$files_in_scope_json")

  {
    if [ "$mutations_total" -eq 0 ]; then
      printf "Title: Mutation Report — %s — WARN\n\n" "$task_id"
      printf "No security-critical patterns found to mutate.\n"
      printf "Verify that security paths are explicitly tested in __tests__/ files.\n"
    elif [ "$mutations_caught" -eq "$mutations_total" ]; then
      printf "Title: Mutation Report — %s — PASS\n\n" "$task_id"
      printf "All %d mutation(s) caught by tests. Security paths are covered.\n" \
        "$mutations_total"
    else
      local survived=$(( mutations_total - mutations_caught ))
      printf "Title: Mutation Report — %s — WARN\n\n" "$task_id"
      printf "%d of %d mutation(s) survived — these security paths may lack test coverage:\n\n" \
        "$survived" "$mutations_total"
      printf "%b" "$survived_list"
      printf "\nAdd tests that verify the security check is enforced when removed.\n"
    fi
  } > "$task_dir/mutation-report.md"
}

# Parses security FAIL outputs for this task and records violated rule categories
# in metrics.json under tasks.<id>.security_findings.
record_security_findings() {
  local task_id="$1" task_dir="$2"
  python3 - "$PIPELINE_DIR/metrics.json" "$task_id" "$task_dir" <<'PYEOF'
import json, os, re, sys
metrics_file, task_id, task_dir = sys.argv[1], sys.argv[2], sys.argv[3]
if not os.path.exists(metrics_file):
    sys.exit(0)
data = json.load(open(metrics_file))
if task_id not in data.get('tasks', {}):
    sys.exit(0)

rule_patterns = [
    "Parameterised queries", "Prompt injection", "Input validation",
    "Cron injection", "Secrets in .env", "Never log secrets",
    "Agent exposure", "secrets in git", "Whitelist on every handler",
    "agent-constructed SQL", "OAuth tokens", "Admin UI",
    "No PII in logs", "Label all external content", "No stack traces",
    "Statement timeout", "Zero high or critical", "exact versions",
    "No unjustified",
]
violated = set()
for fname in sorted(os.listdir(task_dir)):
    if not fname.startswith('sec-output-'):
        continue
    try:
        content = open(os.path.join(task_dir, fname)).read()
        if 'FAIL' not in content:
            continue
        for pattern in rule_patterns:
            if re.search(pattern, content, re.IGNORECASE):
                violated.add(pattern)
    except Exception:
        pass
if violated:
    data['tasks'][task_id]['security_findings'] = sorted(violated)
    with open(metrics_file, 'w') as fp:
        json.dump(data, fp, indent=2)
PYEOF
}

# Trajectory evaluation: verifies the Tester wrote real test files with assertions.
# Logs warnings — does not halt. Called after RED phase.
check_tester_trajectory() {
  local task_dir="$1" tests_written_file="$2"
  local ac_count="$3"  # number of acceptance criteria (minimum test count target)
  local issues=""

  # Find test files created or modified within 10 minutes of tests-written.txt.
  # Using -newer alone misses files written in the same second as the sentinel
  # or files that the tester wrote before touching the sentinel. Use a 10-minute
  # window from the sentinel's modification time as a generous but bounded proxy.
  local sentinel_time
  sentinel_time=$(python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" \
    "$tests_written_file" 2>/dev/null || echo "0")
  local window_start=$(( sentinel_time - 600 ))  # 10 minutes before sentinel

  local test_count=0
  local files_without_assertions=()
  while IFS= read -r tf; do
    [[ -f "$tf" ]] || continue
    local tf_time
    tf_time=$(python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" \
      "$tf" 2>/dev/null || echo "0")
    [[ "$tf_time" -ge "$window_start" ]] || continue
    test_count=$(( test_count + 1 ))
    if ! grep -qE "expect\(|it\(|test\(|describe\(" "$tf" 2>/dev/null; then
      files_without_assertions+=("$(basename "$tf")")
    fi
  done < <(find "$REPO_ROOT" \( -name "*.test.ts" -o -name "*.spec.ts" \) \
    -not -path "*/node_modules/*" 2>/dev/null)

  if [ "$test_count" -eq 0 ]; then
    issues+="No test files found after RED phase — Tester may not have written any tests\n"
  else
    if [ ${#files_without_assertions[@]} -gt 0 ]; then
      issues+="Test files with no assertions: ${files_without_assertions[*]}\n"
    fi
    if [ -n "$ac_count" ] && [ "$test_count" -lt "$ac_count" ]; then
      issues+="$test_count test file(s) for $ac_count acceptance criteria — some ACs may be uncovered\n"
    fi
  fi

  if [ -n "$issues" ]; then
    log "  Tester trajectory warnings:"
    printf "%b" "$issues" | while IFS= read -r line; do
      [[ -n "$line" ]] && log "    ⚠ $line"
    done
  fi
}

# Trajectory evaluation: verifies the Security PASS report mentions all known rules.
# Logs warnings — does not halt. Called after security PASS.
check_security_trajectory() {
  local task_dir="$1"
  local sec_report="$task_dir/security-report.md"
  local rules_file="$REPO_ROOT/.opencode/agents/security-rules.md"

  [[ -f "$sec_report" ]] && [[ -f "$rules_file" ]] || return 0

  local missing
  missing=$(python3 - "$sec_report" "$rules_file" <<'PYEOF'
import re, sys
report = open(sys.argv[1]).read().lower()
rules = open(sys.argv[2]).read()
rule_names = re.findall(r'### ([^\n]+)', rules)
missing = [r for r in rule_names if r.lower() not in report]
if missing:
    print(f"{len(missing)} rule(s) not mentioned in security report: "
          f"{', '.join(missing[:4])}{'...' if len(missing) > 4 else ''}")
PYEOF
)
  if [ -n "$missing" ]; then
    log "  Security trajectory warning: $missing"
  fi
}

# Runs code health checks (duplication, coverage, complexity) on files_in_scope.
# Optional 4th arg "pre-refactor" writes health-report-pre.json for before/after comparison.
# Logs results immediately. Informational only — does not gate the pipeline.
run_code_health_checks() {
  local task_id="$1" task_dir="$2" files_in_scope_json="$3"
  local label="${4:-}"
  # skip_tests=1: reuse existing coverage-summary.json instead of re-running the suite.
  # verify_implementation already ran tests; no need to pay the cost twice (P-02 fix).
  local skip_tests="${5:-0}"
  local report_file
  if [ "$label" = "pre-refactor" ]; then
    report_file="$task_dir/health-report-pre.json"
  else
    report_file="$task_dir/health-report.json"
  fi

  python3 - "$REPO_ROOT" "$PIPELINE_DIR/metrics.json" \
    "$task_id" "$files_in_scope_json" "$report_file" "$label" "$skip_tests" <<'PYEOF'
import json, os, re, subprocess, sys

repo_root, metrics_file = sys.argv[1], sys.argv[2]
task_id, files_json, report_file = sys.argv[3], sys.argv[4], sys.argv[5]
label = sys.argv[6] if len(sys.argv) > 6 else ''
skip_tests = sys.argv[7] == '1' if len(sys.argv) > 7 else False

files = [f for f in json.loads(files_json)
         if os.path.isfile(os.path.join(repo_root, f))]
ts_files = [os.path.join(repo_root, f) for f in files
            if f.endswith('.ts') or f.endswith('.tsx')]

report = {'task_id': task_id, 'files_checked': files}

# ── Complexity: parse Biome JSON output for noExcessiveCognitiveComplexity ───
# Biome --reporter=json emits structured diagnostics including the rule name
# and the cognitive complexity score extracted from the message text.
# This replaces the fragile line-counting regex heuristic.
complex_fns = []
if ts_files:
    try:
        r = subprocess.run(
            ['pnpm', 'exec', 'biome', 'check', '--reporter=json', *ts_files],
            capture_output=True, text=True, cwd=repo_root, timeout=60
        )
        # Biome writes JSON to stdout; exit code non-zero when violations found
        if r.stdout.strip():
            biome_out = json.loads(r.stdout)
            for diag in biome_out.get('diagnostics', []):
                # Filter to complexity rule only
                category = diag.get('category', '')
                if 'noExcessiveCognitiveComplexity' not in category:
                    continue
                # Extract file and line from the first span
                spans = diag.get('advices', {}).get('advices', [])
                location = diag.get('location', {})
                fp = location.get('path', {}).get('file', '')
                line = (location.get('span', [0])[0] or 0)
                # Extract score from message, e.g. "Excessive complexity of 14 detected"
                msg = diag.get('message', '')
                score_match = re.search(r'complexity of (\d+)', msg)
                score = int(score_match.group(1)) if score_match else 0
                rel = os.path.relpath(fp, repo_root) if fp else fp
                # Convert byte offset to line number if needed
                if fp and os.path.isfile(fp) and isinstance(line, int) and line > 1000:
                    # Biome reports byte offset, convert to line
                    try:
                        content = open(fp, 'rb').read()
                        line = content[:line].count(b'\n') + 1
                    except Exception:
                        pass
                complex_fns.append({
                    'file': rel,
                    'line': line,
                    'score': score,
                })
    except (json.JSONDecodeError, Exception):
        pass
report['complex_functions'] = complex_fns[:10]  # cap at 10

# ── Duplication: run jscpd if available ──────────────────────────────────────
duplication_pct = None
if ts_files:
    try:
        r = subprocess.run(
            ['npx', '--yes', 'jscpd@3.5.10', '--min-lines', '5', '--reporters', 'json',
             '--output', '/tmp/jscpd-out', *ts_files],
            capture_output=True, text=True, cwd=repo_root, timeout=30
        )
        jscpd_json = '/tmp/jscpd-out/jscpd-report.json'
        if os.path.exists(jscpd_json):
            d = json.load(open(jscpd_json))
            stats = d.get('statistics', {}).get('total', {})
            duplication_pct = round(stats.get('percentage', 0), 1)
    except Exception:
        pass
report['duplication_pct'] = duplication_pct

# ── Coverage: read existing summary or run vitest --coverage ─────────────────
# If skip_tests=True, reuse the coverage-summary.json from the verify_implementation
# run that already passed — avoids running the full test suite a second time (P-02).
coverage_pct = None
summary_file = os.path.join(repo_root, 'coverage', 'coverage-summary.json')
try:
    if not skip_tests:
        subprocess.run(
            ['pnpm', 'test', '--coverage', '--coverage.reporter=json-summary'],
            capture_output=True, text=True, cwd=repo_root, timeout=120
        )
    if os.path.exists(summary_file):
        s = json.load(open(summary_file))
        total = s.get('total', {})
        lines = total.get('lines', {})
        if 'pct' in lines:
            coverage_pct = round(lines['pct'], 1)
except Exception:
    pass
report['coverage_pct'] = coverage_pct

# ── Write report ─────────────────────────────────────────────────────────────
with open(report_file, 'w') as fp:
    json.dump(report, fp, indent=2)

# ── Log immediately to terminal ───────────────────────────────────────────────
prefix = 'pre-refactor: ' if label == 'pre-refactor' else ''
parts = []
if coverage_pct is not None:
    parts.append(f'coverage {coverage_pct}%')
if duplication_pct is not None:
    parts.append(f'dup {duplication_pct}%')
if complex_fns:
    parts.append(f'{len(complex_fns)} complexity violation(s)')
    for fn in complex_fns[:3]:
        score_str = f" (score {fn['score']})" if fn.get('score') else ''
        parts_detail = f"    {fn['file']}:{fn['line']}{score_str}"
        print(parts_detail)
if parts:
    print(f'  {prefix}' + ' · '.join(parts))
elif files:
    print(f'  {prefix}(coverage/duplication tools not available)')

# ── Record in metrics (final report only, not pre-refactor baseline) ──────────
if label == 'pre-refactor' or not os.path.exists(metrics_file):
    sys.exit(0)
data = json.load(open(metrics_file))
if task_id in data.get('tasks', {}):
    data['tasks'][task_id]['health'] = {
        'complex_fn_count': len(complex_fns),
        'max_complexity_score': max((f.get('score', 0) for f in complex_fns), default=0),
        'duplication_pct': duplication_pct,
        'coverage_pct': coverage_pct,
    }
    with open(metrics_file, 'w') as fp:
        json.dump(data, fp, indent=2)
PYEOF
}

# Runs tsc --noEmit, ESLint on files that exist from files_in_scope, and pnpm test.
# Prints combined failure output to stdout (empty on full pass).
# Returns 0 if all checks pass, 1 if any fail.
# NOTE: output is intentionally NOT truncated — the full tsc/lint/test output is
# captured so the developer receives the complete picture on retry.
#
# Args:
#   $1  files_in_scope_json   — JSON array of in-scope file paths
#   $2  baseline_file         — optional path to baseline-failures.txt; when
#                               supplied, pnpm test failures that already existed
#                               before the developer ran (infrastructure errors,
#                               unrelated packages) are stripped from the gate
#                               output so the developer is not blamed for them.
verify_implementation() {
  local files_in_scope_json="$1"
  local baseline_file="${2:-}"
  local failures=""

  # Resolve existing files from files_in_scope (used by linter below)
  local existing_files=()
  while IFS= read -r line; do
    existing_files+=("$line")
  done < <(python3 -c "
import json, os, sys
files = json.loads(sys.argv[1])
for f in files:
    full = os.path.join('$REPO_ROOT', f)
    if os.path.isfile(full):
        print(full)
" "$files_in_scope_json" 2>/dev/null)

  # Determine linter while tsc starts up
  local linter="eslint"
  if grep -q '"@biomejs/biome"' "$REPO_ROOT/package.json" 2>/dev/null; then
    linter="biome"
  fi

  # Launch tsc and linter in parallel using temp files for output + exit codes
  local tsc_out tsc_rc_file lint_out lint_rc_file tsc_pid lint_pid
  tsc_out=$(mktemp)
  tsc_rc_file=$(mktemp)
  { cd "$REPO_ROOT" && pnpm exec tsc --noEmit 2>&1; echo $? > "$tsc_rc_file"; } > "$tsc_out" &
  tsc_pid=$!

  lint_pid=""
  if [ ${#existing_files[@]} -gt 0 ]; then
    lint_out=$(mktemp)
    lint_rc_file=$(mktemp)
    if [ "$linter" = "biome" ]; then
      { cd "$REPO_ROOT" && pnpm exec biome check "${existing_files[@]}" 2>&1; echo $? > "$lint_rc_file"; } > "$lint_out" &
    else
      { cd "$REPO_ROOT" && pnpm exec eslint "${existing_files[@]}" 2>&1; echo $? > "$lint_rc_file"; } > "$lint_out" &
    fi
    lint_pid=$!
  fi

  # Collect tsc result
  wait "$tsc_pid"
  if [ "$(cat "$tsc_rc_file")" -ne 0 ]; then
    failures+="=== tsc --noEmit ===
$(cat "$tsc_out")

"
  fi
  rm -f "$tsc_out" "$tsc_rc_file"

  # Collect linter result
  if [ -n "$lint_pid" ]; then
    wait "$lint_pid"
    if [ "$(cat "$lint_rc_file")" -ne 0 ]; then
      failures+="=== $linter ===
$(cat "$lint_out")

"
    fi
    rm -f "$lint_out" "$lint_rc_file"
  fi

  local affected_pkgs
  affected_pkgs=$(python3 -c "
import json, sys, re
files = json.loads(sys.argv[1])
pkgs = set()
for f in files:
    m = re.match(r'packages/([^/]+)/', f)
    if m: pkgs.add('@lifeos/' + m.group(1))
print(' '.join('--filter ' + p for p in sorted(pkgs)) if pkgs else '')
" "$files_in_scope_json" 2>/dev/null)

  # shellcheck disable=SC2086
  out=$(cd "$REPO_ROOT" && pnpm ${affected_pkgs} test 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    # When a baseline file exists, filter out failures that were already present
    # before the developer ran. Only surface genuinely new failures.
    local test_failures_out="$out"
    if [ -n "$baseline_file" ] && [ -f "$baseline_file" ]; then
      test_failures_out=$(python3 - "$out" "$baseline_file" <<'PYEOF'
import re, sys

raw_output  = sys.argv[1]
baseline_path = sys.argv[2]

try:
    baseline = set(line.strip() for line in open(baseline_path) if line.strip())
except FileNotFoundError:
    baseline = set()

if not baseline:
    # No baseline recorded — pass through everything
    print(raw_output)
    sys.exit(0)

# Extract failing test identifiers from current run
fail_files_now = set(re.findall(r'^\s*FAIL\s+(\S+)', raw_output, re.MULTILINE))
fail_tests_now = set(re.findall(r'^\s*×\s+(.+?)\s+\d+ms', raw_output, re.MULTILINE))
all_now = fail_files_now | fail_tests_now

new_failures = all_now - baseline

if not new_failures:
    # Every failure existed in the baseline — treat as clean for the gate
    note = (
        "NOTE: pnpm test returned non-zero but ALL failures were pre-existing "
        "before this task's implementation (recorded in baseline-failures.txt). "
        "These are infrastructure or unrelated-package failures — not caused by "
        "this task. Gate treating test step as PASS.\n\n"
        "Pre-existing failures:\n" +
        '\n'.join(f"  - {f}" for f in sorted(baseline))
    )
    print(note)
    sys.exit(1)   # signal to caller: treat as pass (caller checks new_failures empty)

# There are new failures — report only those prominently, then append full output
new_list = '\n'.join(f"  - {f}" for f in sorted(new_failures))
print(f"NEW failures (not in baseline):\n{new_list}\n\nFull test output:\n{raw_output}")
sys.exit(0)
PYEOF
      )
      # Check if all failures were baseline — python exits 1 to signal "treat as pass"
      local py_rc=$?
      if [ $py_rc -eq 1 ]; then
        # All failures were pre-existing — log informational note, skip gate failure
        log "pnpm test: non-zero exit but all failures are pre-existing (baseline). Skipping test gate."
        printf "%s" "$failures"
        [ -z "$failures" ]
        return
      fi
    fi

    failures+="=== pnpm test ===
${test_failures_out}

"
  fi

  printf "%s" "$failures"
  [ -z "$failures" ]
}

# Checks that all git-modified and new files (excluding pipeline/ and __tests__/)
# are listed in files_in_scope_json. Prints violating paths, returns 1 if any found.
check_scope_compliance() {
  local files_in_scope_json="$1"
  local violations=""

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ "$f" == pipeline/* ]] && continue
    [[ "$f" == *__tests__* ]] && continue
    [[ "$f" == *.tsbuildinfo ]] && continue
    # Always-allowed support files — type/env additions are common cross-task
    # needs; both security and test gates still run on them.
    [[ "$f" == packages/shared/src/types.ts ]] && continue
    [[ "$f" == packages/shared/src/env.ts ]] && continue
    [[ "$f" == packages/shared/dist/* ]] && continue
    local in_scope
    in_scope=$(python3 -c "
import json, sys
print('yes' if sys.argv[2] in json.loads(sys.argv[1]) else 'no')
" "$files_in_scope_json" "$f" 2>/dev/null)
    [ "$in_scope" = "no" ] && violations+="$f"$'\n'
  done < <(
    git -C "$REPO_ROOT" diff --name-only HEAD 2>/dev/null
    git -C "$REPO_ROOT" ls-files --others --exclude-standard "$REPO_ROOT" 2>/dev/null \
      | sed "s|$REPO_ROOT/||"
  )

  [ -z "$violations" ] && return 0
  printf "%s" "$violations"
  return 1
}

# Reverts files returned by check_scope_compliance (tracked = git checkout, new = rm).
revert_scope_violations() {
  while IFS= read -r vf; do
    [[ -z "$vf" ]] && continue
    if git -C "$REPO_ROOT" ls-files --error-unmatch "$vf" 2>/dev/null; then
      if ! git -C "$REPO_ROOT" checkout HEAD -- "$vf" 2>/dev/null; then
        log "  WARNING: could not revert $vf via git checkout (index locked?) — using rm fallback"
        rm -f "$REPO_ROOT/$vf"
      fi
    else
      rm -f "$REPO_ROOT/$vf"
    fi
    log "  Reverted out-of-scope: $vf"
  done
}

# When sourced with PIPELINE_LIB_ONLY=1, stop here — caller gets the functions above.
[[ "${PIPELINE_LIB_ONLY:-}" == "1" ]] && return 0 2>/dev/null || true

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

if [[ "${SKIP_ARCHITECT:-}" == "1" ]]; then
  log "SKIP_ARCHITECT=1 — skipping AG-01, AG-02, and human gate"
  if [ ! -f "$PIPELINE_DIR/task-manifest.json" ]; then
    halt "task-manifest.json not found" "orchestrator" \
      "SKIP_ARCHITECT=1 requires task-manifest.json to already exist in $PIPELINE_DIR/"
  fi
  log "task-manifest.json found — proceeding to task execution"
fi

# ── Header ────────────────────────────────────────────────────────────────────
log "========================================"
log "{PROJECT_NAME} Pipeline — Phase $PHASE"
log "========================================"

# Tiered context: extract only the relevant phase section and its epics from the PRD.
# Computed unconditionally so DEV_PROMPT can reference it even when SKIP_ARCHITECT=1.
PHASE_PRD_CONTENT=$(python3 - "$REPO_ROOT/docs/prd.md" "$PHASE" <<'PYEOF'
import re, sys
try:
    content = open(sys.argv[1]).read()
except FileNotFoundError:
    print("(docs/prd.md not found — create it before running the pipeline)")
    sys.exit(0)
phase_num = sys.argv[2]
phase_match = re.search(
    rf'(## Phase {phase_num}[^\n]*\n.*?)(?=\n## Phase \d+|\Z)',
    content, re.DOTALL
)
phase_section = phase_match.group(1) if phase_match else ''
epics = list(dict.fromkeys(re.findall(r'EP-\d+', phase_section)))
stories = []
for ep in epics:
    m = re.search(rf'(### {ep}[^\n]*\n.*?)(?=\n### |\n---|\Z)', content, re.DOTALL)
    if m:
        stories.append(m.group(1))
result = phase_section
if stories:
    result += '\n\n## User stories for this phase\n\n' + '\n\n'.join(stories)
print(result.strip() if result.strip() else content)
PYEOF
)

# Tiered architecture doc: inject in full if small; extract relevant sections if large.
# Keywords are drawn from the phase PRD content so only in-scope sections are included.
ARCH_DOC=$(python3 - "$REPO_ROOT/docs/architecture.md" \
  "$ARCH_DOC_MAX_CHARS" "$PHASE_PRD_CONTENT" <<'PYEOF'
import re, sys
try:
    content = open(sys.argv[1]).read()
except FileNotFoundError:
    print("(docs/architecture.md not found — create it before running the pipeline)")
    sys.exit(0)

max_chars, prd_content = int(sys.argv[2]), sys.argv[3]

if len(content) <= max_chars:
    print(content)
    sys.exit(0)

# Extract sections: split on ## headings
parts = re.split(r'\n(## [^\n]+)', content)
intro = parts[0]  # content before first ## heading

# Always include overview/structure sections regardless of keywords
always = {'overview', 'system', 'component', 'repository', 'structure', 'stack', 'non-functional'}

# Keywords from phase PRD content (file paths, module names, significant words)
keywords = set(w for w in re.findall(r'\b[a-z][a-z0-9/_-]{3,}\b', prd_content.lower())
               if w not in {'this', 'that', 'with', 'from', 'have', 'will', 'each', 'must',
                            'should', 'phase', 'task', 'file', 'code', 'test', 'spec'})

included = [intro] if intro.strip() else []
i = 1
while i < len(parts) - 1:
    heading, body = parts[i], parts[i + 1]
    heading_lower = heading.lower()
    if any(kw in heading_lower for kw in always) or \
       any(kw in heading_lower or kw in body[:400].lower() for kw in keywords):
        included.append(heading + body)
    i += 2

result = '\n'.join(included)
if len(result) < len(content):
    result = '*(Architecture doc filtered for relevance — full doc at docs/architecture.md)*\n\n' \
             + result
print(result)
PYEOF
)

if [[ "${SKIP_ARCHITECT:-}" != "1" ]]; then

# ── AG-01 Architect ───────────────────────────────────────────────────────────
log ""
log "AG-01 Architect — producing task manifest..."

# Produce a compact repo file tree for the Architect so it can name real files
# in files_in_scope. Excludes noise directories. Capped at 300 lines to stay
# within a sensible context budget.
REPO_FILE_TREE=$(python3 - "$REPO_ROOT" <<'PYEOF'
import os, sys

root = sys.argv[1]
skip = {
    'node_modules', '.git', 'dist', 'build', 'coverage',
    'pipeline', '.turbo', '.next', '__pycache__', '.cache',
}
lines = []
for dirpath, dirnames, filenames in os.walk(root):
    # Prune skip dirs in-place so os.walk doesn't descend into them
    dirnames[:] = sorted(d for d in dirnames if d not in skip and not d.startswith('.'))
    rel = os.path.relpath(dirpath, root)
    depth = 0 if rel == '.' else rel.count(os.sep) + 1
    indent = '  ' * depth
    folder = os.path.basename(dirpath) if rel != '.' else '.'
    lines.append(f"{indent}{folder}/")
    for fname in sorted(filenames):
        lines.append(f"{indent}  {fname}")
    if len(lines) > 300:
        lines.append("  ... (truncated)")
        break

print('\n'.join(lines[:300]))
PYEOF
)

ARCH_PROMPT="You are running as AG-01 Architect for {PROJECT_NAME}.

Here is the PRD content for Phase $PHASE:
<prd-phase>
$PHASE_PRD_CONTENT
</prd-phase>

Here is the Architecture document:
<architecture>
$ARCH_DOC
</architecture>

Here is the current repository file tree (use this to assign real, existing paths in files_in_scope):
<repo-file-tree>
$REPO_FILE_TREE
</repo-file-tree>

Produce the task manifest for Phase $PHASE.

Write two files to pipeline/phase-$PHASE/:
1. task-manifest.json
2. manifest-summary.md

STRICT SCHEMA REQUIREMENT — every task object in task-manifest.json MUST have ALL of these fields
with EXACTLY these types and allowed values. The manifest will be machine-validated and will be
rejected if any field is missing or uses a non-allowed value:

  {
    "id":                   string   — e.g. "task-1" (sequential, no other format)
    "title":                string
    "description":          string
    "files_in_scope":       string[] — MUST be non-empty; use exact repo paths from the file tree above
    "dependencies":         string[] — task ids; use [] if none
    "acceptance_criteria":  string[] — MUST be non-empty; each item must be a specific testable statement
    "security_sensitive":   boolean  — true or false (REQUIRED — never omit this field)
    "estimated_complexity": string   — MUST be exactly one of: "low", "medium", "high"
                                       DO NOT use XS, S, M, L, XL, or any other value
  }

Follow your system prompt exactly."

if [ ! -f "$PIPELINE_DIR/task-manifest.json" ]; then
  run_agent "ag-01-architect" "$ARCH_PROMPT" "$PIPELINE_DIR/ag01-output.md"
else
  log "task-manifest.json already exists — skipping AG-01"
fi

if [ ! -f "$PIPELINE_DIR/task-manifest.json" ]; then
  halt "task-manifest.json not produced" "AG-01" "Architect did not write task-manifest.json"
fi

# ── Manifest schema validation ────────────────────────────────────────────────
SCHEMA_ERRORS=$(python3 - "$PIPELINE_DIR/task-manifest.json" <<'PYEOF'
import json, sys

try:
    data = json.load(open(sys.argv[1]))
except json.JSONDecodeError as e:
    print(f"Invalid JSON: {e}")
    sys.exit(0)

tasks = data if isinstance(data, list) else data.get('tasks', data.get('task_order', []))
tasks = [t for t in tasks if isinstance(t, dict)]

if not tasks:
    print("Manifest contains no tasks")
    sys.exit(0)

required = ['id', 'title', 'description', 'files_in_scope',
            'acceptance_criteria', 'security_sensitive', 'estimated_complexity']
valid_complexity = {'low', 'medium', 'high'}
all_ids = [t.get('id') for t in tasks]
errors = []

for t in tasks:
    tid = t.get('id', '(missing id)')
    for field in required:
        if field not in t:
            errors.append(f"{tid}: missing required field '{field}'")
    if isinstance(t.get('acceptance_criteria'), list) and \
       len(t.get('acceptance_criteria', [])) == 0:
        errors.append(f"{tid}: acceptance_criteria is empty")
    if isinstance(t.get('files_in_scope'), list) and \
       len(t.get('files_in_scope', [])) == 0:
        errors.append(f"{tid}: files_in_scope is empty")
    if t.get('estimated_complexity') not in valid_complexity:
        errors.append(f"{tid}: estimated_complexity must be low/medium/high, "
                      f"got '{t.get('estimated_complexity')}'")
    for dep in t.get('dependencies', []):
        if dep not in all_ids:
            errors.append(f"{tid}: dependency '{dep}' is not a valid task id")

if len(all_ids) != len(set(all_ids)):
    dupes = [i for i in set(all_ids) if all_ids.count(i) > 1]
    errors.append(f"Duplicate task ids: {', '.join(dupes)}")

for e in errors:
    print(e)
PYEOF
)

if [ -n "$SCHEMA_ERRORS" ]; then
  # Write debug info to a file so the workflow can always cat it
  {
    echo "=== SCHEMA VALIDATION ERRORS ==="
    echo "$SCHEMA_ERRORS"
    echo ""
    echo "=== RAW MANIFEST ==="
    cat "$PIPELINE_DIR/task-manifest.json" 2>/dev/null || echo "(manifest file not found)"
  } | tee "$PIPELINE_DIR/schema-errors.txt"
  halt "task-manifest.json failed schema validation" "AG-01" \
    "Fix these issues in the manifest before proceeding:
$SCHEMA_ERRORS"
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

# ── Acceptance criteria quality gate (LLM judge with regex fallback) ─────────
AC_ISSUES=$(python3 - "$PIPELINE_DIR/task-manifest.json" <<'PYEOF'
import json, os, re, sys, urllib.request

data = json.load(open(sys.argv[1]))
tasks = data if isinstance(data, list) else data.get('tasks', [])
tasks = [t for t in tasks if isinstance(t, dict)]
api_key = os.environ.get('ANTHROPIC_API_KEY', '')

# ── Regex pass: structural issues caught regardless of LLM ───────────────────
vague = re.compile(
    r'\b(works?(?: correctly| properly| as expected)?|is (?:done|complete|working|functional)|'
    r'functions?(?: properly| correctly)|it works|should work|is (?:implemented|added|created))\b',
    re.IGNORECASE
)
structural = []
criteria_for_llm = []
for t in tasks:
    tid = t.get('id', '?')
    for i, c in enumerate(t.get('acceptance_criteria', []), 1):
        c = c.strip()
        if len(c) < 10:
            structural.append(f"{tid} AC-{i}: too short to be testable — '{c}'")
        elif vague.search(c):
            structural.append(f"{tid} AC-{i}: vague language — '{c[:80]}'")
        else:
            criteria_for_llm.append(f"{tid} AC-{i}: {c}")

for s in structural:
    print(s)

# ── LLM judge: deeper testability check via Claude Haiku ─────────────────────
if not criteria_for_llm or not api_key:
    sys.exit(0)

criteria_text = "\n".join(criteria_for_llm)
prompt = (f"Review these software acceptance criteria for testability.\n"
          f"A criterion is testable if it describes a specific, verifiable outcome "
          f"with no ambiguity about how to confirm it passed or failed.\n\n"
          f"Criteria:\n{criteria_text}\n\n"
          f"Reply with ONLY a JSON array of non-testable criteria. "
          f"Each entry: {{\"id\": \"task-1 AC-2\", \"issue\": \"reason\"}}. "
          f"If all are testable, reply with: []")

try:
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps({
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 600,
            "messages": [{"role": "user", "content": prompt}]
        }).encode(),
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        }
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        text = json.load(resp)["content"][0]["text"].strip()
        # Extract JSON array even if surrounded by markdown fences
        m = re.search(r'\[.*\]', text, re.DOTALL)
        if m:
            for issue in json.loads(m.group(0)):
                print(f"{issue.get('id','?')}: {issue.get('issue','?')}")
except Exception:
    pass  # LLM unavailable — structural check above is sufficient
PYEOF
)

if [ -n "$AC_ISSUES" ]; then
  log "Acceptance criteria quality warnings:"
  while IFS= read -r issue; do log "  ! $issue"; done <<< "$AC_ISSUES"
fi

# ── AG-02 Reviewer ────────────────────────────────────────────────────────────
log ""
log "AG-02 Reviewer — preparing human review..."

REVIEW_PROMPT="You are running as AG-02 Reviewer for {PROJECT_NAME}.

Read pipeline/phase-$PHASE/task-manifest.json and pipeline/phase-$PHASE/manifest-summary.md.

Write reviewer-summary.md to pipeline/phase-$PHASE/ using the format defined in your system prompt.

Do not make any API calls. Just write the file and stop."

if [ -n "$AC_ISSUES" ]; then
  REVIEW_PROMPT="$REVIEW_PROMPT

The orchestrator detected acceptance criteria quality issues — surface these in 'Concerns or risks':
$AC_ISSUES"
fi

run_agent "ag-02-reviewer" "$REVIEW_PROMPT" "$PIPELINE_DIR/ag02-output.md"

SUMMARY_FILE="$PIPELINE_DIR/reviewer-summary.md"
if [ ! -f "$SUMMARY_FILE" ]; then
  halt "reviewer-summary.md not produced" "AG-02" "Reviewer did not write the summary file"
fi

if [[ "${ARCHITECT_ONLY:-}" == "1" ]]; then
  log "ARCHITECT_ONLY=1 — planning complete, exiting before human gate"
  log "Manifest and reviewer summary written to $PIPELINE_DIR/"
  exit 0
fi

# ── Human gate ────────────────────────────────────────────────────────────────

APPROVAL=$(wait_for_approval)

if [ "$APPROVAL" = "stop" ]; then
  halt "User stopped the pipeline" "human-gate" "User replied 'stop'"
fi

MAX_REVISIONS=3
REVISION=0

while [[ "$APPROVAL" == changes:* ]]; do
  REVISION=$(( REVISION + 1 ))
  if [ "$REVISION" -ge "$MAX_REVISIONS" ]; then
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

  REVIEW_PROMPT_REVISED="You are running as AG-02 Reviewer for {PROJECT_NAME}.

This is revision $REVISION of the manifest. The user requested: $CHANGES

Read pipeline/phase-$PHASE/task-manifest.json and pipeline/phase-$PHASE/manifest-summary.md.
Also read the previous pipeline/phase-$PHASE/reviewer-summary.md to identify what changed.

Write a revised reviewer-summary.md to pipeline/phase-$PHASE/ using the revision format from
your system prompt — put the 'What changed' section first, then the standard summary.

Do not make any API calls. Just write the file and stop."

  run_agent "ag-02-reviewer" "$REVIEW_PROMPT_REVISED" "$PIPELINE_DIR/ag02-output-revised-$REVISION.md"

  SUMMARY_FILE="$PIPELINE_DIR/reviewer-summary.md"
  if [ ! -f "$SUMMARY_FILE" ]; then
    halt "reviewer-summary.md not produced on revision" "AG-02" "Reviewer did not write the summary file"
  fi
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

fi # end of SKIP_ARCHITECT != 1 block

# ── Ticket splitter ───────────────────────────────────────────────────────────
# Runs after the manifest is finalised (regardless of SKIP_ARCHITECT).
# Splits any high-complexity or large-AC tasks into smaller sub-tasks.
# Skips tasks that are already complete. No-ops if all tasks are already small.
if [ ! -f "$PIPELINE_DIR/splitter-output.md" ]; then
  COMPLETED_TASKS=$(python3 -c "
import os, json, sys
pipeline_dir = sys.argv[1]
manifest_path = os.path.join(pipeline_dir, 'task-manifest.json')
data = json.load(open(manifest_path))
tasks = data if isinstance(data, list) else data.get('tasks', [])
complete = []
for t in tasks:
    tid = t.get('id', '')
    sec_report = os.path.join(pipeline_dir, tid, 'security-report.md')
    if os.path.isfile(sec_report):
        complete.append(tid)
print(', '.join(complete) if complete else 'none')
" "$PIPELINE_DIR" 2>/dev/null || echo "none")

  NEEDS_SPLIT=$(python3 -c "
import json, os, sys
pipeline_dir, manifest_path = sys.argv[1], sys.argv[2]
data = json.load(open(manifest_path))
tasks = data if isinstance(data, list) else data.get('tasks', [])
for t in tasks:
    tid = t.get('id', '')
    # Only consider incomplete tasks
    sec_report = os.path.join(pipeline_dir, tid, 'security-report.md')
    if os.path.isfile(sec_report):
        continue
    c = t.get('estimated_complexity', '')
    acs = len(t.get('acceptance_criteria', []))
    files = len(t.get('files_in_scope', []))
    if c == 'high' or acs > 4 or files > 3:
        print('yes')
        sys.exit(0)
print('no')
" "$PIPELINE_DIR" "$PIPELINE_DIR/task-manifest.json" 2>/dev/null || echo "no")

  if [ "$NEEDS_SPLIT" = "yes" ]; then
    log "Ticket splitter — breaking down large tasks..."

    # Write a filtered manifest containing ONLY incomplete tasks for the splitter.
    # Complete tasks are never shown to the agent — it cannot rename or modify them.
    # After the agent rewrites the filtered manifest, we merge the results back.
    INCOMPLETE_MANIFEST="$PIPELINE_DIR/splitter-input.json"
    COMPLETE_MANIFEST="$PIPELINE_DIR/splitter-complete-tasks.json"
    python3 -c "
import json, os, sys
pipeline_dir, manifest_path = sys.argv[1], sys.argv[2]
incomplete_out, complete_out = sys.argv[3], sys.argv[4]
data = json.load(open(manifest_path))
tasks = data if isinstance(data, list) else data.get('tasks', [])
incomplete, complete = [], []
for t in tasks:
    sec = os.path.join(pipeline_dir, t.get('id',''), 'security-report.md')
    (complete if os.path.isfile(sec) else incomplete).append(t)
with open(incomplete_out, 'w') as f:
    json.dump(incomplete, f, indent=2)
with open(complete_out, 'w') as f:
    json.dump(complete, f, indent=2)
" "$PIPELINE_DIR" "$PIPELINE_DIR/task-manifest.json" \
      "$INCOMPLETE_MANIFEST" "$COMPLETE_MANIFEST"

    SPLIT_PROMPT="You are AG-09 Ticket Splitter for {PROJECT_NAME}.

Your input manifest (incomplete tasks only): $INCOMPLETE_MANIFEST
Pipeline directory: $PIPELINE_DIR

PRD summary:
$(head -c 3000 "$PIPELINE_DIR/ag01-output.md" 2>/dev/null || echo "(no architect output)")

Read $INCOMPLETE_MANIFEST. Split any tasks that exceed the thresholds in your system
prompt. Rewrite $INCOMPLETE_MANIFEST in place with the split tasks.
Write splitter-output.md to $PIPELINE_DIR/splitter-output.md."

    run_agent "ag-09-splitter" "$SPLIT_PROMPT" "$PIPELINE_DIR/splitter-agent-log.md" 300

    # Merge complete tasks back at the front of the manifest, split tasks at the end.
    python3 -c "
import json, sys
complete_path, incomplete_path, manifest_path = sys.argv[1], sys.argv[2], sys.argv[3]
complete = json.load(open(complete_path))
incomplete = json.load(open(incomplete_path))
with open(manifest_path, 'w') as f:
    json.dump(complete + incomplete, f, indent=2)
" "$COMPLETE_MANIFEST" "$INCOMPLETE_MANIFEST" "$PIPELINE_DIR/task-manifest.json"

    log "Ticket splitter complete"
  else
    log "Ticket splitter — all tasks already small, skipping"
    echo "All tasks within size thresholds — no splitting needed." > "$PIPELINE_DIR/splitter-output.md"
  fi
else
  log "Ticket splitter already ran — skipping"
fi

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

  # Parse manifest once and extract all task fields in a single Python invocation.
  # Avoids 4 separate subprocess + file parse calls per task (P-01 fix).
  eval "$(python3 - "$PIPELINE_DIR/task-manifest.json" "$TASK_ID" <<'PYEOF'
import json, sys, shlex
data = json.load(open(sys.argv[1]))
tasks = data if isinstance(data, list) else data.get('tasks', data.get('task_order', []))
task = next(t for t in tasks if isinstance(t, dict) and t['id'] == sys.argv[2])
print(f"TASK_JSON={shlex.quote(json.dumps(task, indent=2))}")
print(f"TASK_TITLE={shlex.quote(task.get('title', task['id']))}")
print(f"FILES_IN_SCOPE_JSON={shlex.quote(json.dumps(task.get('files_in_scope', [])))}")
print(f"SECURITY_SENSITIVE={'true' if task.get('security_sensitive') else 'false'}")
files = task.get('files_in_scope', [])
has_mig = any('migration' in f.lower() or f.startswith('migrations/') for f in files)
print(f"HAS_MIGRATION={'true' if has_mig else 'false'}")
ac = task.get('acceptance_criteria', [])
print(f"AC_COUNT={len(ac)}")
PYEOF
)"

  log ""
  log "========================================"
  log "Task: $TASK_ID — $TASK_TITLE"
  log "========================================"

  # Wrap task spec to prevent manifest content being interpreted as agent instructions
  TASK_SPEC="<task-spec>
$TASK_JSON
</task-spec>"

  # Build context snapshot for this task's agents (empty on first task)
  CONTEXT_BLOCK=$(build_context_block)

  # HAS_MIGRATION, SECURITY_SENSITIVE, TASK_JSON, TASK_TITLE, FILES_IN_SCOPE_JSON,
  # and AC_COUNT are all set by the single-parse eval block above.

  # Pre-compute package filter and expanded file list for the DEV_PROMPT validation block.
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

  # ── RED phase: Tester writes failing tests ────────────────────────────────
  TESTS_WRITTEN_FILE="$TASK_DIR/tests-written.txt"

  if [ ! -f "$TESTS_WRITTEN_FILE" ]; then
    RED_START=$(date +%s)
    log "RED phase — Tester writing failing tests..."

    RED_PROMPT="You are AG-03 Tester for {PROJECT_NAME}.

This is the RED phase of TDD. The Developer has not yet written implementation code.

Write the test suite for task $TASK_ID that defines the expected behaviour.
Task spec:
$TASK_SPEC
${CONTEXT_BLOCK:+
$CONTEXT_BLOCK}

Write test files to the __tests__/ directories as normal.
Tests will fail right now because there is no implementation — that is correct and expected.

Time budget: complete the RED phase in under 5 minutes. Read only the files
directly listed in files_in_scope and their immediate imports. Do not explore
the entire codebase — the task spec and build context contain everything needed.

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
    if (cd "$REPO_ROOT" && pnpm test > "$TASK_DIR/test-red-output.txt" 2>&1); then
      log "WARNING: Tests pass before implementation — verify tests have meaningful assertions"
    else
      log "RED confirmed — tests fail as expected"
    fi

    # Capture baseline failing test IDs so the green gate can distinguish
    # pre-existing failures (infrastructure, unrelated packages) from new ones
    # introduced or missed by the developer.
    python3 - "$TASK_DIR/test-red-output.txt" "$TASK_DIR/baseline-failures.txt" <<'PYEOF'
import re, sys

red_output_path = sys.argv[1]
baseline_path   = sys.argv[2]

try:
    content = open(red_output_path).read()
except FileNotFoundError:
    open(baseline_path, 'w').close()
    sys.exit(0)

# Extract Vitest FAIL lines: "FAIL  src/__tests__/foo.test.ts > ..."
# and individual failing test names: " × test name N ms"
fail_files = set(re.findall(r'^\s*FAIL\s+(\S+)', content, re.MULTILINE))
fail_tests = set(re.findall(r'^\s*×\s+(.+?)\s+\d+ms', content, re.MULTILINE))

baseline = sorted(fail_files | fail_tests)
with open(baseline_path, 'w') as fh:
    fh.write('\n'.join(baseline) + '\n' if baseline else '')

print(f"Baseline: {len(baseline)} pre-existing failure(s) recorded.")
PYEOF

    # Trajectory check: verify test files have real assertions (AC_COUNT set above)
    check_tester_trajectory "$TASK_DIR" "$TESTS_WRITTEN_FILE" "$AC_COUNT"
    record_task_metrics "$TASK_ID" "$TASK_TITLE" "red" $(( $(date +%s) - RED_START )) 1 "pass"
  else
    log "RED phase already complete — skipping"
  fi

  # ── GREEN phase: Developer implements until hard gate passes ───────────────
  GREEN_VERIFIED_FILE="$TASK_DIR/green-verified.txt"

  if [ ! -f "$GREEN_VERIFIED_FILE" ]; then
    GREEN_START=$(date +%s)
    DEV_ATTEMPTS=0
    GREEN_PASSED=false
    GATE_FAILURES=""

    while [ "$GREEN_PASSED" = false ] && [ "$DEV_ATTEMPTS" -lt 5 ]; do
      DEV_ATTEMPTS=$(( DEV_ATTEMPTS + 1 ))
      log "GREEN phase — Developer attempt $DEV_ATTEMPTS/5..."

      DEV_PROMPT="You are AG-04 Developer for {PROJECT_NAME}.

Implement this task to make the failing tests pass:
$TASK_SPEC
${CONTEXT_BLOCK:+
$CONTEXT_BLOCK}

<architecture>
$ARCH_DOC
</architecture>

The Tester has already written failing tests in the __tests__/ directories.
Your job is to write implementation code that makes every test pass.
Do not modify the test files.

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
You are not done until you have run all four and seen zero errors and all tests passing.
Copy the terminal output of each command into self-assessment.md as proof.

Write self-assessment.md to pipeline/phase-$PHASE/$TASK_ID/
Follow your system prompt exactly. Apply all security rules.
Use process.env.DATABASE_URL for any database connections — do not read .env directly."

      if [ -n "$GATE_FAILURES" ]; then
        # Capture a diff of in-scope files from the previous attempt so the
        # developer can see exactly what it changed without re-reading everything.
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

      run_agent "ag-04-developer" "$DEV_PROMPT" "$TASK_DIR/dev-output-$DEV_ATTEMPTS.md" 1200
      dev_rc=$?

      if [ $dev_rc -eq 124 ]; then
        log "Developer attempt $DEV_ATTEMPTS timed out after 20 minutes — counting as gate failure"
        GATE_FAILURES="=== Developer attempt timed out ===
The agent did not complete within 20 minutes. This usually means the task is too large
or the agent spent too long reading before writing. On your next attempt:
- Write implementation code immediately — do not re-read files you already know
- Focus only on files_in_scope; ignore everything else
- Implement the minimum needed to make the failing tests pass"
        continue
      fi

      if [ -f "$TASK_DIR/BLOCKED.md" ]; then
        halt "Developer blocked on $TASK_ID" "AG-04" "$(cat "$TASK_DIR/BLOCKED.md")"
      fi

      # Silently remove common temp/debug patterns before scope check so they
      # don't pollute retry feedback. These are never legitimate scope files.
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
        log "Scope violation — reverting out-of-scope changes..."
        revert_scope_violations <<< "$SCOPE_VIOLATIONS"
        SCOPE_GATE="=== files_in_scope violation (changes reverted) ===
The following files were modified or created outside files_in_scope and have been automatically reverted.
Do NOT re-create or modify them — only write to files listed in files_in_scope:
$SCOPE_VIOLATIONS"
      fi

      # Auto-fix biome formatting on in-scope files before the gate so trivial
      # whitespace/comma/quote issues don't consume a developer attempt.
      # Semantic lint errors (noExplicitAny, complexity, etc.) are NOT auto-fixed.
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
      IMPL_FAILURES=$(verify_implementation "$FILES_IN_SCOPE_JSON" "$TASK_DIR/baseline-failures.txt") || true
      # Only include scope violations in failures if tsc/lint/tests also failed.
      # Scope violations alone are auto-recoverable via revert and shouldn't halt.
      if [ -n "$IMPL_FAILURES" ]; then
        GATE_FAILURES="${SCOPE_GATE:+$SCOPE_GATE
}${IMPL_FAILURES}"
      else
        GATE_FAILURES=""
      fi

      # Guard: if all changes were reverted (scope violations) but no in-scope
      # file was actually written, the developer produced no real implementation.
      # Force a retry so the agent writes code in the correct files.
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
You MUST write implementation code to the files listed in files_in_scope.
Do not create new files — modify only the files already listed there."
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

$(cat "$TASK_DIR/test-red-output.txt" 2>/dev/null || true)
REPORT
        record_task_metrics "$TASK_ID" "$TASK_TITLE" "green" $(( $(date +%s) - GREEN_START )) "$DEV_ATTEMPTS" "pass"
        log "Code health (pre-refactor baseline):"
        run_code_health_checks "$TASK_ID" "$TASK_DIR" "$FILES_IN_SCOPE_JSON" "pre-refactor" "1"
        log "GREEN phase: PASS"
      else
        log "Hard gate: FAIL (attempt $DEV_ATTEMPTS/5)"
        printf "%s" "$GATE_FAILURES" > "$TASK_DIR/gate-failures-$DEV_ATTEMPTS.txt"
        if [ "$DEV_ATTEMPTS" -eq 5 ]; then
          halt "Developer could not pass hard gate after 5 attempts" "AG-04" \
            "Task: $TASK_ID — see $TASK_DIR/gate-failures-5.txt"
        fi
      fi
    done
  else
    log "GREEN phase already complete — skipping"

    if [ ! -f "$TASK_DIR/test-report.md" ]; then
      cat > "$TASK_DIR/test-report.md" <<REPORT
Title: Test Report — $TASK_ID — PASS

Verified by orchestrator hard gate (restored on resume).

- tsc --noEmit: PASS
- eslint (files_in_scope): PASS
- pnpm test: PASS
REPORT
    fi
  fi

  # ── MIGRATION phase (conditional) ────────────────────────────────────────
  MIGRATION_VERIFIED_FILE="$TASK_DIR/migration-verified.txt"

  if [ "$HAS_MIGRATION" = "true" ]; then
    if [ ! -f "$MIGRATION_VERIFIED_FILE" ]; then
      MIGRATION_START=$(date +%s)
      log "MIGRATION phase — AG-05 Migration..."

      MIGRATION_PROMPT="You are AG-05 Migration for {PROJECT_NAME}.

The Developer has written migration files for task $TASK_ID.
Task spec:
$TASK_SPEC

Validate every migration file in files_in_scope.
Run the migration and its rollback against the test database.
Write migration-report.md to pipeline/phase-$PHASE/$TASK_ID/
Follow your system prompt exactly."

      run_agent "ag-05-migration" "$MIGRATION_PROMPT" "$TASK_DIR/migration-output.md"

      if [ ! -f "$TASK_DIR/migration-report.md" ]; then
        halt "Migration agent did not write migration-report.md" "AG-05" \
          "Task: $TASK_ID — migration-report.md not found"
      fi

      if ! report_passes "$TASK_DIR/migration-report.md"; then
        halt "Migration failed for task $TASK_ID" "AG-05" \
          "$(cat "$TASK_DIR/migration-report.md")"
      fi

      echo "migration-verified" > "$MIGRATION_VERIFIED_FILE"
      record_task_metrics "$TASK_ID" "$TASK_TITLE" "migration" $(( $(date +%s) - MIGRATION_START )) 1 "pass"
      log "MIGRATION phase: PASS"
    else
      log "MIGRATION phase already complete — skipping"
    fi
  fi

  # ── REFACTOR phase: clean up without changing behaviour ───────────────────
  REFACTOR_VERIFIED_FILE="$TASK_DIR/refactor-verified.txt"

  if [ ! -f "$REFACTOR_VERIFIED_FILE" ]; then
    REFACTOR_START=$(date +%s)
    log "REFACTOR phase — AG-06 Refactor..."

    # Pre-check: derive health metrics from the pre-refactor baseline and skip
    # the agent entirely if complexity and duplication are within thresholds.
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
      # Build complexity violation list from the pre-refactor health report
      COMPLEXITY_BLOCK=$(python3 - "$TASK_DIR/health-report-pre.json" <<'PYEOF'
import json, sys, os
try:
    report = json.load(open(sys.argv[1]))
    fns = report.get('complex_functions', [])
    if not fns:
        sys.exit(0)
    print("The following functions exceeded the cognitive complexity threshold (max: 10).")
    print("These are your primary refactor targets — reduce their complexity score:")
    print("")
    for fn in fns:
        score = fn.get('score', '?')
        print(f"  {fn['file']}:{fn['line']} — complexity score {score}")
except Exception:
    pass
PYEOF
)

      REFACTOR_PROMPT="You are AG-06 Refactor for {PROJECT_NAME}.

The Developer has implemented task $TASK_ID and all tests pass.
Your job is to improve the code without changing its behaviour.

Task spec:
$TASK_SPEC
${CONTEXT_BLOCK:+
$CONTEXT_BLOCK}
${COMPLEXITY_BLOCK:+
## Complexity violations to fix

$COMPLEXITY_BLOCK
}
Read every file in files_in_scope and the corresponding test files.
Make conservative, targeted improvements only.
Do NOT modify test files. Do NOT change public interfaces.

## Required: run validation before writing the report
Run these in order and fix every error:
\`\`\`bash
pnpm exec tsc --noEmit
pnpm exec biome check --write ${FILES_IN_SCOPE_JSON_EXPANDED:-packages/}
pnpm exec biome check ${FILES_IN_SCOPE_JSON_EXPANDED:-packages/}
pnpm${AFFECTED_PKGS:+ $AFFECTED_PKGS} test
\`\`\`
Do not write refactor-report.md until all four pass.

Write refactor-report.md to pipeline/phase-$PHASE/$TASK_ID/
Follow your system prompt exactly."

      run_agent "ag-06-refactor" "$REFACTOR_PROMPT" "$TASK_DIR/refactor-output.md"

      if [ ! -f "$TASK_DIR/refactor-report.md" ]; then
        halt "Refactor agent did not write refactor-report.md" "AG-06" \
          "Task: $TASK_ID — refactor-report.md not found"
      fi
    fi

    # Re-run hard gate regardless of whether the agent ran
    log "Re-running hard gate after refactor..."
    REFACTOR_FAILURES=$(verify_implementation "$FILES_IN_SCOPE_JSON") || true
    if [ -n "$REFACTOR_FAILURES" ]; then
      halt "Refactor broke tsc or tests on task $TASK_ID" "AG-06" \
        "Task: $TASK_ID
$REFACTOR_FAILURES"
    fi

    echo "refactor-verified" > "$REFACTOR_VERIFIED_FILE"
    record_task_metrics "$TASK_ID" "$TASK_TITLE" "refactor" $(( $(date +%s) - REFACTOR_START )) 1 "pass"

    # Post-refactor health check + delta vs baseline
    log "Code health (post-refactor):"
    run_code_health_checks "$TASK_ID" "$TASK_DIR" "$FILES_IN_SCOPE_JSON" "" "1"

    if [ -f "$TASK_DIR/health-report-pre.json" ] && [ -f "$TASK_DIR/health-report.json" ]; then
      python3 - "$TASK_DIR/health-report-pre.json" "$TASK_DIR/health-report.json" \
        "$PIPELINE_DIR/metrics.json" "$TASK_ID" <<'PYEOF'
import json, sys
pre  = json.load(open(sys.argv[1]))
post = json.load(open(sys.argv[2]))
metrics_file, task_id = sys.argv[3], sys.argv[4]

deltas = []
if pre.get('coverage_pct') is not None and post.get('coverage_pct') is not None:
    d = round(post['coverage_pct'] - pre['coverage_pct'], 1)
    if d != 0:
        deltas.append(f"coverage {'↑' if d > 0 else '↓'}{abs(d)}%")
if pre.get('duplication_pct') is not None and post.get('duplication_pct') is not None:
    d = round(post['duplication_pct'] - pre['duplication_pct'], 1)
    if d != 0:
        deltas.append(f"dup {'↓' if d < 0 else '↑'}{abs(d)}%")
pre_cx  = len(pre.get('complex_functions', []))
post_cx = len(post.get('complex_functions', []))
if pre_cx != post_cx:
    deltas.append(f"complex fns {pre_cx}→{post_cx}")

summary = ' · '.join(deltas) if deltas else 'no measurable change'
print(f'  Refactor delta: {summary}')

# Store delta in metrics for health-summary.md
try:
    import os as _os
    if _os.path.exists(metrics_file):
        data = json.load(open(metrics_file))
        if task_id in data.get('tasks', {}):
            data['tasks'][task_id]['health_delta'] = summary
            with open(metrics_file, 'w') as fp:
                json.dump(data, fp, indent=2)
except Exception:
    pass
PYEOF
    fi

    log "REFACTOR phase: PASS"
  else
    log "REFACTOR phase already complete — skipping"
  fi

  # ── MUTATION TESTING (security-sensitive tasks only) ─────────────────────
  if [ "$SECURITY_SENSITIVE" = "true" ]; then
    if [ ! -f "$TASK_DIR/mutation-report.md" ]; then
      MUTATION_START=$(date +%s)
      log "MUTATION TESTING — task is security_sensitive..."
      run_mutation_tests "$TASK_ID" "$TASK_DIR" "$FILES_IN_SCOPE_JSON"
      record_task_metrics "$TASK_ID" "$TASK_TITLE" "mutation" \
        $(( $(date +%s) - MUTATION_START )) 1 "pass"
      log "Mutation testing complete — see mutation-report.md"
    else
      log "MUTATION TESTING already complete — skipping"
    fi
  fi

  # ── Security phase ────────────────────────────────────────────────────────
  # Persist attempt count to a file so the 3-attempt limit survives pipeline
  # resumes — without this, each resume gives a fresh 3 attempts (L-02 fix).
  SEC_ATTEMPTS_FILE="$TASK_DIR/security-attempts.txt"
  SECURITY_PASSED=false
  SECURITY_ATTEMPTS=$(cat "$SEC_ATTEMPTS_FILE" 2>/dev/null || echo "0")
  SECURITY_START=$(date +%s)

  while [ "$SECURITY_PASSED" = false ] && [ "$SECURITY_ATTEMPTS" -lt 3 ]; do
    SECURITY_ATTEMPTS=$(( SECURITY_ATTEMPTS + 1 ))
    echo "$SECURITY_ATTEMPTS" > "$SEC_ATTEMPTS_FILE"
    log "Security attempt $SECURITY_ATTEMPTS/3..."

    SEC_PROMPT="You are AG-07 Security Agent for {PROJECT_NAME}.

Review the code written for task $TASK_ID.
Task spec:
$TASK_SPEC
${CONTEXT_BLOCK:+
$CONTEXT_BLOCK}

Files to review (read every one before writing findings):
$(python3 -c "import json,sys; print('\n'.join('  - ' + f for f in json.loads(sys.argv[1])))" "$FILES_IN_SCOPE_JSON")

Apply every rule in .opencode/agents/security-rules.md to every file listed above.
Write security-report.md to pipeline/phase-$PHASE/$TASK_ID/
Return PASS or FAIL with specific findings."

    run_agent "ag-07-security" "$SEC_PROMPT" "$TASK_DIR/sec-output-$SECURITY_ATTEMPTS.md"

    if [ -f "$SEC_REPORT" ] && report_passes "$SEC_REPORT"; then
      SECURITY_PASSED=true
      record_task_metrics "$TASK_ID" "$TASK_TITLE" "security" $(( $(date +%s) - SECURITY_START )) "$SECURITY_ATTEMPTS" "pass"
      record_security_findings "$TASK_ID" "$TASK_DIR"
      check_security_trajectory "$TASK_DIR"
      log "Security: PASS"
    else
      log "Security: FAIL (attempt $SECURITY_ATTEMPTS/3)"
      if [ "$SECURITY_ATTEMPTS" -eq 3 ]; then
        halt "Security could not be resolved after 3 attempts" "AG-07" \
          "Task: $TASK_ID — see $SEC_REPORT"
      fi

      log "Security fix needed — re-running Developer..."

      SEC_FIX_PROMPT="You are AG-04 Developer for {PROJECT_NAME}.

The Security Agent has rejected task $TASK_ID. Fix every finding below, then run all
validation commands before marking done.

<security-findings>
$(cat "$SEC_REPORT")
</security-findings>

Task spec for context:
$TASK_SPEC
${CONTEXT_BLOCK:+
$CONTEXT_BLOCK}

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
Fix everything before updating self-assessment.md.
Use process.env.DATABASE_URL for any database connections."

      run_agent "ag-04-developer" "$SEC_FIX_PROMPT" \
        "$TASK_DIR/dev-secfix-$SECURITY_ATTEMPTS.md" 900

      SCOPE_VIOLATIONS=$(check_scope_compliance "$FILES_IN_SCOPE_JSON") || true
      if [ -n "$SCOPE_VIOLATIONS" ]; then
        log "Scope violation after security fix — reverting..."
        revert_scope_violations <<< "$SCOPE_VIOLATIONS"
      fi

      log "Re-running hard gate after security fix..."
      POST_SEC_FAILURES=$(verify_implementation "$FILES_IN_SCOPE_JSON") || true
      # Only include scope violations in failures if tsc/lint/tests also failed.
      # Scope violations alone are auto-recoverable via revert and shouldn't halt.
      if [ -n "$POST_SEC_FAILURES" ] && [ -n "$SCOPE_VIOLATIONS" ]; then
        POST_SEC_FAILURES="=== files_in_scope violation after security fix ===
$SCOPE_VIOLATIONS

${POST_SEC_FAILURES}"
      fi
      if [ -n "$POST_SEC_FAILURES" ]; then
        rm -f "$GREEN_VERIFIED_FILE" "$REFACTOR_VERIFIED_FILE"
        halt "Security fix broke tsc or tests on task $TASK_ID" "AG-07" \
          "Task: $TASK_ID
$POST_SEC_FAILURES"
      fi
      log "Post-security hard gate: PASS"
    fi
  done

  # ── Context accumulation ──────────────────────────────────────────────────
  log "Updating build context..."
  {
    printf "## %s — %s\n\n" "$TASK_ID" "$TASK_TITLE"
    printf "**Files:** %s\n\n" "$(python3 -c "
import json, sys
print(', '.join(json.loads(sys.argv[1])))
" "$FILES_IN_SCOPE_JSON")"
    python3 - "$TASK_DIR/self-assessment.md" "$TASK_ID" <<'PYEOF'
import re, sys
task_id = sys.argv[2] if len(sys.argv) > 2 else '?'
try:
    content = open(sys.argv[1]).read()
    m = re.search(r'## Notes for future agents\n(.*?)(\n## |\Z)', content, re.DOTALL)
    if m:
        print(m.group(1).strip())
    else:
        print(f"⚠ {task_id}: self-assessment.md is missing the '## Notes for future agents' section — future tasks will have no context from this task.")
except Exception:
    print(f"⚠ {task_id}: self-assessment.md not found or unreadable.")
PYEOF
    printf "\n---\n"
  } >> "$PIPELINE_DIR/context.md"

  # ── Git commit ────────────────────────────────────────────────────────────
  log "Committing task $TASK_ID..."

  while IFS= read -r f; do
    if [ -e "$REPO_ROOT/$f" ] && ! git -C "$REPO_ROOT" check-ignore -q "$f" 2>/dev/null; then
      git -C "$REPO_ROOT" add "$f"
    fi
  done < <(python3 -c "
import json, sys
for f in json.loads(sys.argv[1]):
    print(f)
" "$FILES_IN_SCOPE_JSON")

  while IFS= read -r f; do
    base=$(basename "${f%.ts}")
    while IFS= read -r tf; do
      rel=${tf#"$REPO_ROOT/"}
      if ! git -C "$REPO_ROOT" check-ignore -q "$rel" 2>/dev/null; then
        git -C "$REPO_ROOT" add "$tf"
      fi
    done < <(find "$REPO_ROOT" -path "*/__tests__/${base}*" 2>/dev/null)
  done < <(python3 -c "
import json, sys
for f in json.loads(sys.argv[1]):
    print(f)
" "$FILES_IN_SCOPE_JSON")

  if ! git -C "$REPO_ROOT" diff --cached --quiet; then
    git -C "$REPO_ROOT" commit -m "feat($TASK_ID): $TASK_TITLE"
    log "Committed: feat($TASK_ID): $TASK_TITLE"
  else
    log "Nothing new to commit for $TASK_ID"
  fi

  log "Task $TASK_ID: COMPLETE"
done

# ── Health summary report ─────────────────────────────────────────────────────
python3 - "$PIPELINE_DIR/metrics.json" "$PIPELINE_DIR/health-summary.md" \
  "$PHASE" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" <<'PYEOF'
import json, os, sys

metrics_file, output_file, phase, timestamp = \
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

if not os.path.exists(metrics_file):
    sys.exit(0)

data = json.load(open(metrics_file))
tasks = data.get('tasks', {})
if not tasks:
    sys.exit(0)

def fmt(v, suffix='%'):
    return f"{v}{suffix}" if v is not None else '—'

rows = []
for tid, t in tasks.items():
    h = t.get('health', {})
    rows.append({
        'id':    tid,
        'title': t.get('title', tid)[:35],
        'cov':   fmt(h.get('coverage_pct')),
        'dup':   fmt(h.get('duplication_pct')),
        'cx':    str(h.get('complex_fn_count', 0)) if 'complex_fn_count' in h else '—',
        'delta': t.get('health_delta', '—'),
    })

covs = [t.get('health', {}).get('coverage_pct') for t in tasks.values()
        if t.get('health', {}).get('coverage_pct') is not None]
dups = [t.get('health', {}).get('duplication_pct') for t in tasks.values()
        if t.get('health', {}).get('duplication_pct') is not None]
total_cx = sum(t.get('health', {}).get('complex_fn_count', 0) for t in tasks.values())
avg_cov = fmt(round(sum(covs) / len(covs), 1)) if covs else '—'
avg_dup = fmt(round(sum(dups) / len(dups), 1)) if dups else '—'

lines = [
    f"# Phase {phase} — Code Health Summary",
    f"",
    f"*Generated {timestamp}*",
    f"",
    f"| Task | Coverage | Duplication | Complex Fns | Refactor delta |",
    f"|---|---|---|---|---|",
]
for r in rows:
    lines.append(
        f"| {r['id']} — {r['title']} | {r['cov']} | {r['dup']} | {r['cx']} | {r['delta']} |"
    )
lines += [
    f"| **Phase average** | **{avg_cov}** | **{avg_dup}** | **{total_cx} total** | |",
    "",
]

open(output_file, 'w').write('\n'.join(lines))
PYEOF

if [ -f "$PIPELINE_DIR/health-summary.md" ]; then
  log "Health summary written to pipeline/phase-$PHASE/health-summary.md"
fi

# ── AG-08 Validator ───────────────────────────────────────────────────────────
log ""
log "========================================"
log "AG-08 Validator — end-to-end phase check"
log "========================================"

VALIDATION_PASSED=false
VALIDATION_ATTEMPTS=0

# Maximum fix+re-validate cycles after an initial FAIL.
# Cycle: AG-08 FAIL → AG-04 fix → hard gate → AG-08 retry.
MAX_VALIDATION_CYCLES=2

while [ "$VALIDATION_PASSED" = false ] && [ "$VALIDATION_ATTEMPTS" -lt $(( MAX_VALIDATION_CYCLES + 1 )) ]; do
  VALIDATION_ATTEMPTS=$(( VALIDATION_ATTEMPTS + 1 ))
  log "Validation attempt $VALIDATION_ATTEMPTS/$(( MAX_VALIDATION_CYCLES + 1 ))..."

  VAL_PROMPT="You are AG-08 Validator for {PROJECT_NAME}.

Validate the full Phase $PHASE implementation against the PRD exit criteria in docs/prd.md.

1. Check every exit criterion for Phase $PHASE explicitly
2. Run the smoke tests for this phase
3. Read every task's security-report.md and test-report.md in pipeline/phase-$PHASE/
4. Write validation-report.md to pipeline/phase-$PHASE/

On PASS:
- Run: git tag phase-$PHASE-complete
- Write the validation-report.md with PASS, changelog, and full sign-off

On FAIL:
- List exactly which exit criteria failed and why, with the task ID and file responsible
- Do not create a git tag

Follow your system prompt exactly."

  run_agent "ag-08-validator" "$VAL_PROMPT" "$PIPELINE_DIR/val-output-$VALIDATION_ATTEMPTS.md"

  if [ -f "$PIPELINE_DIR/validation-report.md" ] && report_passes "$PIPELINE_DIR/validation-report.md"; then
    VALIDATION_PASSED=true

    printf "\a"  # terminal bell
    log ""
    log "========================================"
    log "Phase $PHASE: COMPLETE"
    log "Git tag: phase-$PHASE-complete created"
    log "========================================"
  else
    log "Validation: FAIL (attempt $VALIDATION_ATTEMPTS/$(( MAX_VALIDATION_CYCLES + 1 )))"

    if [ "$VALIDATION_ATTEMPTS" -ge $(( MAX_VALIDATION_CYCLES + 1 )) ]; then
      halt "Phase validation failed after $VALIDATION_ATTEMPTS attempt(s)" "AG-08" \
        "See pipeline/phase-$PHASE/validation-report.md"
    fi

    # ── Validation fix cycle ─────────────────────────────────────────────────
    # The validator identified specific exit-criteria failures. Re-run the
    # developer on every affected task so the code is actually fixed before
    # we ask the validator to look again.
    log "Validation fix cycle $VALIDATION_ATTEMPTS — running Developer against validator findings..."

    VAL_FIX_PROMPT="You are AG-04 Developer for {PROJECT_NAME}.

The Phase $PHASE Validator has rejected the implementation. Fix every issue listed below.

<validation-findings>
$(cat "$PIPELINE_DIR/validation-report.md")
</validation-findings>

Phase context (all tasks):
$(build_context_block)

Rules:
- Only modify files that belong to the failing exit criteria.
- Do not modify test files.
- After fixing, update self-assessment.md in the relevant task directory with a summary
  of what you changed and why.
- Use process.env.DATABASE_URL for any database connections.

Apply all security rules. Do not introduce new issues."

    run_agent "ag-04-developer" "$VAL_FIX_PROMPT" \
      "$PIPELINE_DIR/val-fix-dev-$VALIDATION_ATTEMPTS.md" 900

    # Re-run the full hard gate across all tasks so we know nothing regressed
    log "Re-running full hard gate after validation fix..."
    PHASE_GATE_FAILURES=""
    while IFS= read -r VTASK_ID; do
      [[ -z "$VTASK_ID" ]] && continue
      VTASK_FILES_JSON=$(python3 -c "
import json
data = json.load(open('$PIPELINE_DIR/task-manifest.json'))
tasks = data if isinstance(data, list) else data.get('tasks', [])
task = next((t for t in tasks if isinstance(t, dict) and t['id'] == '$VTASK_ID'), None)
print(json.dumps(task.get('files_in_scope', []) if task else []))
")
      VTASK_FAILURES=$(verify_implementation "$VTASK_FILES_JSON") || true
      if [ -n "$VTASK_FAILURES" ]; then
        PHASE_GATE_FAILURES+="=== $VTASK_ID ===
$VTASK_FAILURES

"
      fi
    done <<< "$TASKS"

    if [ -n "$PHASE_GATE_FAILURES" ]; then
      halt "Validation fix broke the hard gate" "AG-04" \
        "Fix introduced regressions — see below:
$PHASE_GATE_FAILURES"
    fi
    log "Post-validation-fix hard gate: PASS — retrying validator..."

    # Scope-compliance check after the fix — build the union of all tasks' files_in_scope
    # so that any file touched by the developer fix is permitted if it belongs to any task.
    ALL_TASKS_FILES_JSON=$(python3 -c "
import json
data = json.load(open('$PIPELINE_DIR/task-manifest.json'))
tasks = data if isinstance(data, list) else data.get('tasks', data.get('task_order', []))
files = []
for t in tasks:
    if isinstance(t, dict):
        files.extend(t.get('files_in_scope', []))
print(json.dumps(list(dict.fromkeys(files))))
" 2>/dev/null || echo "[]")
    SCOPE_VIOLATIONS=$(check_scope_compliance "$ALL_TASKS_FILES_JSON") || true
    if [ -n "$SCOPE_VIOLATIONS" ]; then
      log "Reverting out-of-scope changes from validation fix..."
      revert_scope_violations <<< "$SCOPE_VIOLATIONS"
    fi
  fi
done

# ── Phase metrics summary ─────────────────────────────────────────────────────
python3 - "$PIPELINE_DIR/metrics.json" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" <<'PYEOF'
import json, os, sys
f, completed_at = sys.argv[1], sys.argv[2]
if not os.path.exists(f):
    sys.exit(0)
from collections import Counter
data = json.load(open(f))
total = sum(t.get('total_duration_s', 0) for t in data['tasks'].values())
high_retry = [
    tid for tid, t in data['tasks'].items()
    if any(v.get('attempts', 1) > 1 for v in t.values() if isinstance(v, dict))
]
all_findings = []
for t in data['tasks'].values():
    all_findings.extend(t.get('security_findings', []))
top_findings = [f"{r} ({c}x)" for r, c in Counter(all_findings).most_common(5)] if all_findings else []

# pass@1 rate: tasks where every phase passed on the first attempt
tasks_pass_at_1 = sum(
    1 for t in data['tasks'].values()
    if all(v.get('attempts', 1) == 1 for v in t.values() if isinstance(v, dict) and 'attempts' in v)
)
n = len(data['tasks'])
pass_at_1_rate = round(100 * tasks_pass_at_1 / n) if n else 0

# Health summary: aggregate across tasks, skip None values
health_vals = [t.get('health', {}) for t in data['tasks'].values()]
def avg(vals):
    v = [x for x in vals if x is not None]
    return round(sum(v) / len(v), 1) if v else None

health_summary = {
    'avg_coverage_pct':    avg([h.get('coverage_pct')    for h in health_vals]),
    'avg_duplication_pct': avg([h.get('duplication_pct') for h in health_vals]),
    'total_complex_fns':   sum(h.get('complex_fn_count', 0) for h in health_vals),
}

data['summary'] = {
    'completed_at': completed_at,
    'total_duration_s': total,
    'tasks_completed': n,
    'pass_at_1_rate': pass_at_1_rate,
    'high_retry_tasks': high_retry,
    'top_security_findings': top_findings,
    'health': health_summary,
}
with open(f, 'w') as fp:
    json.dump(data, fp, indent=2)
PYEOF

if [ -s "$PIPELINE_DIR/metrics.json" ]; then
  log "Metrics summary:"
  python3 -c "
import json
data = json.load(open('$PIPELINE_DIR/metrics.json'))
s = data.get('summary', {})
print(f\"  Total time : {s.get('total_duration_s', 0)}s\")
print(f\"  Tasks done : {s.get('tasks_completed', 0)}\")
print(f\"  Pass@1 rate: {s.get('pass_at_1_rate', 0)}%  ← % of tasks needing no retries\")
high = s.get('high_retry_tasks', [])
if high:
    print(f\"  High-retry : {', '.join(high)}  ← review task specs\")
findings = s.get('top_security_findings', [])
if findings:
    print(f\"  Top security findings:\")
    for finding in findings:
        print(f\"    - {finding}\")
h = s.get('health', {})
if any(v is not None for v in h.values()):
    print(f\"  Code health:\")
    if h.get('avg_coverage_pct') is not None:
        print(f\"    Coverage   : {h['avg_coverage_pct']}% avg\")
    if h.get('avg_duplication_pct') is not None:
        print(f\"    Duplication: {h['avg_duplication_pct']}% avg\")
    if h.get('total_complex_fns', 0) > 0:
        print(f\"    Complex fns: {h['total_complex_fns']} functions > 20 lines\")
"
fi

# Clean up HALT.md if present from a previous run
rm -f "$REPO_ROOT/HALT.md"

exit 0
