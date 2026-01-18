#!/usr/bin/env bash
set -euo pipefail

# monitor.sh - Real-time status monitoring for agent factory
#
# Usage: ./agent_factory/monitor.sh [--watch] [--queues] [--logs] [--git] [--launchd] [--all]

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WATCH="${1:-}"
SHOW_QUEUES="${SHOW_QUEUES:-1}"
SHOW_LOGS="${SHOW_LOGS:-1}"
SHOW_GIT="${SHOW_GIT:-1}"
SHOW_LAUNCHD="${SHOW_LAUNCHD:-1}"
SHOW_GOAL="${SHOW_GOAL:-1}"

# parse arguments
if [[ "${1:-}" == "--watch" ]]; then
  WATCH="1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --queues) SHOW_QUEUES="1"; SHOW_LOGS="0"; SHOW_GIT="0"; SHOW_LAUNCHD="0"; SHOW_GOAL="0"; shift ;;
    --logs) SHOW_LOGS="1"; SHOW_QUEUES="0"; SHOW_GIT="0"; SHOW_LAUNCHD="0"; SHOW_GOAL="0"; shift ;;
    --git) SHOW_GIT="1"; SHOW_QUEUES="0"; SHOW_LOGS="0"; SHOW_LAUNCHD="0"; SHOW_GOAL="0"; shift ;;
    --launchd) SHOW_LAUNCHD="1"; SHOW_QUEUES="0"; SHOW_LOGS="0"; SHOW_GIT="0"; SHOW_GOAL="0"; shift ;;
    --all) SHOW_QUEUES="1"; SHOW_LOGS="1"; SHOW_GIT="1"; SHOW_LAUNCHD="1"; SHOW_GOAL="1"; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

print_header() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

show_queues() {
  print_header "QUEUE STATUS"
  
  for queue_dir in tasks/{planner_queue,subplanner_queue,queue,judge_queue}; do
    if [[ ! -d "$queue_dir" ]]; then
      continue
    fi
    
    queue_name="$(basename "$queue_dir")"
    pending="$(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    if [[ -d "$queue_dir/processed" ]]; then
      processed="$(find "$queue_dir/processed" -type f 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    else
      processed="0"
    fi
    
    if [[ "$pending" -gt 0 ]]; then
      echo "  📋 $queue_name: $pending pending, $processed processed"
      if [[ "$pending" -le 5 ]]; then
        echo "     Next: $(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | head -n 1 | xargs basename 2>/dev/null || echo 'none')"
      fi
    else
      echo "  ✅ $queue_name: empty ($processed processed)"
    fi
  done
  echo
}

show_logs() {
  print_header "LATEST AGENT RUNS"
  
  log_dir="logs/agent_runs"
  if [[ ! -d "$log_dir" ]]; then
    echo "  No agent runs yet"
    echo
    return
  fi
  
  latest_runs="$(ls -1t "$log_dir"/*.log 2>/dev/null | head -n 5 || true)"
  
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

show_failed_tasks() {
  print_header "FAILURE SIGNALS"

  log_dir="logs/agent_runs"
  if [[ ! -d "$log_dir" ]]; then
    echo "  No agent runs yet"
    echo
    return
  fi

  failed_logs="$(find "$log_dir" -type f -name '*.log' -print0 2>/dev/null | xargs -0 grep -l -E "NEED-INFO|empty agent output|rate limit|ActionRequiredError|failed to process" 2>/dev/null | head -n 10 || true)"

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
  [[ "$SHOW_QUEUES" == "1" ]] && show_queues
  [[ "$SHOW_LOGS" == "1" ]] && show_logs
  [[ "$SHOW_GIT" == "1" ]] && show_git
  [[ "$SHOW_LAUNCHD" == "1" ]] && show_launchd
  [[ "$SHOW_QUEUES" == "1" ]] && show_failed_tasks
  
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Use: ./agent_factory/monitor.sh --watch (auto-refresh every 2s)"
  echo "       ./agent_factory/monitor.sh --queues (queues only)"
  echo "       ./agent_factory/monitor.sh --logs (logs only)"
  echo "       ./agent_factory/restart.sh (requeue failed tasks)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

if [[ "$WATCH" == "1" ]]; then
  while true; do
    main
    sleep 2
  done
else
  main
fi
