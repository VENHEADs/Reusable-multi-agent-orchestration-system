#!/usr/bin/env bash
set -euo pipefail

# queue_status.sh - Quick queue status overview
#
# Usage: ./agent_factory/queue_status.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# source configuration
AGENT_FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${AGENT_FACTORY_DIR}/config.sh" 2>/dev/null || true

# calculate task age in seconds from file modification time
get_task_age() {
  local task_file="$1"
  local now
  now="$(date +%s)"
  local timestamp
  if [[ "$(uname)" == "Darwin" ]]; then
    timestamp="$(stat -f "%B" "$task_file" 2>/dev/null || echo "0")"
    if [[ "$timestamp" -le 0 ]]; then
      timestamp="$(stat -f "%m" "$task_file" 2>/dev/null || echo "$now")"
    fi
  else
    timestamp="$(stat -c "%W" "$task_file" 2>/dev/null || echo "0")"
    if [[ "$timestamp" -le 0 ]]; then
      timestamp="$(stat -c "%Y" "$task_file" 2>/dev/null || echo "$now")"
    fi
  fi
  echo $((now - timestamp))
}

# format age as human-readable string
format_age() {
  local age_seconds="$1"
  if [[ "$age_seconds" -lt 60 ]]; then
    echo "${age_seconds}s"
  elif [[ "$age_seconds" -lt 3600 ]]; then
    echo "$((age_seconds / 60))m"
  elif [[ "$age_seconds" -lt 86400 ]]; then
    echo "$((age_seconds / 3600))h"
  else
    echo "$((age_seconds / 86400))d"
  fi
}

stuck_threshold="${MONITOR_STUCK_THRESHOLD:-3600}"
warning_threshold="${MONITOR_WARNING_THRESHOLD:-1800}"

total_pending=0
total_processed=0
has_stuck=0
has_warnings=0
total_stuck=0
total_warning=0
planner_pending=0
subplanner_pending=0
worker_pending=0
judge_pending=0
planner_rate=0
subplanner_rate=0
worker_rate=0
judge_rate=0
health_status="healthy"
health_warnings=""
health_criticals=""

# calculate processing rate helper
# uses files processed in last hour to estimate current rate
get_processing_rate() {
  local processed_dir="$1"
  if [[ ! -d "$processed_dir" ]]; then
    echo "0"
    return
  fi
  
  local now
  now="$(date +%s)"
  local one_hour_ago=$((now - 3600))
  local files_in_last_hour=0
  
  # count files processed in last hour
  while IFS= read -r processed_file; do
    [[ -z "$processed_file" ]] && continue
    [[ ! -f "$processed_file" ]] && continue
    
    local mtime
    if [[ "$(uname)" == "Darwin" ]]; then
      mtime="$(stat -f "%m" "$processed_file" 2>/dev/null || echo "0")"
    else
      mtime="$(stat -c "%Y" "$processed_file" 2>/dev/null || echo "0")"
    fi
    
    # count files processed in last hour
    if [[ "$mtime" -ge "$one_hour_ago" ]] && [[ "$mtime" -le "$now" ]]; then
      files_in_last_hour=$((files_in_last_hour + 1))
    fi
  done < <(find "$processed_dir" -type f \( -name '*.md' -o -name '*.md.*' \) ! -name '*.provenance.json' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -n 100 || true)
  
  # if no files in last hour, try last 24 hours and scale down
  if [[ "$files_in_last_hour" -eq 0 ]]; then
    local one_day_ago=$((now - 86400))
    local files_in_last_day=0
    
    while IFS= read -r processed_file; do
      [[ -z "$processed_file" ]] && continue
      [[ ! -f "$processed_file" ]] && continue
      
      local mtime
      if [[ "$(uname)" == "Darwin" ]]; then
        mtime="$(stat -f "%m" "$processed_file" 2>/dev/null || echo "0")"
      else
        mtime="$(stat -c "%Y" "$processed_file" 2>/dev/null || echo "0")"
      fi
      
      if [[ "$mtime" -ge "$one_day_ago" ]] && [[ "$mtime" -le "$now" ]]; then
        files_in_last_day=$((files_in_last_day + 1))
      fi
    done < <(find "$processed_dir" -type f \( -name '*.md' -o -name '*.md.*' \) ! -name '*.provenance.json' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -n 200 || true)
    
    # estimate hourly rate from daily rate (files_in_last_day / 24)
    if [[ "$files_in_last_day" -gt 0 ]]; then
      echo $((files_in_last_day / 24))
    else
      echo "0"
    fi
  else
    echo "$files_in_last_hour"
  fi
}

# first pass: collect all metrics
for queue_dir in tasks/{planner_queue,subplanner_queue,queue,judge_queue}; do
  if [[ ! -d "$queue_dir" ]]; then
    continue
  fi
  
  queue_name="$(basename "$queue_dir")"
  pending="$(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  processed="$(find "$queue_dir/processed" -type f \( -name '*.md' -o -name '*.md.*' \) ! -name '*.provenance.json' 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
  
  total_pending=$((total_pending + pending))
  total_processed=$((total_processed + processed))
  
  if [[ "$pending" -gt 0 ]]; then
    # find oldest pending task and count stuck/warning tasks
    oldest_task=""
    oldest_age=0
    stuck_count=0
    warning_count=0
    
    while IFS= read -r task_file; do
      [[ -z "$task_file" ]] && continue
      [[ ! -f "$task_file" ]] && continue
      
      age="$(get_task_age "$task_file")"
      if [[ "$age" -gt "$oldest_age" ]]; then
        oldest_age="$age"
        oldest_task="$task_file"
      fi
      if [[ "$age" -gt "$stuck_threshold" ]]; then
        stuck_count=$((stuck_count + 1))
        total_stuck=$((total_stuck + 1))
      elif [[ "$age" -gt "$warning_threshold" ]]; then
        warning_count=$((warning_count + 1))
        total_warning=$((total_warning + 1))
      fi
    done < <(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null || true)
    
    if [[ "$stuck_count" -gt 0 ]]; then
      has_stuck=1
    elif [[ "$warning_count" -gt 0 ]]; then
      has_warnings=1
    fi
    
    # get processing rate
    rate=0
    if [[ -d "$queue_dir/processed" ]]; then
      rate="$(get_processing_rate "$queue_dir/processed")"
    fi
    
    # store metrics by queue name for imbalance detection
    case "$queue_name" in
      planner_queue)
        planner_pending="$pending"
        planner_rate="$rate"
        ;;
      subplanner_queue)
        subplanner_pending="$pending"
        subplanner_rate="$rate"
        ;;
      queue)
        worker_pending="$pending"
        worker_rate="$rate"
        ;;
      judge_queue)
        judge_pending="$pending"
        judge_rate="$rate"
        ;;
    esac
  fi
done

# calculate overall health status
if [[ "$has_stuck" -eq 1 ]]; then
  health_status="critical"
  health_criticals="$total_stuck stuck task(s) detected"
elif [[ "$has_warnings" -eq 1 ]]; then
  health_status="warning"
  health_warnings="$total_warning aging task(s) detected"
fi

# check for queue imbalances
if [[ "$planner_pending" -eq 0 ]] && [[ "$subplanner_pending" -gt 10 ]]; then
  if [[ "$health_status" == "healthy" ]]; then
    health_status="warning"
  fi
  if [[ -z "$health_warnings" ]]; then
    health_warnings="planner_queue empty but subplanner_queue has $subplanner_pending tasks"
  else
    health_warnings="$health_warnings; planner_queue empty but subplanner_queue has $subplanner_pending tasks"
  fi
fi

if [[ "$subplanner_pending" -eq 0 ]] && [[ "$worker_pending" -gt 20 ]]; then
  if [[ "$health_status" == "healthy" ]]; then
    health_status="warning"
  fi
  if [[ -z "$health_warnings" ]]; then
    health_warnings="subplanner_queue empty but queue has $worker_pending tasks"
  else
    health_warnings="$health_warnings; subplanner_queue empty but queue has $worker_pending tasks"
  fi
fi

if [[ "$worker_pending" -eq 0 ]] && [[ "$judge_pending" -gt 5 ]]; then
  if [[ "$health_status" == "healthy" ]]; then
    health_status="warning"
  fi
  if [[ -z "$health_warnings" ]]; then
    health_warnings="queue empty but judge_queue has $judge_pending tasks"
  else
    health_warnings="$health_warnings; queue empty but judge_queue has $judge_pending tasks"
  fi
fi

# check for zero processing rates with pending tasks
if [[ "$planner_pending" -gt 0 ]] && [[ "$planner_rate" -eq 0 ]]; then
  if [[ "$health_status" == "healthy" ]]; then
    health_status="warning"
  fi
  if [[ -z "$health_warnings" ]]; then
    health_warnings="planner_queue has $planner_pending pending but zero processing rate"
  else
    health_warnings="$health_warnings; planner_queue has $planner_pending pending but zero processing rate"
  fi
fi

if [[ "$subplanner_pending" -gt 0 ]] && [[ "$subplanner_rate" -eq 0 ]]; then
  if [[ "$health_status" == "healthy" ]]; then
    health_status="warning"
  fi
  if [[ -z "$health_warnings" ]]; then
    health_warnings="subplanner_queue has $subplanner_pending pending but zero processing rate"
  else
    health_warnings="$health_warnings; subplanner_queue has $subplanner_pending pending but zero processing rate"
  fi
fi

if [[ "$worker_pending" -gt 0 ]] && [[ "$worker_rate" -eq 0 ]]; then
  if [[ "$health_status" == "healthy" ]]; then
    health_status="warning"
  fi
  if [[ -z "$health_warnings" ]]; then
    health_warnings="queue has $worker_pending pending but zero processing rate"
  else
    health_warnings="$health_warnings; queue has $worker_pending pending but zero processing rate"
  fi
fi

if [[ "$judge_pending" -gt 0 ]] && [[ "$judge_rate" -eq 0 ]]; then
  if [[ "$health_status" == "healthy" ]]; then
    health_status="warning"
  fi
  if [[ -z "$health_warnings" ]]; then
    health_warnings="judge_queue has $judge_pending pending but zero processing rate"
  else
    health_warnings="$health_warnings; judge_queue has $judge_pending pending but zero processing rate"
  fi
fi

# check for processing bottlenecks
if [[ "$planner_pending" -gt 5 ]] && [[ "$planner_rate" -gt 0 ]]; then
  estimated_hours=$((planner_pending / planner_rate))
  if [[ "$estimated_hours" -gt 2 ]]; then
    if [[ "$health_status" == "healthy" ]]; then
      health_status="warning"
    fi
    if [[ -z "$health_warnings" ]]; then
      health_warnings="planner_queue bottleneck: ~${estimated_hours}h to clear"
    else
      health_warnings="$health_warnings; planner_queue bottleneck: ~${estimated_hours}h to clear"
    fi
  fi
fi

if [[ "$subplanner_pending" -gt 5 ]] && [[ "$subplanner_rate" -gt 0 ]]; then
  estimated_hours=$((subplanner_pending / subplanner_rate))
  if [[ "$estimated_hours" -gt 2 ]]; then
    if [[ "$health_status" == "healthy" ]]; then
      health_status="warning"
    fi
    if [[ -z "$health_warnings" ]]; then
      health_warnings="subplanner_queue bottleneck: ~${estimated_hours}h to clear"
    else
      health_warnings="$health_warnings; subplanner_queue bottleneck: ~${estimated_hours}h to clear"
    fi
  fi
fi

if [[ "$worker_pending" -gt 10 ]] && [[ "$worker_rate" -gt 0 ]]; then
  estimated_hours=$((worker_pending / worker_rate))
  if [[ "$estimated_hours" -gt 2 ]]; then
    if [[ "$health_status" == "healthy" ]]; then
      health_status="warning"
    fi
    if [[ -z "$health_warnings" ]]; then
      health_warnings="queue bottleneck: ~${estimated_hours}h to clear"
    else
      health_warnings="$health_warnings; queue bottleneck: ~${estimated_hours}h to clear"
    fi
  fi
fi

if [[ "$judge_pending" -gt 3 ]] && [[ "$judge_rate" -gt 0 ]]; then
  estimated_hours=$((judge_pending / judge_rate))
  if [[ "$estimated_hours" -gt 1 ]]; then
    if [[ "$health_status" == "healthy" ]]; then
      health_status="warning"
    fi
    if [[ -z "$health_warnings" ]]; then
      health_warnings="judge_queue bottleneck: ~${estimated_hours}h to clear"
    else
      health_warnings="$health_warnings; judge_queue bottleneck: ~${estimated_hours}h to clear"
    fi
  fi
fi

# display health summary at top
echo "📋 QUEUE STATUS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
case "$health_status" in
  healthy)
    echo "  ✅ Health: HEALTHY"
    if [[ "$total_pending" -eq 0 ]]; then
      echo "     All queues empty"
    else
      echo "     All tasks within healthy age thresholds"
    fi
    ;;
  warning)
    echo "  ⚠️  Health: WARNING"
    echo "     $health_warnings"
    ;;
  critical)
    echo "  ❌ Health: CRITICAL"
    echo "     $health_criticals"
    if [[ -n "$health_warnings" ]]; then
      echo "     $health_warnings"
    fi
    ;;
esac
echo
echo "  Processing rates (tasks/hour):"
if [[ "$planner_rate" -gt 0 ]] || [[ "$planner_pending" -gt 0 ]]; then
  printf "     %-20s %3d tasks/hr\n" "planner_queue:" "$planner_rate"
fi
if [[ "$subplanner_rate" -gt 0 ]] || [[ "$subplanner_pending" -gt 0 ]]; then
  printf "     %-20s %3d tasks/hr\n" "subplanner_queue:" "$subplanner_rate"
fi
if [[ "$worker_rate" -gt 0 ]] || [[ "$worker_pending" -gt 0 ]]; then
  printf "     %-20s %3d tasks/hr\n" "queue:" "$worker_rate"
fi
if [[ "$judge_rate" -gt 0 ]] || [[ "$judge_pending" -gt 0 ]]; then
  printf "     %-20s %3d tasks/hr\n" "judge_queue:" "$judge_rate"
fi
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# second pass: display detailed queue information
for queue_dir in tasks/{planner_queue,subplanner_queue,queue,judge_queue}; do
  if [[ ! -d "$queue_dir" ]]; then
    continue
  fi
  
  queue_name="$(basename "$queue_dir")"
  pending="$(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  processed="$(find "$queue_dir/processed" -type f 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
  
  if [[ "$pending" -gt 0 ]]; then
    # find oldest pending task and count stuck/warning tasks
    oldest_task=""
    oldest_age=0
    stuck_count=0
    warning_count=0
    
    while IFS= read -r task_file; do
      [[ -z "$task_file" ]] && continue
      [[ ! -f "$task_file" ]] && continue
      
      age="$(get_task_age "$task_file")"
      if [[ "$age" -gt "$oldest_age" ]]; then
        oldest_age="$age"
        oldest_task="$task_file"
      fi
      if [[ "$age" -gt "$stuck_threshold" ]]; then
        stuck_count=$((stuck_count + 1))
      elif [[ "$age" -gt "$warning_threshold" ]]; then
        warning_count=$((warning_count + 1))
      fi
    done < <(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null || true)
    
    oldest_age_str="$(format_age "$oldest_age")"
    health_indicator=""
    if [[ "$stuck_count" -gt 0 ]]; then
      health_indicator=" ❌ ($stuck_count stuck)"
    elif [[ "$warning_count" -gt 0 ]]; then
      health_indicator=" ⚠️  ($warning_count aging)"
    fi
    
    # get processing rate
    rate=0
    if [[ -d "$queue_dir/processed" ]]; then
      rate="$(get_processing_rate "$queue_dir/processed")"
    fi
    
    if [[ "$rate" -gt 0 ]]; then
      printf "  %-20s %3d pending  %5d processed (oldest: %s, rate: %d/hr)%s\n" "$queue_name:" "$pending" "$processed" "$oldest_age_str" "$rate" "$health_indicator"
    else
      printf "  %-20s %3d pending  %5d processed (oldest: %s)%s\n" "$queue_name:" "$pending" "$processed" "$oldest_age_str" "$health_indicator"
    fi
    
    # show next 3 tasks or all stuck/warning tasks
    if [[ "$pending" -le 10 ]] || [[ "$stuck_count" -gt 0 ]] || [[ "$warning_count" -gt 0 ]]; then
      if [[ "$stuck_count" -gt 0 ]]; then
        # show stuck tasks first
        stuck_tasks=""
        while IFS= read -r task_file; do
          [[ -z "$task_file" ]] && continue
          [[ ! -f "$task_file" ]] && continue
          age="$(get_task_age "$task_file")"
          if [[ "$age" -gt "$stuck_threshold" ]]; then
            task_name="$(basename "$task_file")"
            task_age_str="$(format_age "$age")"
            if [[ -z "$stuck_tasks" ]]; then
              stuck_tasks="$task_name|$task_age_str"
            else
              stuck_tasks="$stuck_tasks"$'\n'"$task_name|$task_age_str"
            fi
          fi
        done < <(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null || true)
        
        if [[ -n "$stuck_tasks" ]]; then
          echo "     Stuck tasks:"
          echo "$stuck_tasks" | while IFS='|' read -r task_name task_age_str; do
            [[ -z "$task_name" ]] && continue
            echo "       ❌ $task_name (age: $task_age_str)"
          done
        fi
      fi
      
      # show warning tasks if any
      if [[ "$warning_count" -gt 0 ]] && [[ "$pending" -gt 10 ]]; then
        warning_tasks=""
        while IFS= read -r task_file; do
          [[ -z "$task_file" ]] && continue
          [[ ! -f "$task_file" ]] && continue
          age="$(get_task_age "$task_file")"
          if [[ "$age" -gt "$warning_threshold" ]] && [[ "$age" -le "$stuck_threshold" ]]; then
            task_name="$(basename "$task_file")"
            task_age_str="$(format_age "$age")"
            if [[ -z "$warning_tasks" ]]; then
              warning_tasks="$task_name|$task_age_str"
            else
              warning_tasks="$warning_tasks"$'\n'"$task_name|$task_age_str"
            fi
          fi
        done < <(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null || true)
        
        if [[ -n "$warning_tasks" ]]; then
          echo "     Aging tasks:"
          echo "$warning_tasks" | while IFS='|' read -r task_name task_age_str; do
            [[ -z "$task_name" ]] && continue
            echo "       ⚠️  $task_name (age: $task_age_str)"
          done
        fi
      fi
      
      # show next few tasks (excluding already shown stuck/warning tasks)
      next_tasks="$(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort | head -n 3)"
      while IFS= read -r task; do
        [[ -z "$task" ]] && continue
        task_name="$(basename "$task")"
        task_age="$(get_task_age "$task")"
        task_age_str="$(format_age "$task_age")"
        task_indicator=""
        if [[ "$task_age" -gt "$stuck_threshold" ]]; then
          task_indicator=" ❌"
        elif [[ "$task_age" -gt "$warning_threshold" ]]; then
          task_indicator=" ⚠️"
        fi
        echo "     → $task_name (age: $task_age_str)$task_indicator"
      done <<< "$next_tasks"
    fi
  else
    printf "  %-20s %3s          %5d processed\n" "$queue_name:" "✅" "$processed"
  fi
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  TOTAL: %3d pending tasks, %5d processed\n" "$total_pending" "$total_processed"

# show actionable recommendations based on health status
if [[ "$health_status" == "critical" ]]; then
  echo
  echo "  Immediate actions:"
  echo "     1. view details: ./agent_factory/monitor.sh --health"
  echo "     2. check logs: ./agent_factory/monitor.sh --logs"
  echo "     3. verify agents: ./agent_factory/monitor.sh --launchd"
  echo "     4. restart if needed: ./agent_factory/launchd_stop.sh && ./agent_factory/setup.sh"
  echo "     5. investigate stuck tasks: ./agent_factory/log_search.sh --task <task_name>"
elif [[ "$health_status" == "warning" ]]; then
  echo
  echo "  Recommended actions:"
  echo "     1. view details: ./agent_factory/monitor.sh --health"
  echo "     2. check processing rates: ./agent_factory/monitor.sh --queues"
  echo "     3. monitor for a few minutes: ./agent_factory/monitor.sh --watch"
fi
echo
