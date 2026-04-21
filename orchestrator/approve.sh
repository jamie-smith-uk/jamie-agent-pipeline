#!/bin/bash

# Write approval signal for a paused phase or task pipeline gate.
# Used when run-phase.sh or run-task.sh is running non-interactively
# (e.g. backgrounded, in CI, or under Claude Code).
#
# Usage:
#   ./orchestrator/approve.sh --phase 2                          (approve phase)
#   ./orchestrator/approve.sh --phase 2 --stop                   (stop phase)
#   ./orchestrator/approve.sh --phase 2 --changes "what to fix"  (request revision)
#   ./orchestrator/approve.sh --task pipeline/tasks/<slug>-<ts>  (approve task)
#   ./orchestrator/approve.sh --task pipeline/tasks/<slug>-<ts> --stop

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PHASE=""
TASK_DIR=""
SIGNAL="approve"
CHANGES=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --phase=*)   PHASE="${1#*=}";    shift ;;
    --phase)     PHASE="$2";         shift 2 ;;
    --task=*)    TASK_DIR="${1#*=}"; shift ;;
    --task)      TASK_DIR="$2";      shift 2 ;;
    --stop)      SIGNAL="stop";      shift ;;
    --changes)   SIGNAL="changes"; CHANGES="$2"; shift 2 ;;
    --changes=*) SIGNAL="changes"; CHANGES="${1#*=}"; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [ -n "$PHASE" ]; then
  TARGET_DIR="$REPO_ROOT/pipeline/phase-$PHASE"
  LABEL="Phase $PHASE"
elif [ -n "$TASK_DIR" ]; then
  # Accept either absolute path or path relative to repo root
  if [[ "$TASK_DIR" = /* ]]; then
    TARGET_DIR="$TASK_DIR"
  else
    TARGET_DIR="$REPO_ROOT/$TASK_DIR"
  fi
  LABEL="Task $(basename "$TARGET_DIR")"
else
  echo "Usage: ./orchestrator/approve.sh --phase N | --task pipeline/tasks/<slug>-<ts>"
  echo "  Optional: --stop | --changes \"description\""
  exit 1
fi

if [ ! -d "$TARGET_DIR" ]; then
  echo "Error: $TARGET_DIR does not exist — is the pipeline running?"
  exit 1
fi

APPROVAL_FILE="$TARGET_DIR/approval.json"

python3 -c "
import json, datetime
data = {'signal': '$SIGNAL', 'timestamp': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'), 'source': 'approve.sh'}
$([ -n "$CHANGES" ] && echo "data['changes'] = '$CHANGES'")
with open('$APPROVAL_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"

echo "✅ $LABEL: signal '$SIGNAL' written → $APPROVAL_FILE"
