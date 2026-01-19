#!/usr/bin/env bash
set -euo pipefail

# requeue_failed.sh - Requeue failed tasks from processed directory
#
# Usage: ./agent_factory/requeue_failed.sh [--queue-dir <dir>] [--dry-run]

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

QUEUE_DIR="tasks/queue"
DRY_RUN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --queue-dir)
      QUEUE_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="1"
      shift
      ;;
    *)
      echo "unknown option: $1" >&2
      echo "usage: $0 [--queue-dir <dir>] [--dry-run]"
      exit 1
      ;;
  esac
done

if [[ ! -d "$QUEUE_DIR" ]]; then
  echo "Queue directory not found: $QUEUE_DIR" >&2
  exit 1
fi

processed_dir="$QUEUE_DIR/processed"
if [[ ! -d "$processed_dir" ]]; then
  echo "No processed tasks found in $processed_dir"
  exit 0
fi

log_dir="logs/agent_runs"
if [[ ! -d "$log_dir" ]]; then
  echo "No agent logs found in $log_dir"
  exit 0
fi

echo "🔍 Scanning for failed tasks..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

requeued=0
skipped=0

# find all processed task files
for processed_file in "$processed_dir"/*.md.*; do
  [[ ! -f "$processed_file" ]] && continue
  
  # extract original task name (before timestamp and PID)
  task_name="$(basename "$processed_file" | sed -E 's/\.([0-9]+\.)+[0-9]+$//')"
  
  # find corresponding log file
  log_file="$(find "$log_dir" -name "*_${task_name}.log" -type f | sort -r | head -n 1)"
  
  if [[ -z "$log_file" ]] || [[ ! -f "$log_file" ]]; then
    # no log found, skip
    continue
  fi
  
  # check for failure indicators
  is_failed="0"
  failure_reason=""
  
  # check for rate limit (even after fallback attempt)
  if grep -qiE "(hit your hard limit|rate limit|429|quota|ActionRequiredError)" "$log_file" 2>/dev/null; then
    # check if fallback was attempted and also failed
    if grep -q "FALLBACK ATTEMPT" "$log_file" 2>/dev/null; then
      # fallback was attempted, check if it also failed
      if ! grep -qE "(successfully completed|Task.*completed)" "$log_file" 2>/dev/null; then
        is_failed="1"
        failure_reason="rate limit (fallback also failed)"
      fi
    else
      # no fallback attempted yet, or fallback not configured
      is_failed="1"
      failure_reason="rate limit"
    fi
  fi
  
  # check for empty output
  if [[ "$is_failed" == "0" ]] && [[ ! -s "$log_file" ]] || [[ "$(wc -l < "$log_file" | tr -d ' ')" -lt 3 ]]; then
    is_failed="1"
    failure_reason="empty output"
  fi
  
  # check for NEED-INFO
  if [[ "$is_failed" == "0" ]] && grep -qi "NEED-INFO" "$log_file" 2>/dev/null; then
    is_failed="1"
    failure_reason="NEED-INFO"
  fi
  
  # check for error patterns (but not if it looks successful)
  if [[ "$is_failed" == "0" ]] && grep -qiE "(error|failed|exception)" "$log_file" 2>/dev/null; then
    # only mark as failed if it doesn't look like a successful completion
    if ! grep -qiE "(Task.*completed|Summary|successfully|all tests passed)" "$log_file" 2>/dev/null; then
      is_failed="1"
      failure_reason="error in log"
    fi
  fi
  
    if [[ "$is_failed" == "1" ]]; then
      target_file="$QUEUE_DIR/$task_name"
      
      if [[ -f "$target_file" ]]; then
        echo "  ⚠️  $task_name (already in queue, skipping)"
        skipped=$((skipped + 1))
        continue
      fi
      
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "  [DRY-RUN] Would requeue: $task_name ($failure_reason)"
        requeued=$((requeued + 1))
      else
        if mv "$processed_file" "$target_file" 2>/dev/null; then
          echo "  ✅ Requeued: $task_name ($failure_reason)"
          requeued=$((requeued + 1))
        else
          echo "  ❌ Failed to requeue: $task_name" >&2
        fi
      fi
    fi
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "  [DRY-RUN] Would requeue: $requeued tasks, skipped: $skipped"
else
  echo "  Requeued: $requeued tasks, skipped: $skipped"
fi
echo
