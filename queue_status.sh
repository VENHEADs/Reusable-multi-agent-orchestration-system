#!/usr/bin/env bash
set -euo pipefail

# queue_status.sh - Quick queue status overview
#
# Usage: ./agent_factory/queue_status.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "📋 QUEUE STATUS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

total_pending=0
total_processed=0

for queue_dir in tasks/{planner_queue,subplanner_queue,queue,judge_queue}; do
  if [[ ! -d "$queue_dir" ]]; then
    continue
  fi
  
  queue_name="$(basename "$queue_dir")"
  pending="$(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  processed="$(find "$queue_dir/processed" -type f 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
  
  total_pending=$((total_pending + pending))
  total_processed=$((total_processed + processed))
  
  if [[ "$pending" -gt 0 ]]; then
    printf "  %-20s %3d pending  %5d processed\n" "$queue_name:" "$pending" "$processed"
    
    # show next 3 tasks
    if [[ "$pending" -le 10 ]]; then
      next_tasks="$(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort | head -n 3)"
      while IFS= read -r task; do
        [[ -z "$task" ]] && continue
        task_name="$(basename "$task")"
        echo "     → $task_name"
      done <<< "$next_tasks"
    fi
  else
    printf "  %-20s %3s          %5d processed\n" "$queue_name:" "✅" "$processed"
  fi
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  TOTAL: %3d pending tasks, %5d processed\n" "$total_pending" "$total_processed"
echo
