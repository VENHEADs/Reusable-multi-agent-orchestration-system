#!/usr/bin/env bash
set -euo pipefail

# restart.sh - Restart the agent system by requeuing failed tasks
#
# Usage: ./agent_factory/restart.sh [--all-queues] [--dry-run]

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

agent_factory_dir="$script_dir"

ALL_QUEUES="${1:-}"
DRY_RUN="${DRY_RUN:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all-queues)
      ALL_QUEUES="1"
      shift
      ;;
    --dry-run)
      DRY_RUN="1"
      shift
      ;;
    *)
      echo "unknown option: $1" >&2
      echo "usage: $0 [--all-queues] [--dry-run]"
      exit 1
      ;;
  esac
done

echo "🔄 RESTARTING AGENT SYSTEM"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# show current status
echo "📊 Current Status:"
"$agent_factory_dir/queue_status.sh"
echo

# requeue failed tasks
if [[ "$ALL_QUEUES" == "1" ]]; then
  echo "🔍 Requeuing failed tasks from all queues..."
  for queue_dir in tasks/{planner_queue,subplanner_queue,queue,judge_queue}; do
    if [[ -d "$queue_dir" ]]; then
      echo
      echo "  Queue: $(basename "$queue_dir")"
      DRY_RUN="$DRY_RUN" "$agent_factory_dir/requeue_failed.sh" --queue-dir "$queue_dir"
    fi
  done
else
  echo "🔍 Requeuing failed tasks from worker queue..."
  DRY_RUN="$DRY_RUN" "$agent_factory_dir/requeue_failed.sh" --queue-dir tasks/queue
fi

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Status After Requeue:"
"$agent_factory_dir/queue_status.sh"

echo
echo "✅ System ready to continue"
echo
echo "Next steps:"
echo "  1. Monitor progress: ./agent_factory/monitor.sh --watch"
echo "  2. Start orchestrator: ./agent_factory/run_orchestrator --profile Agent_profiles/worker.md --queue-dir tasks/queue --max 1 --sleep 10"
echo "  3. Or use launchd jobs (if configured)"
echo
