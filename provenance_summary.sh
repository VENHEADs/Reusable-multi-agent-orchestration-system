#!/usr/bin/env bash
set -euo pipefail

# provenance summary query script
# provides summary statistics and querying capabilities for provenance files

usage() {
  cat <<'EOF'
usage: provenance_summary.sh [options]

options:
  --queue-dir <dir>        filter by queue directory (e.g., tasks/queue)
  --status <status>        filter by status (success, failed)
  --model <model>          filter by agent model used
  --ticket <name>          filter by ticket name
  --failed-only            show only failed tasks
  --requeued-only          show only requeued tasks (requeue_attempt > 0)
  --timeout-only           show only timeout events
  --summary                show summary statistics only (default)
  --detailed               show detailed per-ticket information
  --json                   output as JSON
  --help                   show this help

examples:
  # show summary for all tasks
  ./agent_factory/provenance_summary.sh

  # show failed tasks only
  ./agent_factory/provenance_summary.sh --failed-only --detailed

  # show timeout events only
  ./agent_factory/provenance_summary.sh --timeout-only --detailed

  # show tasks that were requeued
  ./agent_factory/provenance_summary.sh --requeued-only --detailed

  # filter by queue
  ./agent_factory/provenance_summary.sh --queue-dir tasks/queue --detailed

  # filter by model
  ./agent_factory/provenance_summary.sh --model gpt-4 --detailed
EOF
}

queue_dir_filter=""
status_filter=""
model_filter=""
ticket_filter=""
failed_only="0"
requeued_only="0"
timeout_only="0"
summary_mode="1"
detailed_mode="0"
json_output="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --queue-dir)
      queue_dir_filter="$2"
      shift 2
      ;;
    --status)
      status_filter="$2"
      shift 2
      ;;
    --model)
      model_filter="$2"
      shift 2
      ;;
    --ticket)
      ticket_filter="$2"
      shift 2
      ;;
    --failed-only)
      failed_only="1"
      shift
      ;;
    --requeued-only)
      requeued_only="1"
      shift
      ;;
    --timeout-only)
      timeout_only="1"
      failed_only="1"
      shift
      ;;
    --summary)
      summary_mode="1"
      detailed_mode="0"
      shift
      ;;
    --detailed)
      detailed_mode="1"
      summary_mode="0"
      shift
      ;;
    --json)
      json_output="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

# process provenance files with python
python3 - "$queue_dir_filter" "$status_filter" "$model_filter" "$ticket_filter" "$failed_only" "$requeued_only" "$timeout_only" "$summary_mode" "$detailed_mode" "$json_output" <<'PY'
import json
import sys
from pathlib import Path
from collections import defaultdict
from datetime import datetime

queue_dir_filter = sys.argv[1] if len(sys.argv) > 1 else ""
status_filter = sys.argv[2] if len(sys.argv) > 2 else ""
model_filter = sys.argv[3] if len(sys.argv) > 3 else ""
ticket_filter = sys.argv[4] if len(sys.argv) > 4 else ""
failed_only = sys.argv[5] == "1" if len(sys.argv) > 5 else False
requeued_only = sys.argv[6] == "1" if len(sys.argv) > 6 else False
timeout_only = sys.argv[7] == "1" if len(sys.argv) > 7 else False
summary_mode = sys.argv[8] == "1" if len(sys.argv) > 8 else True
detailed_mode = sys.argv[9] == "1" if len(sys.argv) > 9 else False
json_output = sys.argv[10] == "1" if len(sys.argv) > 10 else False

# find all provenance files
provenance_files = []
if Path("tasks").exists():
    for prov_file in Path("tasks").rglob("*.provenance.json"):
        if prov_file.is_file():
            provenance_files.append(str(prov_file))

if not provenance_files:
    if json_output:
        print(json.dumps({"total": 0, "message": "no provenance files found"}))
    else:
        print("no provenance files found")
    sys.exit(0)

tasks = []
for prov_file in provenance_files:
    if not prov_file or not Path(prov_file).exists():
        continue
    try:
        with open(prov_file, 'r') as f:
            task = json.load(f)
            task['_provenance_file'] = prov_file
            tasks.append(task)
    except (json.JSONDecodeError, IOError):
        continue

# apply filters
filtered_tasks = []
for task in tasks:
    if queue_dir_filter and queue_dir_filter not in task.get('queue_dir', ''):
        continue
    if status_filter and task.get('status', '') != status_filter:
        continue
    if model_filter:
        model = task.get('agent_model', {}).get('final', '') or task.get('agent_model', {}).get('primary', '')
        if model_filter.lower() not in model.lower():
            continue
    if ticket_filter and ticket_filter not in task.get('ticket_name', ''):
        continue
    if failed_only and task.get('status', '') != 'failed':
        continue
    if requeued_only and task.get('requeue_attempt', 0) == 0:
        continue
    if timeout_only and task.get('error_code', '') != 'timeout':
        continue
    filtered_tasks.append(task)

if json_output:
    output = {
        'total': len(filtered_tasks),
        'tasks': filtered_tasks
    }
    print(json.dumps(output, indent=2))
    sys.exit(0)

if summary_mode:
    # calculate statistics
    total = len(filtered_tasks)
    successful = sum(1 for t in filtered_tasks if t.get('status') == 'success')
    failed = sum(1 for t in filtered_tasks if t.get('status') == 'failed')
    requeued = sum(1 for t in filtered_tasks if t.get('requeue_attempt', 0) > 0)
    
    # execution duration stats
    durations = [t.get('execution_duration_secs', 0) for t in filtered_tasks if t.get('execution_duration_secs', 0) > 0]
    avg_duration = sum(durations) / len(durations) if durations else 0
    min_duration = min(durations) if durations else 0
    max_duration = max(durations) if durations else 0
    
    # model usage stats
    model_counts = defaultdict(int)
    fallback_usage = 0
    for task in filtered_tasks:
        model_info = task.get('agent_model', {})
        final_model = model_info.get('final', '') or model_info.get('primary', '') or 'unknown'
        model_counts[final_model] += 1
        if model_info.get('used_fallback', False):
            fallback_usage += 1
    
    # queue distribution
    queue_counts = defaultdict(int)
    for task in filtered_tasks:
        queue_counts[task.get('queue_dir', 'unknown')] += 1
    
    # error code distribution
    error_counts = defaultdict(int)
    for task in filtered_tasks:
        if task.get('status') == 'failed':
            error_counts[task.get('error_code', 'unknown')] += 1
    
    print(f"Provenance Summary")
    print(f"{'=' * 60}")
    print(f"Total tasks: {total}")
    print(f"  Successful: {successful}")
    print(f"  Failed: {failed}")
    print(f"  Requeued: {requeued}")
    print()
    
    if durations:
        print(f"Execution Duration:")
        print(f"  Average: {avg_duration:.1f}s ({avg_duration/60:.1f}m)")
        print(f"  Min: {min_duration}s ({min_duration/60:.1f}m)")
        print(f"  Max: {max_duration}s ({max_duration/60:.1f}m)")
        print()
    
    if model_counts:
        print(f"Agent Model Usage:")
        for model, count in sorted(model_counts.items(), key=lambda x: -x[1]):
            print(f"  {model}: {count}")
        if fallback_usage > 0:
            print(f"  Fallback used: {fallback_usage} times")
        print()
    
    if queue_counts:
        print(f"Queue Distribution:")
        for queue, count in sorted(queue_counts.items(), key=lambda x: -x[1]):
            print(f"  {queue}: {count}")
        print()
    
    if error_counts:
        print(f"Error Distribution:")
        for error, count in sorted(error_counts.items(), key=lambda x: -x[1]):
            print(f"  {error}: {count}")
        print()

if detailed_mode:
    print(f"Detailed Task Information ({len(filtered_tasks)} tasks)")
    print(f"{'=' * 60}")
    
    # group tasks by ticket name to show execution history
    tasks_by_ticket = defaultdict(list)
    for task in filtered_tasks:
        ticket_name = task.get('ticket_name', 'unknown')
        tasks_by_ticket[ticket_name].append(task)
    
    for ticket_name in sorted(tasks_by_ticket.keys()):
        ticket_tasks = sorted(tasks_by_ticket[ticket_name], key=lambda t: t.get('requeue_attempt', 0))
        print()
        print(f"Ticket: {ticket_name}")
        print(f"  Total attempts: {len(ticket_tasks)}")
        
        for task in ticket_tasks:
            attempt_num = task.get('requeue_attempt', 0)
            if attempt_num > 0:
                print(f"  └─ Attempt #{attempt_num + 1}:")
            else:
                print(f"  └─ Attempt #1:")
            print(f"      Queue: {task.get('queue_dir', 'unknown')}")
            print(f"      Status: {task.get('status', 'unknown')}")
            if task.get('status') == 'failed':
                print(f"      Error: {task.get('error_code', 'unknown')} - {task.get('error_message', '')}")
            print(f"      Start: {task.get('start_ts_utc', 'unknown')}")
            print(f"      End: {task.get('end_ts_utc', 'unknown')}")
            print(f"      Duration: {task.get('execution_duration', 'unknown')} ({task.get('execution_duration_secs', 0)}s)")
            model_info = task.get('agent_model', {})
            print(f"      Model: {model_info.get('final', model_info.get('primary', 'unknown'))}")
            if model_info.get('used_fallback', False):
                print(f"        (fallback from {model_info.get('primary', 'unknown')})")
            if task.get('previous_attempt_provenance_file'):
                prev_file = task.get('previous_attempt_provenance_file', '')
                print(f"      Previous attempt: {prev_file}")
            if task.get('git_commit_hash'):
                print(f"      Git commit: {task.get('git_commit_hash', '')[:8]}")
            if task.get('newly_dirty_files'):
                print(f"      Files modified: {len(task.get('newly_dirty_files', []))}")
            print(f"      Provenance: {task.get('_provenance_file', 'unknown')}")
PY
