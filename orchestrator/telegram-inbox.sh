#!/bin/bash

# telegram-inbox.sh — Persistent Telegram listener for creating and running tasks.
#
# Send commands to your bot:
#   /task <description>   — generate a task spec and queue it for review
#   /fix  <description>   — alias for /task
#   /queue                — list pending backlog tasks
#   /run  <slug>          — run a queued task immediately
#   /status               — show what's running
#   /cancel               — cancel a pending approval
#   /stop                 — shut down the inbox
#
# Usage:
#   ./orchestrator/telegram-inbox.sh          — run in foreground
#   ./orchestrator/telegram-inbox.sh &        — run in background
#   ./orchestrator/telegram-inbox.sh --stop   — stop a running instance

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INBOX_DIR="$REPO_ROOT/pipeline/inbox"
STATE_FILE="$INBOX_DIR/state.json"
PID_FILE="$INBOX_DIR/inbox.pid"
TASK_PID_FILE="$INBOX_DIR/task.pid"
TASK_LOG="$INBOX_DIR/task.log"

# ── Stop command ──────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--stop" ]]; then
  if [ -f "$PID_FILE" ]; then
    INBOX_PID=$(cat "$PID_FILE")
    if kill -0 "$INBOX_PID" 2>/dev/null; then
      kill "$INBOX_PID"
      echo "Inbox stopped (PID $INBOX_PID)"
    else
      echo "Inbox was not running"
    fi
    rm -f "$PID_FILE"
  else
    echo "No inbox PID file found"
  fi
  exit 0
fi

# ── Environment ───────────────────────────────────────────────────────────────
if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN not set}"
: "${TELEGRAM_ALLOWED_CHAT_ID:?TELEGRAM_ALLOWED_CHAT_ID not set}"
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY not set}"

mkdir -p "$INBOX_DIR"

# Write our PID so --stop can find us
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"; log "Inbox stopped"; exit 0' EXIT INT TERM

log() { echo "[$(date '+%H:%M:%S')] [inbox] $*"; }

# ── State management ──────────────────────────────────────────────────────────
# States: idle | awaiting_approval | running
read_state() {
  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  else
    echo '{"state":"idle","pending_slug":null,"running_slug":null,"running_pid":null,"last_update_id":0}'
  fi
}

get_field() {
  local json="$1" field="$2"
  echo "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$field') or '')"
}

save_state() {
  echo "$1" | python3 -m json.tool > "$STATE_FILE" 2>/dev/null || echo "$1" > "$STATE_FILE"
}

update_state() {
  local json="$1"; shift
  while [[ $# -gt 0 ]]; do
    local key="$1" val="$2"; shift 2
    json=$(echo "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
v = '$val'
if v == 'null': v = None
elif v == 'true': v = True
elif v == 'false': v = False
d['$key'] = v
print(json.dumps(d))
")
  done
  echo "$json"
}

# ── Telegram helpers ──────────────────────────────────────────────────────────
send() {
  local text="$1"
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "text=$text" \
    -d "chat_id=${TELEGRAM_ALLOWED_CHAT_ID}" \
    -d "parse_mode=Markdown" > /dev/null
}

get_updates() {
  local offset="$1"
  curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=${offset}&timeout=10&allowed_updates=message"
}

# ── Spec generation ───────────────────────────────────────────────────────────
generate_spec() {
  local description="$1"
  python3 - "$description" "${ANTHROPIC_API_KEY}" "$REPO_ROOT" <<'PYEOF'
import json, re, subprocess, sys, urllib.request

desc, api_key, repo_root = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    listing = subprocess.run(
        ['git', 'ls-files', '--cached'],
        capture_output=True, text=True, cwd=repo_root, timeout=5
    ).stdout[:2000]
except Exception:
    listing = '(unavailable)'

prompt = (
    f"You are a software architect. Given this task description and repo file listing, "
    f"produce a task manifest JSON object.\n\n"
    f"Task: {desc}\nRepo files:\n{listing}\n\n"
    f"Reply with ONLY valid JSON:\n"
    f'{{"id":"kebab-slug-max-40-chars","title":"Short title",'
    f'"description":"What to build","files_in_scope":["path/to/file.ts"],'
    f'"dependencies":[],"acceptance_criteria":["Specific testable criterion"],'
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
        task = json.loads(m.group(0)) if m else {}
        print(json.dumps(task))
except Exception as e:
    print(json.dumps({"error": str(e)}), file=sys.stderr)
    sys.exit(1)
PYEOF
}

format_spec_message() {
  local task_json="$1" slug="$2"
  python3 -c "
import json, sys
t = json.loads(sys.argv[1])
slug = sys.argv[2]
files = ', '.join(t.get('files_in_scope', [])) or '(to be determined)'
criteria = '\n'.join(f'  • {c}' for c in t.get('acceptance_criteria', []))
security = '⚠️ Yes' if t.get('security_sensitive') else 'No'
print(f'''📋 *{t['title']}*
\`{slug}\`

Files: {files}
Security sensitive: {security}
Complexity: {t.get('estimated_complexity','medium')}

Criteria:
{criteria}

Reply: *run* | *edit:* [changes] | *cancel*''')
" "$task_json" "$slug"
}

write_backlog_file() {
  local slug="$1" task_json="$2"
  local file="$REPO_ROOT/backlog/$slug.md"
  python3 -c "
import json, sys
t = json.loads(sys.argv[1])
slug = sys.argv[2]
files_yaml = '\n'.join(f'  - {f}' for f in t.get('files_in_scope', []))
criteria_yaml = '\n'.join(f'  - {c}' for c in t.get('acceptance_criteria', []))
print(f'''---
title: {t['title']}
security_sensitive: {str(t.get('security_sensitive',False)).lower()}
files:
{files_yaml}
criteria:
{criteria_yaml}
---

{t.get('description','')}
''')
" "$task_json" "$slug" > "$file"
  echo "$file"
}

# ── Task execution ────────────────────────────────────────────────────────────
start_task() {
  local slug="$1"
  local file="$REPO_ROOT/backlog/$slug.md"

  if [ ! -f "$file" ]; then
    send "❌ Task file not found: backlog/$slug.md"
    return 1
  fi

  log "Starting task: $slug"
  nohup "$SCRIPT_DIR/run-task.sh" "$file" > "$TASK_LOG" 2>&1 &
  local task_pid=$!
  echo "$task_pid" > "$TASK_PID_FILE"
  log "Task PID: $task_pid"
  echo "$task_pid"
}

is_task_running() {
  [ -f "$TASK_PID_FILE" ] || return 1
  local pid
  pid=$(cat "$TASK_PID_FILE")
  kill -0 "$pid" 2>/dev/null
}

check_task_completion() {
  local state="$1"
  is_task_running && return 1  # still running

  # Task finished — determine outcome from log
  local slug
  slug=$(get_field "$state" "running_slug")
  local exit_info=""
  if [ -f "$TASK_LOG" ]; then
    exit_info=$(tail -5 "$TASK_LOG" | grep -E "Task complete|HALTED|Error" | tail -1 || true)
  fi

  rm -f "$TASK_PID_FILE"
  log "Task $slug completed"

  # run-task.sh already sends the Telegram notification on success;
  # send our own only if it was halted/errored and the notification may not have fired
  if echo "$exit_info" | grep -q "HALTED\|Error"; then
    send "❌ Task *$slug* halted. Check \`pipeline/inbox/task.log\` for details."
  fi

  return 0
}

# ── Command handlers ──────────────────────────────────────────────────────────
handle_task_command() {
  local state="$1" description="$2"

  if is_task_running; then
    send "⚠️ A task is already running. Use /status to check progress."
    echo "$state"; return
  fi

  send "⏳ Generating spec..."
  local task_json
  if ! task_json=$(generate_spec "$description"); then
    send "❌ Failed to generate spec. Try again or use a task file."
    echo "$state"; return
  fi

  local slug
  slug=$(echo "$task_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id','task'))")
  slug=$(echo "$slug" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-40)

  write_backlog_file "$slug" "$task_json" > /dev/null

  local msg
  msg=$(format_spec_message "$task_json" "$slug")
  send "$msg"

  state=$(update_state "$state" "state" "awaiting_approval" "pending_slug" "$slug")
  echo "$state"
}

handle_queue_command() {
  local state="$1"
  local files
  files=$(find "$REPO_ROOT/backlog" -name "*.md" ! -name "README.md" 2>/dev/null | sort)

  if [ -z "$files" ]; then
    send "📭 No tasks in the backlog."
  else
    local list=""
    while IFS= read -r f; do
      local slug
      slug=$(basename "$f" .md)
      local title
      title=$(grep -m1 "^title:" "$f" 2>/dev/null | sed 's/^title: //' || echo "$slug")
      list+="  • \`$slug\` — $title\n"
    done <<< "$files"
    send "📋 *Backlog*\n\n${list}\nUse */run <slug>* to start one."
  fi

  echo "$state"
}

handle_run_command() {
  local state="$1" slug="$2"

  if is_task_running; then
    send "⚠️ A task is already running. Use /status to check."
    echo "$state"; return
  fi

  if [ ! -f "$REPO_ROOT/backlog/$slug.md" ]; then
    send "❌ No backlog file found for \`$slug\`"
    echo "$state"; return
  fi

  send "▶ Starting *$slug*..."
  start_task "$slug"
  state=$(update_state "$state" "state" "running" "running_slug" "$slug" \
    "running_pid" "$(cat "$TASK_PID_FILE")" "pending_slug" "null")
  echo "$state"
}

handle_status_command() {
  local state="$1"
  local current
  current=$(get_field "$state" "state")

  case "$current" in
    idle)
      send "💤 Idle — no task running.\n\nUse */task <description>* or */queue* to see pending tasks."
      ;;
    awaiting_approval)
      local slug
      slug=$(get_field "$state" "pending_slug")
      send "⏸ Waiting for your approval on *$slug*.\n\nReply: *run* | *edit:* [changes] | *cancel*"
      ;;
    running)
      local slug
      slug=$(get_field "$state" "running_slug")
      local lines=""
      if [ -f "$TASK_LOG" ]; then
        lines=$(tail -3 "$TASK_LOG" | sed 's/^/  /' || true)
      fi
      send "▶ Running *$slug*\n\nRecent output:\n$lines"
      ;;
  esac

  echo "$state"
}

# ── Main loop ─────────────────────────────────────────────────────────────────
log "Telegram inbox started (PID $$)"
log "Listening for commands from chat ${TELEGRAM_ALLOWED_CHAT_ID}..."

# Sync offset to current — don't replay old messages
STATE=$(read_state)
INITIAL_RESPONSE=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?limit=1&offset=-1")
LAST_UPDATE_ID=$(echo "$INITIAL_RESPONSE" | python3 -c "
import json, sys
r = json.load(sys.stdin).get('result', [])
print(r[-1]['update_id'] + 1 if r else 0)
")
STATE=$(update_state "$STATE" "last_update_id" "$LAST_UPDATE_ID")
save_state "$STATE"

log "Starting at update offset $LAST_UPDATE_ID"

while true; do
  STATE=$(read_state)
  LAST_UPDATE_ID=$(get_field "$STATE" "last_update_id")
  CURRENT_STATE=$(get_field "$STATE" "state")

  # ── Check for running task completion ──────────────────────────────────────
  if [ "$CURRENT_STATE" = "running" ]; then
    if check_task_completion "$STATE"; then
      STATE=$(update_state "$STATE" "state" "idle" "running_slug" "null" "running_pid" "null")
      save_state "$STATE"
      log "Returned to idle"
    fi
  fi

  # ── Poll for new messages ──────────────────────────────────────────────────
  RESPONSE=$(get_updates "$LAST_UPDATE_ID")

  RESULT=$(echo "$RESPONSE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
results = []
for update in data.get('result', []):
    msg = update.get('message', {})
    chat_id = str(msg.get('chat', {}).get('id', ''))
    text = msg.get('text', '').strip()
    update_id = update['update_id']
    if chat_id == '${TELEGRAM_ALLOWED_CHAT_ID}' and text:
        results.append(f'{update_id}|{text}')
for r in results:
    print(r)
" 2>/dev/null)

  if [ -z "$RESULT" ]; then
    continue
  fi

  # Process each message
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    UPDATE_ID=$(echo "$line" | cut -d'|' -f1)
    TEXT=$(echo "$line" | cut -d'|' -f2-)

    # Advance offset past this message
    NEW_OFFSET=$(( UPDATE_ID + 1 ))
    STATE=$(update_state "$STATE" "last_update_id" "$NEW_OFFSET")
    save_state "$STATE"
    LAST_UPDATE_ID="$NEW_OFFSET"

    CURRENT_STATE=$(get_field "$STATE" "state")
    log "Message [state=$CURRENT_STATE]: $TEXT"

    # ── Handle /stop ──────────────────────────────────────────────────────────
    if [[ "$TEXT" == "/stop" ]]; then
      send "🛑 Inbox stopping."
      exit 0
    fi

    # ── Handle state-aware commands ───────────────────────────────────────────
    case "$CURRENT_STATE" in

      idle)
        case "$TEXT" in
          /task\ *|/fix\ *)
            DESC="${TEXT#/t*ask }"
            DESC="${TEXT#/fix }"
            # Handle both /task and /fix
            [[ "$TEXT" == /task\ * ]] && DESC="${TEXT#/task }"
            [[ "$TEXT" == /fix\ * ]]  && DESC="${TEXT#/fix }"
            STATE=$(handle_task_command "$STATE" "$DESC")
            ;;
          /queue)
            STATE=$(handle_queue_command "$STATE")
            ;;
          /run\ *)
            SLUG="${TEXT#/run }"
            STATE=$(handle_run_command "$STATE" "$SLUG")
            ;;
          /status)
            STATE=$(handle_status_command "$STATE")
            ;;
          /help)
            send "*/task* <description> — create and review a task
*/fix* <description>  — alias for /task
*/queue*              — list pending backlog tasks
*/run* <slug>         — run a queued task
*/status*             — show what's running
*/stop*               — shut down the inbox"
            ;;
          *)
            send "Unknown command. Use */help* for available commands."
            ;;
        esac
        ;;

      awaiting_approval)
        PENDING_SLUG=$(get_field "$STATE" "pending_slug")
        TEXT_LOWER=$(echo "$TEXT" | tr '[:upper:]' '[:lower:]')
        case "$TEXT_LOWER" in
          run|yes|approve)
            send "▶ Starting *$PENDING_SLUG*..."
            start_task "$PENDING_SLUG"
            STATE=$(update_state "$STATE" "state" "running" \
              "running_slug" "$PENDING_SLUG" \
              "running_pid" "$(cat "$TASK_PID_FILE")" \
              "pending_slug" "null")
            ;;
          cancel|no|stop)
            rm -f "$REPO_ROOT/backlog/$PENDING_SLUG.md"
            STATE=$(update_state "$STATE" "state" "idle" "pending_slug" "null")
            send "❌ Task *$PENDING_SLUG* cancelled and removed from backlog."
            ;;
          edit:\ *)
            CHANGES="${TEXT#edit: }"
            send "⏳ Regenerating spec with your changes..."
            ORIGINAL_DESC=$(python3 -c "
import sys
try:
    content = open('$REPO_ROOT/backlog/$PENDING_SLUG.md').read()
    import re
    m = re.search(r'---\n.*?---\n(.*)', content, re.DOTALL)
    print(m.group(1).strip() if m else '$PENDING_SLUG')
except: print('$PENDING_SLUG')
")
            NEW_DESC="$ORIGINAL_DESC. Changes requested: $CHANGES"
            rm -f "$REPO_ROOT/backlog/$PENDING_SLUG.md"
            STATE=$(update_state "$STATE" "state" "idle" "pending_slug" "null")
            STATE=$(handle_task_command "$STATE" "$NEW_DESC")
            ;;
          /status)
            STATE=$(handle_status_command "$STATE")
            ;;
          *)
            PENDING_SLUG=$(get_field "$STATE" "pending_slug")
            send "⏸ Waiting for approval on *$PENDING_SLUG*.\n\nReply: *run* | *edit:* [changes] | *cancel*"
            ;;
        esac
        ;;

      running)
        RUNNING_SLUG=$(get_field "$STATE" "running_slug")
        TEXT_LOWER=$(echo "$TEXT" | tr '[:upper:]' '[:lower:]')
        case "$TEXT_LOWER" in
          /status)
            STATE=$(handle_status_command "$STATE")
            ;;
          *)
            send "▶ *$RUNNING_SLUG* is running. Use */status* to check progress."
            ;;
        esac
        ;;
    esac

    save_state "$STATE"

  done <<< "$RESULT"

done
