#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${AGENT_FACTORY_DIR}/config.sh" ]]; then
  source "${AGENT_FACTORY_DIR}/config.sh"
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

launch_agents_dir="$HOME/Library/LaunchAgents"
user_id="$(id -u)"

# bootout all jobs (ignore errors)
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

# remove plists
rm -f "${launch_agents_dir}/com.${project_id}.agent_factory."*.plist 2>/dev/null || true

# re-enable jobs and start
for role in primary_planner sub_planner worker judge judge_trigger watchdog; do
  label="com.${project_id}.agent_factory.${role}"
  launchctl enable "gui/${user_id}/${label}" >/dev/null 2>&1 || true
done

exec "${repo_root}/agent_factory/launchd_start.sh" --project-id "$project_id"
