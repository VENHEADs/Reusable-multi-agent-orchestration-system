#!/usr/bin/env bash
set -euo pipefail

# judge_trigger.sh - deterministic trigger for judge runs
#
# runs forever:
# - if worker queue is empty and git is dirty, enqueue a judge ticket (if none pending)
# - sleeps between checks

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
cd "$repo_root"

SLEEP_SECS="${SLEEP_SECS:-15}"
MAX_WORKER_PENDING="${JUDGE_TRIGGER_MAX_WORKER_PENDING:-2}"
COOLDOWN_SECS="${JUDGE_TRIGGER_COOLDOWN_SECS:-300}"
STATE_DIR=".agent_factory_state"
LAST_TRIGGER_FILE="${STATE_DIR}/judge_last_trigger_epoch"

pending_md_count() {
  local dir="$1"
  find "$dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' '
}

git_is_dirty() {
  [[ -n "$(git status --porcelain 2>/dev/null)" ]]
}

ensure_judge_ticket() {
  mkdir -p tasks/judge_queue
  if [[ "$(pending_md_count tasks/judge_queue)" -gt 0 ]]; then
    return 0
  fi

  mkdir -p "$STATE_DIR"
  now="$(date +%s)"
  last="0"
  if [[ -f "$LAST_TRIGGER_FILE" ]]; then
    last="$(cat "$LAST_TRIGGER_FILE" 2>/dev/null || echo 0)"
  fi
  if [[ $((now - last)) -lt "$COOLDOWN_SECS" ]]; then
    return 0
  fi

  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  cat >"tasks/judge_queue/10_judge_run_${ts}.md" <<'EOF'
# Judge Run: validate + commit

## Objective
Run tests + lint. If all pass, commit meaningful changes. If any fail, do not commit and create a fix ticket under `tasks/planner_queue/`.
EOF

  echo "$now" > "$LAST_TRIGGER_FILE"
}

while true; do
  if [[ -d .git ]] && git_is_dirty; then
    # run judge only when the pipeline is idle to avoid generating new work
    # while a prior review/commit cycle is still pending.
    worker_pending="$(pending_md_count tasks/queue)"
    if [[ "$worker_pending" -le "$MAX_WORKER_PENDING" ]] && \
       [[ "$(pending_md_count tasks/subplanner_queue)" -eq 0 ]] && \
       [[ "$(pending_md_count tasks/planner_queue)" -eq 0 ]]; then
      ensure_judge_ticket
    fi
  fi
  sleep "$SLEEP_SECS"
done
