#!/usr/bin/env bash
set -euo pipefail

# watch_logs.sh - Watch latest agent run logs in real-time
#
# Usage: ./agent_factory/watch_logs.sh [--tail N] [--follow]

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$script_dir/.git" ]]; then
  repo_root="$script_dir"
elif [[ -d "$script_dir/../.git" ]]; then
  repo_root="$(cd "$script_dir/.." && pwd)"
elif [[ -d "$PWD/tasks" || -f "$PWD/goal.md" ]]; then
  repo_root="$PWD"
else
  repo_root="$(cd "$script_dir/.." && pwd)"
fi
cd "$repo_root"

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
