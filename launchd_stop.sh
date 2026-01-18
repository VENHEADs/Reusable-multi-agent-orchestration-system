#!/usr/bin/env bash
set -euo pipefail

# unloads agent factory launchd jobs for this repo.
#
# usage:
#   ./agent_factory/launchd_stop.sh [--project-id <id>] [--remove]

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

project_id=""
remove="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      project_id="$2"
      shift 2
      ;;
    --remove)
      remove="1"
      shift
      ;;
    -h|--help)
      echo "usage: $0 [--project-id <id>] [--remove]" >&2
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$project_id" ]]; then
  project_id="$(basename "$repo_root" | tr -cs 'A-Za-z0-9' '_' | tr '[:upper:]' '[:lower:]' | sed -E 's/^_+|_+$//g')"
fi

launch_agents_dir="$HOME/Library/LaunchAgents"
user_id="$(id -u)"

# stop any loaded agent_factory services (including stray/test labels)
labels="$(
  launchctl list 2>/dev/null | python3 -c "import sys
lines=sys.stdin.read().splitlines()
for l in lines:
  parts=l.split()
  if not parts:
    continue
  label=parts[-1]
  if label.startswith('com.${project_id}.agent_factory.'):
    print(label)
"
)"

if [[ -n "$labels" ]]; then
  while IFS= read -r label; do
    [[ -z "$label" ]] && continue
    launchctl disable "gui/${user_id}/${label}" >/dev/null 2>&1 || true
    launchctl bootout "gui/${user_id}/${label}" >/dev/null 2>&1 || true
  done <<< "$labels"
fi

# stop the canonical role plists (and optionally remove them)
for role in primary_planner sub_planner worker judge judge_trigger; do
  label="com.${project_id}.agent_factory.${role}"
  plist_path="${launch_agents_dir}/${label}.plist"

  launchctl disable "gui/${user_id}/${label}" >/dev/null 2>&1 || true
  if [[ -f "$plist_path" ]]; then
    launchctl bootout "gui/${user_id}" "$plist_path" >/dev/null 2>&1 || true
  fi

  if [[ "$remove" == "1" && -f "$plist_path" ]]; then
    rm -f "$plist_path"
  fi
done

# stop stray orchestrator processes started outside launchd
stray_pids="$(
  ps -ax -o pid=,command= | python3 -c "import sys
repo_root='${repo_root}'
out=[]
for line in sys.stdin.read().splitlines():
  line=line.strip()
  if not line:
    continue
  pid_s, cmd = line.split(' ', 1)
  if f'{repo_root}/agent_factory/orchestrator' in cmd or f'{repo_root}/agent_factory/run_orchestrator' in cmd:
    out.append(pid_s)
for pid in out:
  print(pid)
"
)"

if [[ -n "$stray_pids" ]]; then
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    kill "$pid" >/dev/null 2>&1 || true
  done <<< "$stray_pids"
fi

echo "stopped launchd jobs for project: ${project_id}"
