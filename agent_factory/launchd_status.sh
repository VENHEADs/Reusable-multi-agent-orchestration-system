#!/usr/bin/env bash
set -euo pipefail

# prints launchd status for agent factory jobs for this repo.
#
# usage:
#   ./agent_factory/launchd_status.sh [--project-id <id>]

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

project_id=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      project_id="$2"
      shift 2
      ;;
    -h|--help)
      echo "usage: $0 [--project-id <id>]" >&2
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

user_id="$(id -u)"

echo "launchd status for project: ${project_id}"
for role in primary_planner sub_planner worker judge judge_trigger; do
  label="com.${project_id}.agent_factory.${role}"
  echo
  echo "== ${label}"
  if launchctl print "gui/${user_id}/${label}" >/dev/null 2>&1; then
    launchd_info="$(launchctl print "gui/${user_id}/${label}" 2>/dev/null || true)"
    echo "  loaded: yes"
    state="$(echo "$launchd_info" | sed -n 's/.*state = //p' | head -n 1)"
    last_exit="$(echo "$launchd_info" | sed -n 's/.*last exit code = //p' | head -n 1)"
    pid="$(echo "$launchd_info" | sed -n 's/.*pid = //p' | head -n 1)"
    path="$(echo "$launchd_info" | sed -n 's/.*path = //p' | head -n 1)"
    if [[ -n "$state" ]]; then
      echo "  state: $state"
    fi
    if [[ -n "$last_exit" ]]; then
      echo "  last exit state: $last_exit"
    else
      echo "  last exit state: n/a"
    fi
    if [[ -n "$pid" ]]; then
      echo "  pid: $pid"
    fi
    if [[ -n "$path" ]]; then
      echo "  path: $path"
    fi
  else
    echo "  loaded: no"
    echo "  last exit state: n/a"
  fi
done
