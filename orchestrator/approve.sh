#!/bin/bash

# Write approval signal for the pipeline human gate.
# Usage:
#   ./orchestrator/approve.sh --phase 2           (approve)
#   ./orchestrator/approve.sh --phase 2 --stop    (stop pipeline)
#   ./orchestrator/approve.sh --phase 2 --changes "move task-3 before task-2"

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PHASE=""
SIGNAL="approve"
CHANGES=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --phase=*) PHASE="${1#*=}"; shift ;;
    --phase) PHASE="$2"; shift 2 ;;
    --stop) SIGNAL="stop"; shift ;;
    --changes) SIGNAL="changes"; CHANGES="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [ -z "$PHASE" ]; then
  echo "Usage: ./orchestrator/approve.sh --phase 2"
  exit 1
fi

APPROVAL_FILE="$REPO_ROOT/pipeline/phase-$PHASE/approval.json"

python3 -c "
import json, datetime
data = {'signal': '$SIGNAL', 'timestamp': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'), 'source': 'claude-code'}
$([ -n "$CHANGES" ] && echo "data['changes'] = '$CHANGES'")
with open('$APPROVAL_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"

echo "✅ Phase $PHASE: signal '$SIGNAL' written to approval.json"
