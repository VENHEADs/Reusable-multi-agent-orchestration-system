#!/usr/bin/env bash
set -euo pipefail

# monitor.sh - Real-time status monitoring for agent factory
#
# Usage: ./agent_factory/monitor.sh [--watch] [--queues] [--logs] [--git] [--launchd] [--all]

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# source configuration
AGENT_FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${AGENT_FACTORY_DIR}/config.sh" 2>/dev/null || true

WATCH="${1:-}"
SHOW_QUEUES="${SHOW_QUEUES:-1}"
SHOW_LOGS="${SHOW_LOGS:-1}"
SHOW_GIT="${SHOW_GIT:-1}"
SHOW_LAUNCHD="${SHOW_LAUNCHD:-1}"
SHOW_GOAL="${SHOW_GOAL:-1}"
SHOW_BLOCKERS="${SHOW_BLOCKERS:-1}"

# parse arguments
if [[ "${1:-}" == "--watch" ]]; then
  WATCH="1"
  shift
fi

SHOW_HEALTH="${SHOW_HEALTH:-0}"
SHOW_TIMEOUTS="${SHOW_TIMEOUTS:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --queues) SHOW_QUEUES="1"; SHOW_LOGS="0"; SHOW_GIT="0"; SHOW_LAUNCHD="0"; SHOW_GOAL="0"; SHOW_HEALTH="0"; SHOW_TIMEOUTS="0"; shift ;;
    --logs) SHOW_LOGS="1"; SHOW_QUEUES="0"; SHOW_GIT="0"; SHOW_LAUNCHD="0"; SHOW_GOAL="0"; SHOW_HEALTH="0"; SHOW_TIMEOUTS="0"; shift ;;
    --git) SHOW_GIT="1"; SHOW_QUEUES="0"; SHOW_LOGS="0"; SHOW_LAUNCHD="0"; SHOW_GOAL="0"; SHOW_HEALTH="0"; SHOW_TIMEOUTS="0"; shift ;;
    --launchd) SHOW_LAUNCHD="1"; SHOW_QUEUES="0"; SHOW_LOGS="0"; SHOW_GIT="0"; SHOW_GOAL="0"; SHOW_HEALTH="0"; SHOW_TIMEOUTS="0"; shift ;;
    --blockers) SHOW_BLOCKERS="1"; SHOW_QUEUES="0"; SHOW_LOGS="0"; SHOW_GIT="0"; SHOW_LAUNCHD="0"; SHOW_GOAL="0"; SHOW_HEALTH="0"; SHOW_TIMEOUTS="0"; shift ;;
    --health) SHOW_HEALTH="1"; SHOW_QUEUES="0"; SHOW_LOGS="0"; SHOW_GIT="0"; SHOW_LAUNCHD="0"; SHOW_GOAL="0"; SHOW_TIMEOUTS="0"; shift ;;
    --timeouts) SHOW_TIMEOUTS="1"; SHOW_QUEUES="0"; SHOW_LOGS="0"; SHOW_GIT="0"; SHOW_LAUNCHD="0"; SHOW_GOAL="0"; SHOW_HEALTH="0"; shift ;;
    --all) SHOW_QUEUES="1"; SHOW_LOGS="1"; SHOW_GIT="1"; SHOW_LAUNCHD="1"; SHOW_GOAL="1"; SHOW_HEALTH="1"; SHOW_TIMEOUTS="1"; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

print_header() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

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

# calculate processing rate (tasks/hour) from processed directory
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

show_queues() {
  print_header "QUEUE STATUS"
  
  local stuck_threshold="${MONITOR_STUCK_THRESHOLD:-3600}"
  local warning_threshold="${MONITOR_WARNING_THRESHOLD:-1800}"
  
  for queue_dir in tasks/{planner_queue,subplanner_queue,queue,judge_queue}; do
    if [[ ! -d "$queue_dir" ]]; then
      continue
    fi
    
    queue_name="$(basename "$queue_dir")"
    pending="$(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    if [[ -d "$queue_dir/processed" ]]; then
      processed="$(find "$queue_dir/processed" -type f \( -name '*.md' -o -name '*.md.*' \) ! -name '*.provenance.json' 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    else
      processed="0"
    fi
    
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
        echo "  📋 $queue_name: $pending pending, $processed processed (oldest: ${oldest_age_str}, rate: ${rate}/hr)${health_indicator}"
      else
        echo "  📋 $queue_name: $pending pending, $processed processed (oldest: ${oldest_age_str})${health_indicator}"
      fi
      
      echo "     Tasks:"
      if [[ "$pending" -gt 10 ]]; then
        echo "       (showing first 10)"
      fi
      # always show stuck tasks first, then warning tasks, then others
      while IFS= read -r task_file; do
        [[ -z "$task_file" ]] && continue
        [[ ! -f "$task_file" ]] && continue
        
        task_name="$(basename "$task_file")"
        age="$(get_task_age "$task_file")"
        age_str="$(format_age "$age")"
        
        task_indicator=""
        if [[ "$age" -gt "$stuck_threshold" ]]; then
          task_indicator=" ❌ STUCK"
        elif [[ "$age" -gt "$warning_threshold" ]]; then
          task_indicator=" ⚠️ AGING"
        fi
        
        echo "       - $task_name (age: ${age_str})${task_indicator}"
      done < <(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort | head -n 10 || true)
    else
      echo "  ✅ $queue_name: empty ($processed processed)"
    fi
  done
  echo
}

show_queue_health() {
  print_header "QUEUE HEALTH"
  
  local stuck_threshold="${MONITOR_STUCK_THRESHOLD:-3600}"
  local warning_threshold="${MONITOR_WARNING_THRESHOLD:-1800}"
  local health_status="healthy"
  local planner_pending=0
  local subplanner_pending=0
  local worker_pending=0
  local judge_pending=0
  local planner_rate=0
  local subplanner_rate=0
  local worker_rate=0
  local judge_rate=0
  local planner_processed=0
  local subplanner_processed=0
  local worker_processed=0
  local judge_processed=0
  local warnings=""
  local criticals=""
  local stuck_tasks_list=""
  
  # collect queue metrics
  for queue_dir in tasks/{planner_queue,subplanner_queue,queue,judge_queue}; do
    if [[ ! -d "$queue_dir" ]]; then
      continue
    fi
    
    queue_name="$(basename "$queue_dir")"
    pending="$(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    if [[ -d "$queue_dir/processed" ]]; then
      processed="$(find "$queue_dir/processed" -type f \( -name '*.md' -o -name '*.md.*' \) ! -name '*.provenance.json' 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    else
      processed="0"
    fi
    
    # calculate processing rate
    local rate=0
    if [[ -d "$queue_dir/processed" ]]; then
      rate="$(get_processing_rate "$queue_dir/processed")"
    fi
    
    # store metrics by queue name
    case "$queue_name" in
      planner_queue)
        planner_pending="$pending"
        planner_rate="$rate"
        planner_processed="$processed"
        ;;
      subplanner_queue)
        subplanner_pending="$pending"
        subplanner_rate="$rate"
        subplanner_processed="$processed"
        ;;
      queue)
        worker_pending="$pending"
        worker_rate="$rate"
        worker_processed="$processed"
        ;;
      judge_queue)
        judge_pending="$pending"
        judge_rate="$rate"
        judge_processed="$processed"
        ;;
    esac
    
    # check for stuck tasks
    if [[ "$pending" -gt 0 ]]; then
      stuck_count=0
      oldest_age=0
      while IFS= read -r task_file; do
        [[ -z "$task_file" ]] && continue
        [[ ! -f "$task_file" ]] && continue
        
        age="$(get_task_age "$task_file")"
        if [[ "$age" -gt "$stuck_threshold" ]]; then
          stuck_count=$((stuck_count + 1))
        fi
        if [[ "$age" -gt "$oldest_age" ]]; then
          oldest_age="$age"
        fi
      done < <(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null || true)
      
      if [[ "$stuck_count" -gt 0 ]]; then
        oldest_age_str="$(format_age "$oldest_age")"
        if [[ -z "$criticals" ]]; then
          criticals="$queue_name: $stuck_count stuck task(s) (oldest: ${oldest_age_str})"
        else
          criticals="$criticals"$'\n'"$queue_name: $stuck_count stuck task(s) (oldest: ${oldest_age_str})"
        fi
        health_status="critical"
        
        # collect stuck task details
        while IFS= read -r task_file; do
          [[ -z "$task_file" ]] && continue
          [[ ! -f "$task_file" ]] && continue
          
          age="$(get_task_age "$task_file")"
          if [[ "$age" -gt "$stuck_threshold" ]]; then
            task_name="$(basename "$task_file")"
            task_age_str="$(format_age "$age")"
            if [[ -z "$stuck_tasks_list" ]]; then
              stuck_tasks_list="${queue_name}: ${task_name} (${task_age_str})"
            else
              stuck_tasks_list="$stuck_tasks_list"$'\n'"${queue_name}: ${task_name} (${task_age_str})"
            fi
          fi
        done < <(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null || true)
      elif [[ "$oldest_age" -gt "$warning_threshold" ]]; then
        oldest_age_str="$(format_age "$oldest_age")"
        if [[ -z "$warnings" ]]; then
          warnings="$queue_name: oldest task is ${oldest_age_str} old"
        else
          warnings="$warnings"$'\n'"$queue_name: oldest task is ${oldest_age_str} old"
        fi
        if [[ "$health_status" == "healthy" ]]; then
          health_status="warning"
        fi
      fi
    fi
  done
  
  # check for queue imbalances
  if [[ "$planner_pending" -eq 0 ]] && [[ "$subplanner_pending" -gt 10 ]]; then
    if [[ -z "$warnings" ]]; then
      warnings="planner_queue empty but subplanner_queue has $subplanner_pending tasks (upstream bottleneck)"
    else
      warnings="$warnings"$'\n'"planner_queue empty but subplanner_queue has $subplanner_pending tasks (upstream bottleneck)"
    fi
    if [[ "$health_status" == "healthy" ]]; then
      health_status="warning"
    fi
  fi
  
  if [[ "$subplanner_pending" -eq 0 ]] && [[ "$worker_pending" -gt 20 ]]; then
    if [[ -z "$warnings" ]]; then
      warnings="subplanner_queue empty but queue has $worker_pending tasks (upstream bottleneck)"
    else
      warnings="$warnings"$'\n'"subplanner_queue empty but queue has $worker_pending tasks (upstream bottleneck)"
    fi
    if [[ "$health_status" == "healthy" ]]; then
      health_status="warning"
    fi
  fi
  
  if [[ "$worker_pending" -eq 0 ]] && [[ "$judge_pending" -gt 5 ]]; then
    if [[ -z "$warnings" ]]; then
      warnings="queue empty but judge_queue has $judge_pending tasks (judge bottleneck)"
    else
      warnings="$warnings"$'\n'"queue empty but judge_queue has $judge_pending tasks (judge bottleneck)"
    fi
    if [[ "$health_status" == "healthy" ]]; then
      health_status="warning"
    fi
  fi
  
  # check for zero processing rates with pending tasks (potential agent issues)
  if [[ "$planner_pending" -gt 0 ]] && [[ "$planner_rate" -eq 0 ]]; then
    if [[ -z "$warnings" ]]; then
      warnings="planner_queue has $planner_pending pending tasks but zero processing rate (agent may be stuck)"
    else
      warnings="$warnings"$'\n'"planner_queue has $planner_pending pending tasks but zero processing rate (agent may be stuck)"
    fi
    if [[ "$health_status" == "healthy" ]]; then
      health_status="warning"
    fi
  fi
  
  if [[ "$subplanner_pending" -gt 0 ]] && [[ "$subplanner_rate" -eq 0 ]]; then
    if [[ -z "$warnings" ]]; then
      warnings="subplanner_queue has $subplanner_pending pending tasks but zero processing rate (agent may be stuck)"
    else
      warnings="$warnings"$'\n'"subplanner_queue has $subplanner_pending pending tasks but zero processing rate (agent may be stuck)"
    fi
    if [[ "$health_status" == "healthy" ]]; then
      health_status="warning"
    fi
  fi
  
  if [[ "$worker_pending" -gt 0 ]] && [[ "$worker_rate" -eq 0 ]]; then
    if [[ -z "$warnings" ]]; then
      warnings="queue has $worker_pending pending tasks but zero processing rate (agent may be stuck)"
    else
      warnings="$warnings"$'\n'"queue has $worker_pending pending tasks but zero processing rate (agent may be stuck)"
    fi
    if [[ "$health_status" == "healthy" ]]; then
      health_status="warning"
    fi
  fi
  
  if [[ "$judge_pending" -gt 0 ]] && [[ "$judge_rate" -eq 0 ]]; then
    if [[ -z "$warnings" ]]; then
      warnings="judge_queue has $judge_pending pending tasks but zero processing rate (judge may be stuck)"
    else
      warnings="$warnings"$'\n'"judge_queue has $judge_pending pending tasks but zero processing rate (judge may be stuck)"
    fi
    if [[ "$health_status" == "healthy" ]]; then
      health_status="warning"
    fi
  fi
  
  # check for processing bottlenecks (high pending with low rate relative to queue size)
  if [[ "$planner_pending" -gt 5 ]] && [[ "$planner_rate" -gt 0 ]]; then
    local estimated_hours
    estimated_hours=$((planner_pending / planner_rate))
    if [[ "$estimated_hours" -gt 2 ]]; then
      if [[ -z "$warnings" ]]; then
        warnings="planner_queue bottleneck: $planner_pending tasks at ${planner_rate}/hr = ~${estimated_hours}h to clear (consider increasing throughput)"
      else
        warnings="$warnings"$'\n'"planner_queue bottleneck: $planner_pending tasks at ${planner_rate}/hr = ~${estimated_hours}h to clear (consider increasing throughput)"
      fi
      if [[ "$health_status" == "healthy" ]]; then
        health_status="warning"
      fi
    fi
  fi
  
  if [[ "$subplanner_pending" -gt 5 ]] && [[ "$subplanner_rate" -gt 0 ]]; then
    local estimated_hours
    estimated_hours=$((subplanner_pending / subplanner_rate))
    if [[ "$estimated_hours" -gt 2 ]]; then
      if [[ -z "$warnings" ]]; then
        warnings="subplanner_queue bottleneck: $subplanner_pending tasks at ${subplanner_rate}/hr = ~${estimated_hours}h to clear (consider increasing throughput)"
      else
        warnings="$warnings"$'\n'"subplanner_queue bottleneck: $subplanner_pending tasks at ${subplanner_rate}/hr = ~${estimated_hours}h to clear (consider increasing throughput)"
      fi
      if [[ "$health_status" == "healthy" ]]; then
        health_status="warning"
      fi
    fi
  fi
  
  if [[ "$worker_pending" -gt 10 ]] && [[ "$worker_rate" -gt 0 ]]; then
    local estimated_hours
    estimated_hours=$((worker_pending / worker_rate))
    if [[ "$estimated_hours" -gt 2 ]]; then
      if [[ -z "$warnings" ]]; then
        warnings="queue bottleneck: $worker_pending tasks at ${worker_rate}/hr = ~${estimated_hours}h to clear (consider increasing throughput)"
      else
        warnings="$warnings"$'\n'"queue bottleneck: $worker_pending tasks at ${worker_rate}/hr = ~${estimated_hours}h to clear (consider increasing throughput)"
      fi
      if [[ "$health_status" == "healthy" ]]; then
        health_status="warning"
      fi
    fi
  fi
  
  if [[ "$judge_pending" -gt 3 ]] && [[ "$judge_rate" -gt 0 ]]; then
    local estimated_hours
    estimated_hours=$((judge_pending / judge_rate))
    if [[ "$estimated_hours" -gt 1 ]]; then
      if [[ -z "$warnings" ]]; then
        warnings="judge_queue bottleneck: $judge_pending tasks at ${judge_rate}/hr = ~${estimated_hours}h to clear (judge may need more frequent triggers)"
      else
        warnings="$warnings"$'\n'"judge_queue bottleneck: $judge_pending tasks at ${judge_rate}/hr = ~${estimated_hours}h to clear (judge may need more frequent triggers)"
      fi
      if [[ "$health_status" == "healthy" ]]; then
        health_status="warning"
      fi
    fi
  fi
  
  # show health status
  case "$health_status" in
    healthy) echo "  ✅ Status: HEALTHY" ;;
    warning) echo "  ⚠️  Status: WARNING" ;;
    critical) echo "  ❌ Status: CRITICAL" ;;
  esac
  echo
  
  # show processing rates
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
  
  # show warnings
  if [[ -n "$warnings" ]]; then
    echo "  ⚠️  Warnings:"
    echo "$warnings" | while IFS= read -r warning; do
      [[ -z "$warning" ]] && continue
      echo "     - $warning"
    done
    echo
    echo "  Recommendations:"
    echo "     1. check processing rates above - zero rates indicate agent issues"
    echo "     2. verify launchd jobs are running: ./agent_factory/monitor.sh --launchd"
    echo "     3. check agent logs for errors: ./agent_factory/monitor.sh --logs"
    echo "     4. review detailed queue status: ./agent_factory/queue_status.sh"
    echo "     5. check for blocker tickets: ./agent_factory/monitor.sh --blockers"
    echo "     6. restart agents if needed: ./agent_factory/launchd_stop.sh && ./agent_factory/setup.sh"
    echo
  fi
  
  # show critical issues
  if [[ -n "$criticals" ]]; then
    echo "  ❌ Critical issues:"
    echo "$criticals" | while IFS= read -r critical; do
      [[ -z "$critical" ]] && continue
      echo "     - $critical"
    done
    echo
    
    # show stuck task details if available
    if [[ -n "$stuck_tasks_list" ]]; then
      echo "  Stuck task details:"
      echo "$stuck_tasks_list" | while IFS= read -r stuck_task; do
        [[ -z "$stuck_task" ]] && continue
        echo "     - $stuck_task"
      done
      echo
    fi
    
    echo "  Immediate actions:"
    echo "     1. check agent logs for errors:"
    echo "        ./agent_factory/monitor.sh --logs"
    echo "     2. verify launchd jobs are running:"
    echo "        ./agent_factory/monitor.sh --launchd"
    echo "     3. view stuck tasks with details:"
    echo "        ./agent_factory/monitor.sh --queues"
    echo "     4. check for blocker tickets:"
    echo "        ./agent_factory/monitor.sh --blockers"
    echo "     5. restart agents if needed:"
    echo "        ./agent_factory/launchd_stop.sh && ./agent_factory/setup.sh"
    echo "     6. requeue failed tasks if appropriate:"
    echo "        ./agent_factory/requeue_failed.sh"
    echo "     7. investigate specific stuck tasks:"
    echo "        ./agent_factory/log_search.sh --task <task_name>"
    echo
  fi
}

show_logs() {
  print_header "LATEST AGENT RUNS"
  
  log_dir="${REPO_ROOT}/${AGENT_RUNS_LOG_DIR:-logs/agent_runs}"
  echo "  Log dir: $log_dir"
  if [[ -n "${LOG_LATEST_SYMLINK_NAME:-}" ]] && [[ -L "${log_dir}/${LOG_LATEST_SYMLINK_NAME}" ]]; then
    latest_target="$(readlink "${log_dir}/${LOG_LATEST_SYMLINK_NAME}" 2>/dev/null || echo "")"
    if [[ -n "$latest_target" ]]; then
      echo "  Latest: ${LOG_LATEST_SYMLINK_NAME} -> ${latest_target}"
    fi
  fi
  echo
  if [[ ! -d "$log_dir" ]]; then
    echo "  No agent runs yet"
    echo
    return
  fi
  
  latest_runs="$(find "$log_dir" -type f -name '*.log' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -n 5 || true)"
  
  if [[ -z "$latest_runs" ]]; then
    echo "  No agent runs yet"
    echo
    return
  fi
  
  count=0
  while IFS= read -r log_file; do
    [[ -z "$log_file" ]] && continue
    [[ ! -f "$log_file" ]] && continue
    
    count=$((count + 1))
    log_name="$(basename "$log_file")"
    log_size="$(wc -l < "$log_file" | tr -d ' ')"
    log_time="$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$log_file" 2>/dev/null || stat -c "%y" "$log_file" 2>/dev/null | cut -d' ' -f1-2 || echo 'unknown')"
    
    # check for errors
    if grep -q "NEED-INFO\|empty agent output\|failed" "$log_file" 2>/dev/null; then
      status="❌"
    elif [[ "$log_size" -gt 100 ]]; then
      status="✅"
    else
      status="⚠️ "
    fi
    
    echo "  $status [$count] $log_name"
    echo "      $log_time | $log_size lines"
    
    # show last few lines if small
    if [[ "$log_size" -lt 20 ]]; then
      echo "      └─ $(tail -n 3 "$log_file" 2>/dev/null | head -n 1 | cut -c1-60)..."
    fi
  done <<< "$latest_runs"
  
  if [[ "$count" -eq 0 ]]; then
    echo "  No agent runs found"
  fi
  echo
}

show_log_stats() {
  print_header "LOG STATISTICS"
  
  log_dir="${REPO_ROOT}/${AGENT_RUNS_LOG_DIR:-logs/agent_runs}"
  if [[ ! -d "$log_dir" ]]; then
    echo "  No log directory found"
    echo
    return
  fi
  
  # source config for retention settings
  if [[ -f "${AGENT_FACTORY_DIR}/config.sh" ]]; then
    source "${AGENT_FACTORY_DIR}/config.sh" 2>/dev/null || true
  fi
  
  # count files
  uncompressed_count="$(find "$log_dir" -type f -name '*.log' 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
  compressed_count="$(find "$log_dir" -type f -name '*.log.gz' 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
  total_count=$((uncompressed_count + compressed_count))
  
  # calculate disk usage more accurately
  uncompressed_size_kb=0
  compressed_size_kb=0
  
  while IFS= read -r log_file; do
    [[ -z "$log_file" ]] && continue
    [[ ! -f "$log_file" ]] && continue
    
    if [[ "$log_file" == *.gz ]]; then
      if [[ "$(uname)" == "Darwin" ]]; then
        file_size="$(stat -f "%z" "$log_file" 2>/dev/null || echo 0)"
      else
        file_size="$(stat -c "%s" "$log_file" 2>/dev/null || echo 0)"
      fi
      compressed_size_kb=$((compressed_size_kb + file_size / 1024))
    else
      if [[ "$(uname)" == "Darwin" ]]; then
        file_size="$(stat -f "%z" "$log_file" 2>/dev/null || echo 0)"
      else
        file_size="$(stat -c "%s" "$log_file" 2>/dev/null || echo 0)"
      fi
      uncompressed_size_kb=$((uncompressed_size_kb + file_size / 1024))
    fi
  done < <(find "$log_dir" -type f \( -name '*.log' -o -name '*.log.gz' \) -print0 2>/dev/null || true)
  
  total_size_kb=$((uncompressed_size_kb + compressed_size_kb))
  
  # format sizes
  format_size() {
    local kb="$1"
    if [[ "$kb" -lt 1024 ]]; then
      echo "${kb}KB"
    elif [[ "$kb" -lt 1048576 ]]; then
      echo "$((kb / 1024))MB"
    else
      echo "$((kb / 1048576))GB"
    fi
  }
  
  echo "  Total logs: $total_count ($uncompressed_count uncompressed, $compressed_count compressed)"
  echo "  Disk usage: $(format_size $total_size_kb) (uncompressed: $(format_size $uncompressed_size_kb), compressed: $(format_size $compressed_size_kb))"
  
  retention_count="${LOG_RETENTION_COUNT:-100}"
  compression_enabled="${LOG_COMPRESSION_ENABLED:-1}"
  compression_age_days="${LOG_COMPRESSION_AGE_DAYS:-7}"
  deletion_age_days="${LOG_DELETION_AGE_DAYS:-90}"
  max_directory_size_mb="${LOG_MAX_DIRECTORY_SIZE_MB:-0}"
  
  # check log health
  health_status="healthy"
  warnings=""
  
  # check size-based rotation threshold
  if [[ "$max_directory_size_mb" -gt 0 ]]; then
    total_size_mb=$((total_size_kb / 1024))
    if [[ "$total_size_mb" -gt "$max_directory_size_mb" ]]; then
      health_status="critical"
      excess_mb=$((total_size_mb - max_directory_size_mb))
      warnings="${warnings}${warnings:+$'\n'}  ❌ log directory size (${total_size_mb}MB) exceeds limit (${max_directory_size_mb}MB) by ${excess_mb}MB"
    elif [[ "$total_size_mb" -gt $((max_directory_size_mb * 80 / 100)) ]]; then
      if [[ "$health_status" == "healthy" ]]; then
        health_status="warning"
      fi
      warnings="${warnings}${warnings:+$'\n'}  ⚠️  log directory size (${total_size_mb}MB) approaching limit (${max_directory_size_mb}MB)"
    fi
  fi
  
  if [[ "$uncompressed_count" -gt $((retention_count * 2)) ]]; then
    health_status="critical"
    excess=$((uncompressed_count - retention_count))
    warnings="${warnings}${warnings:+$'\n'}  ❌ $excess uncompressed logs exceed retention limit (${retention_count})"
  elif [[ "$uncompressed_count" -gt "$retention_count" ]]; then
    health_status="warning"
    excess=$((uncompressed_count - retention_count))
    warnings="${warnings}${warnings:+$'\n'}  ⚠️  $excess uncompressed logs exceed retention limit (${retention_count})"
  fi
  
  # check for old compressed logs that should be deleted
  now_epoch="$(date +%s)"
  deletion_threshold=$((now_epoch - deletion_age_days * 86400))
  old_compressed=0
  
  while IFS= read -r compressed_file; do
    [[ -z "$compressed_file" ]] && continue
    [[ ! -f "$compressed_file" ]] && continue
    
    if [[ "$(uname)" == "Darwin" ]]; then
      file_mtime="$(stat -f "%m" "$compressed_file" 2>/dev/null || echo "$now_epoch")"
    else
      file_mtime="$(stat -c "%Y" "$compressed_file" 2>/dev/null || echo "$now_epoch")"
    fi
    
    if [[ "$file_mtime" -lt "$deletion_threshold" ]]; then
      old_compressed=$((old_compressed + 1))
    fi
  done < <(find "$log_dir" -type f -name '*.log.gz' -print0 2>/dev/null || true)
  
  if [[ "$old_compressed" -gt 0 ]]; then
    if [[ "$health_status" == "healthy" ]]; then
      health_status="warning"
    fi
    warnings="${warnings}${warnings:+$'\n'}  ⚠️  $old_compressed compressed logs older than ${deletion_age_days} days (eligible for deletion)"
  fi
  
  # show health status
  case "$health_status" in
    healthy)
      echo "  ✅ log rotation: healthy ($uncompressed_count/$retention_count uncompressed)"
      ;;
    warning)
      echo "  ⚠️  log rotation: needs attention"
      echo "$warnings"
      echo "     run: ./agent_factory/log_rotate.sh"
      ;;
    critical)
      echo "  ❌ log rotation: critical"
      echo "$warnings"
      echo "     run: ./agent_factory/log_rotate.sh"
      ;;
  esac
  
  # show rotation settings
  echo
  echo "  Rotation settings:"
  echo "     retention: $retention_count uncompressed logs"
  echo "     compression: $([ "$compression_enabled" == "1" ] && echo "enabled" || echo "disabled")"
  if [[ "$compression_enabled" == "1" ]]; then
    echo "     compress after: ${compression_age_days} days"
  fi
  echo "     delete after: ${deletion_age_days} days"
  if [[ "$max_directory_size_mb" -gt 0 ]]; then
    echo "     max directory size: ${max_directory_size_mb}MB"
  fi
  echo
}

show_git() {
  print_header "GIT STATUS"
  
  if ! command -v git &>/dev/null; then
    echo "  Git not available"
    echo
    return
  fi
  
  if [[ ! -d .git ]]; then
    echo "  Not a git repository"
    echo
    return
  fi
  
  # uncommitted changes
  unstaged="$(git status --porcelain 2>/dev/null | grep -c '^[^ ]' || echo 0)"
  staged="$(git status --porcelain 2>/dev/null | grep -c '^[^ ]' | grep -c '^[MAD]' || echo 0)"
  
  if [[ "$unstaged" -gt 0 ]] || [[ "$staged" -gt 0 ]]; then
    echo "  📝 Uncommitted changes:"
    git status --short 2>/dev/null | head -n 10 | sed 's/^/     /'
    if [[ "$(git status --short 2>/dev/null | wc -l)" -gt 10 ]]; then
      echo "     ... ($(git status --short 2>/dev/null | wc -l | tr -d ' ') total files)"
    fi
  else
    echo "  ✅ Working directory clean"
  fi
  
  # last commit
  last_commit="$(git log -1 --format="%h - %s (%ar)" 2>/dev/null || echo 'no commits')"
  echo "  📌 Last commit: $last_commit"
  echo
}

show_launchd() {
  print_header "LAUNCHD JOBS"
  
  if [[ "$(uname)" != "Darwin" ]]; then
    echo "  macOS only (launchd)"
    echo
    return
  fi
  
  user_id="$(id -u)"
  jobs="$(launchctl list 2>/dev/null | grep -E "com\..*\.agent_factory\.(primary_planner|sub_planner|worker|judge|judge_trigger)" || true)"
  
  if [[ -z "$jobs" ]]; then
    echo "  No agent jobs found in launchd"
    echo "  (jobs should match: com.*.agent_factory.(primary_planner|sub_planner|worker|judge|judge_trigger))"
    echo
    echo "  If you have pending tasks, start background jobs with:"
    echo "    ./ops/agent_factory/start.sh"
    echo
    return
  fi
  
  while IFS= read -r job_line; do
    [[ -z "$job_line" ]] && continue
    
    job_pid="$(echo "$job_line" | awk '{print $1}')"
    job_label="$(echo "$job_line" | awk '{print $3}')"
    
    if [[ "$job_pid" == "-" ]] || [[ "$job_pid" == "0" ]]; then
      status="⏸️  stopped"
    else
      status="▶️  running (PID: $job_pid)"
    fi
    
    echo "  $status $job_label"
    
    # get more details
    job_info="$(launchctl print "gui/$user_id/$job_label" 2>/dev/null || true)"
    if [[ -n "$job_info" ]]; then
      last_exit="$(echo "$job_info" | grep "last exit code" | awk '{print $NF}' || echo 'unknown')"
      state="$(echo "$job_info" | grep "state = " | awk '{print $NF}' || echo 'unknown')"
      echo "      state: $state, last exit: $last_exit"
    fi
  done <<< "$jobs"
  
  if [[ -z "$jobs" ]]; then
    echo "  No active jobs"
  fi
  echo
}

show_goal() {
  print_header "GOAL FILE STATUS"
  
  if [[ -f goal.md ]]; then
    goal_modified="$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" goal.md 2>/dev/null || stat -c "%y" goal.md 2>/dev/null | cut -d' ' -f1-2 || echo 'unknown')"
    goal_lines="$(wc -l < goal.md | tr -d ' ')"
    
    echo "  ✅ goal.md exists"
    echo "     Modified: $goal_modified"
    echo "     Size: $goal_lines lines"
    
    # show first objective line if exists
    objective="$(grep -A 2 "^## Current Objective" goal.md 2>/dev/null | head -n 3 | tail -n 1 | sed 's/^[[:space:]]*//' || true)"
    if [[ -n "$objective" ]] && [[ "$objective" != "Describe the primary objective"* ]]; then
      echo "     Objective: ${objective:0:60}..."
    fi
  else
    echo "  ⚠️  goal.md not found"
    echo "     Create it with: cp agent_factory/goal_template.md goal.md"
  fi
  echo
}

show_blockers() {
  print_header "BLOCKERS"

  canonical_blocker=".agent_factory_state/judge_blocker.md"
  planner_notice="tasks/planner_queue/00_judge_blocker_notice.md"

  if [[ -f "$canonical_blocker" ]]; then
    blocker_time="$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$canonical_blocker" 2>/dev/null || stat -c "%y" "$canonical_blocker" 2>/dev/null | cut -d' ' -f1-2 || echo 'unknown')"
    summary="$(awk 'BEGIN{in=0} /^## Summary/{in=1; next} in==1 && NF{print; exit}' "$canonical_blocker" 2>/dev/null || true)"
    echo "  ❌ judge blocker: $canonical_blocker"
    echo "     Updated: $blocker_time"
    if [[ -n "$summary" ]]; then
      echo "     Summary: ${summary:0:90}"
    fi
    echo "     Preview:"
    sed -n '1,30p' "$canonical_blocker" 2>/dev/null | sed 's/^/       /'
    echo
  else
    echo "  ✅ no canonical judge blocker found"
    echo
  fi

  if [[ -f "$planner_notice" ]]; then
    notice_time="$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$planner_notice" 2>/dev/null || stat -c "%y" "$planner_notice" 2>/dev/null | cut -d' ' -f1-2 || echo 'unknown')"
    echo "  ℹ️  planner notice present: $planner_notice (updated: $notice_time)"
    echo
  fi
}

show_timeout_stats() {
  print_header "TIMEOUT STATISTICS"

  # check timeout configuration
  source "${AGENT_FACTORY_DIR}/config.sh" 2>/dev/null || true
  timeout_secs="${AGENT_EXECUTION_TIMEOUT_SECS:-1800}"
  timeout_min=$((timeout_secs / 60))
  
  echo "  Configuration:"
  echo "     Timeout: ${timeout_secs}s (${timeout_min}m)"
  echo "     Config: AGENT_EXECUTION_TIMEOUT_SECS in agent_factory/config.sh"
  echo

  # count timeouts from provenance files
  timeout_count=0
  total_failed=0
  if [[ -d tasks ]]; then
    while IFS= read -r prov_file; do
      [[ -z "$prov_file" ]] && continue
      [[ ! -f "$prov_file" ]] && continue
      
      if grep -q '"error_code":\s*"timeout"' "$prov_file" 2>/dev/null; then
        timeout_count=$((timeout_count + 1))
      fi
      if grep -q '"status":\s*"failed"' "$prov_file" 2>/dev/null; then
        total_failed=$((total_failed + 1))
      fi
    done < <(find tasks -type f -name '*.provenance.json' 2>/dev/null || true)
  fi

  if [[ "$timeout_count" -gt 0 ]]; then
    echo "  ⚠️  Timeout events: $timeout_count"
    if [[ "$total_failed" -gt 0 ]]; then
      timeout_pct=$((timeout_count * 100 / total_failed))
      echo "     ${timeout_pct}% of failed tasks ($timeout_count/$total_failed)"
    fi
    echo
    echo "  Recent timeout tasks:"
    count=0
    while IFS= read -r prov_file; do
      [[ -z "$prov_file" ]] && continue
      [[ ! -f "$prov_file" ]] && continue
      [[ "$count" -ge 5 ]] && break
      
      if grep -q '"error_code":\s*"timeout"' "$prov_file" 2>/dev/null; then
        ticket_name="$(grep '"ticket_name"' "$prov_file" 2>/dev/null | head -1 | sed 's/.*"ticket_name":\s*"\([^"]*\)".*/\1/' || echo 'unknown')"
        duration="$(grep '"execution_duration_secs"' "$prov_file" 2>/dev/null | head -1 | sed 's/.*"execution_duration_secs":\s*\([0-9]*\).*/\1/' || echo '0')"
        duration_min=$((duration / 60))
        echo "     - $ticket_name (${duration_min}m, exceeded ${timeout_min}m timeout)"
        count=$((count + 1))
      fi
    done < <(find tasks -type f -name '*.provenance.json' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -n 20 || true)
    echo
    echo "  View all timeouts:"
    echo "     ./agent_factory/provenance_summary.sh --failed-only | grep timeout"
    echo
  else
    echo "  ✅ No timeout events detected"
    echo
  fi

  # check for long-running tasks approaching timeout
  long_running=0
  if [[ -d tasks ]]; then
    for queue_dir in tasks/{planner_queue,subplanner_queue,queue,judge_queue}; do
      [[ ! -d "$queue_dir" ]] && continue
      while IFS= read -r task_file; do
        [[ -z "$task_file" ]] && continue
        [[ ! -f "$task_file" ]] && continue
        
        # check if there's a provenance file indicating this task is running
        base_name="$(basename "$task_file" .md)"
        prov_file="$(find "$queue_dir/processed" -name "${base_name}.*.provenance.json" -type f 2>/dev/null | head -1 || true)"
        if [[ -n "$prov_file" ]] && [[ -f "$prov_file" ]]; then
          # check if task started but hasn't completed (status might not be set yet)
          if ! grep -q '"status":\s*"\(success\|failed\)"' "$prov_file" 2>/dev/null; then
            start_ts="$(grep '"start_ts_utc"' "$prov_file" 2>/dev/null | head -1 | sed 's/.*"start_ts_utc":\s*"\([^"]*\)".*/\1/' || echo '')"
            if [[ -n "$start_ts" ]]; then
              # calculate elapsed time (simplified - would need proper date parsing)
              long_running=$((long_running + 1))
            fi
          fi
        fi
      done < <(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null || true)
    done
  fi

  # check for tasks in logs that show timeout warnings
  log_dir="${REPO_ROOT}/${AGENT_RUNS_LOG_DIR:-logs/agent_runs}"
  timeout_logs=""
  if [[ -d "$log_dir" ]]; then
    timeout_logs="$(find "$log_dir" -type f -name '*.log' -print0 2>/dev/null | xargs -0 grep -l "TIMEOUT:" 2>/dev/null | wc -l | tr -d ' ' || echo "0")"
  fi

  if [[ "$timeout_logs" -gt 0 ]]; then
    echo "  ⚠️  Timeout events in logs: $timeout_logs"
    echo "     View: ./agent_factory/log_search.sh --grep 'TIMEOUT'"
    echo
  fi

  # identify pending tasks older than timeout threshold
  long_running_tasks=""
  if [[ -d tasks ]]; then
    for queue_dir in tasks/{planner_queue,subplanner_queue,queue,judge_queue}; do
      [[ ! -d "$queue_dir" ]] && continue
      while IFS= read -r task_file; do
        [[ -z "$task_file" ]] && continue
        [[ ! -f "$task_file" ]] && continue

        age="$(get_task_age "$task_file")"
        if [[ "$age" -ge "$timeout_secs" ]]; then
          task_name="$(basename "$task_file")"
          age_str="$(format_age "$age")"
          if [[ -z "$long_running_tasks" ]]; then
            long_running_tasks="${queue_dir}: ${task_name} (${age_str})"
          else
            long_running_tasks="$long_running_tasks"$'\n'"${queue_dir}: ${task_name} (${age_str})"
          fi
        fi
      done < <(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null || true)
    done
  fi

  if [[ -n "$long_running_tasks" ]]; then
    echo "  ⚠️  Pending tasks older than timeout threshold:"
    echo "$long_running_tasks" | while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      echo "     - $entry"
    done
    echo
  fi
}

show_failed_tasks() {
  print_header "FAILURE SIGNALS"

  log_dir="${REPO_ROOT}/${AGENT_RUNS_LOG_DIR:-logs/agent_runs}"
  if [[ ! -d "$log_dir" ]]; then
    echo "  No agent runs yet"
    echo
    return
  fi

  failed_logs="$(find "$log_dir" -type f -name '*.log' -print0 2>/dev/null | xargs -0 grep -l -E "NEED-INFO|empty agent output|rate limit|ActionRequiredError|failed to process|TIMEOUT:" 2>/dev/null | head -n 10 || true)"

  if [[ -z "$failed_logs" ]]; then
    echo "  ✅ No failure signals detected in recent logs"
    echo
    return
  fi

  echo "  ❌ Logs with failure signals (showing up to 10):"
  while IFS= read -r log_file; do
    [[ -z "$log_file" ]] && continue
    echo "     - $(basename "$log_file")"
  done <<< "$failed_logs"

  echo
  echo "  Requeue candidates: ./agent_factory/restart.sh"
  echo
}

main() {
  clear 2>/dev/null || true
  echo
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║                    AGENT FACTORY STATUS MONITOR                                ║"
  echo "║                    $(date '+%Y-%m-%d %H:%M:%S')                                    ║"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo
  
  [[ "$SHOW_GOAL" == "1" ]] && show_goal
  [[ "$SHOW_BLOCKERS" == "1" ]] && show_blockers
  [[ "$SHOW_QUEUES" == "1" ]] && show_queues
  if [[ "$SHOW_HEALTH" == "1" ]] || [[ "$SHOW_QUEUES" == "1" ]]; then
    show_queue_health
  fi
  [[ "$SHOW_TIMEOUTS" == "1" ]] && show_timeout_stats
  [[ "$SHOW_LOGS" == "1" ]] && show_logs
  [[ "$SHOW_LOGS" == "1" ]] && show_log_stats
  [[ "$SHOW_GIT" == "1" ]] && show_git
  [[ "$SHOW_LAUNCHD" == "1" ]] && show_launchd
  [[ "$SHOW_QUEUES" == "1" ]] && show_failed_tasks
  
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Use: ./agent_factory/monitor.sh --watch (auto-refresh every 2s)"
  echo "       ./agent_factory/monitor.sh --queues (queues only)"
  echo "       ./agent_factory/monitor.sh --health (health check only)"
  echo "       ./agent_factory/monitor.sh --timeouts (timeout statistics only)"
  echo "       ./agent_factory/monitor.sh --logs (logs only)"
  echo "       ./agent_factory/restart.sh (requeue failed tasks)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

if [[ "$WATCH" == "1" ]]; then
  while true; do
    main
    sleep "${MONITOR_REFRESH_INTERVAL_SECS:-2}"
  done
else
  main
fi
