#!/usr/bin/env bash
set -euo pipefail

# watch_logs.sh - Watch latest agent run logs in real-time
#
# Usage: ./agent_factory/watch_logs.sh [--tail N] [--follow]

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TAIL_LINES="${1:-80}"
FOLLOW="${FOLLOW:-0}"

if [[ "${1:-}" == "--follow" ]] || [[ "${1:-}" == "-f" ]]; then
  FOLLOW="1"
  TAIL_LINES="${2:-80}"
elif [[ "${1:-}" == "--tail" ]] || [[ "${1:-}" == "-n" ]]; then
  TAIL_LINES="${2:-80}"
  if [[ "${3:-}" == "--follow" ]] || [[ "${3:-}" == "-f" ]]; then
    FOLLOW="1"
  fi
fi

log_dir="logs/agent_runs"
if [[ ! -d "$log_dir" ]]; then
  echo "No agent runs yet. Logs directory: $log_dir"
  exit 0
fi

# find latest log
latest_log="$(ls -1t "$log_dir"/*.log 2>/dev/null | head -n 1 || true)"

if [[ -z "$latest_log" ]] || [[ ! -f "$latest_log" ]]; then
  echo "No agent run logs found in $log_dir"
  exit 0
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Latest agent run: $(basename "$latest_log")"
echo "  Full path: $latest_log"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

if [[ "$FOLLOW" == "1" ]]; then
  tail -f -n "$TAIL_LINES" "$latest_log"
else
  tail -n "$TAIL_LINES" "$latest_log"
fi
