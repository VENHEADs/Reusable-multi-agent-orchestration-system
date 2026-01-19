#!/usr/bin/env bash
set -euo pipefail

# prints launchd status for agent factory jobs for this repo.
#
# usage:
#   ./agent_factory/launchd_status.sh [--project-id <id>]

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
    launchctl print "gui/${user_id}/${label}" | sed -n 's/^/  /p' | grep -E "state = |last exit code|pid = |path = " || true
  else
    echo "  not loaded"
  fi
done
