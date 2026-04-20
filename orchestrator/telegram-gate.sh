#!/bin/bash

# Watches for a Telegram reply and writes approval.json
# Usage: ./orchestrator/telegram-gate.sh --phase 1

set -euo pipefail

PHASE=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --phase=*) PHASE="${1#*=}"; shift ;;
    --phase) PHASE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [ -z "$PHASE" ]; then
  echo "Usage: ./orchestrator/telegram-gate.sh --phase 1"
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPELINE_DIR="$REPO_ROOT/pipeline/phase-$PHASE"
APPROVAL_FILE="$PIPELINE_DIR/approval.json"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  source "$REPO_ROOT/.env"
  set +a
fi

echo "Waiting for your Telegram reply..."
echo "Reply 'approve', 'changes: [what]', or 'stop'"

# Get the latest update_id to use as offset so we ignore pre-existing messages
LAST_UPDATE_ID=0
RESPONSE=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?limit=1&offset=-1")
LAST_UPDATE_ID=$(echo "$RESPONSE" | python3 -c "
import json,sys
data = json.load(sys.stdin)
results = data.get('result', [])
if results:
    print(results[-1]['update_id'] + 1)
else:
    print(0)
")

DEADLINE=$(( $(date +%s) + 86400 ))

while [ $(date +%s) -lt $DEADLINE ]; do
  # timeout=10 is a server-side long-poll — curl blocks until a message arrives
  # or 10 seconds elapse, so no sleep is needed between iterations
  RESPONSE=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=${LAST_UPDATE_ID}&timeout=10&allowed_updates=message")

  RESULT=$(echo "$RESPONSE" | python3 -c "
import json,sys
data = json.load(sys.stdin)
results = data.get('result', [])
for update in results:
    msg = update.get('message', {})
    chat_id = str(msg.get('chat', {}).get('id', ''))
    text = msg.get('text', '').strip().lower()
    update_id = update['update_id']
    allowed_chat = '${TELEGRAM_ALLOWED_CHAT_ID}'
    if chat_id == allowed_chat and text:
        print(f'{update_id}|{text}')
        break
" 2>/dev/null)

  if [ -n "$RESULT" ]; then
    UPDATE_ID=$(echo "$RESULT" | cut -d'|' -f1)
    TEXT=$(echo "$RESULT" | cut -d'|' -f2-)
    LAST_UPDATE_ID=$(( UPDATE_ID + 1 ))

    if [ "$TEXT" = "approve" ] || [ "$TEXT" = "yes" ]; then
      echo "Approved via Telegram"
      python3 -c "
import json
with open('$APPROVAL_FILE', 'w') as f:
    json.dump({'signal': 'approve', 'timestamp': '$(date -u +"%Y-%m-%dT%H:%M:%SZ")', 'source': 'telegram'}, f, indent=2)
"
      curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "text=✅ Approved. Pipeline starting implementation..." \
        -d "chat_id=${TELEGRAM_ALLOWED_CHAT_ID}" > /dev/null
      exit 0

    elif [[ "$TEXT" == changes:* ]]; then
      CHANGES="${TEXT#changes:}"
      CHANGES="${CHANGES# }"
      echo "Changes requested: $CHANGES"
      python3 -c "
import json
with open('$APPROVAL_FILE', 'w') as f:
    json.dump({'signal': 'changes', 'changes': '$CHANGES', 'timestamp': '$(date -u +"%Y-%m-%dT%H:%M:%SZ")', 'source': 'telegram'}, f, indent=2)
"
      curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "text=📝 Changes noted. Regenerating manifest..." \
        -d "chat_id=${TELEGRAM_ALLOWED_CHAT_ID}" > /dev/null
      exit 0

    elif [ "$TEXT" = "stop" ] || [ "$TEXT" = "no" ]; then
      echo "Pipeline stopped by user"
      python3 -c "
import json
with open('$APPROVAL_FILE', 'w') as f:
    json.dump({'signal': 'stop', 'timestamp': '$(date -u +"%Y-%m-%dT%H:%M:%SZ")', 'source': 'telegram'}, f, indent=2)
"
      curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "text=🛑 Pipeline stopped." \
        -d "chat_id=${TELEGRAM_ALLOWED_CHAT_ID}" > /dev/null
      exit 0
    fi
  fi
done

echo "Timeout — no approval received"
exit 1
