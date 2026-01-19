#!/usr/bin/env bash
set -euo pipefail

# judge_trigger.sh - deterministic trigger for judge runs
#
# runs forever:
# - if worker queue is empty and git is dirty, enqueue a judge ticket (if none pending)
# - sleeps between checks

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SLEEP_SECS="${SLEEP_SECS:-15}"
MAX_WORKER_PENDING="${JUDGE_TRIGGER_MAX_WORKER_PENDING:-2}"
COOLDOWN_SECS="${JUDGE_TRIGGER_COOLDOWN_SECS:-600}"
PROCESSED_DELTA="${JUDGE_TRIGGER_PROCESSED_DELTA:-5}"
STATE_DIR=".agent_factory_state"
LAST_TRIGGER_FILE="${STATE_DIR}/judge_last_trigger_epoch"
LAST_PROCESSED_FILE="${STATE_DIR}/worker_processed_count_at_last_judge"

pending_md_count() {
  local dir="$1"
  find "$dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' '
}

processed_count() {
  find tasks/queue/processed -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '
}

git_is_dirty() {
  [[ -n "$(git status --porcelain 2>/dev/null)" ]]
}

cooldown_elapsed() {
  local now last
  now="$(date +%s)"
  last="0"
  if [[ -f "$LAST_TRIGGER_FILE" ]]; then
    last="$(cat "$LAST_TRIGGER_FILE" 2>/dev/null || echo 0)"
  fi
  [[ $((now - last)) -ge "$COOLDOWN_SECS" ]]
}

should_trigger_due_to_worker_progress() {
  local last_count now_count
  last_count="0"
  if [[ -f "$LAST_PROCESSED_FILE" ]]; then
    last_count="$(cat "$LAST_PROCESSED_FILE" 2>/dev/null || echo 0)"
  fi
  now_count="$(processed_count)"
  [[ $((now_count - last_count)) -ge "$PROCESSED_DELTA" ]]
}

ensure_judge_ticket() {
  mkdir -p tasks/judge_queue
  if [[ "$(pending_md_count tasks/judge_queue)" -gt 0 ]]; then
    return 0
  fi

  mkdir -p "$STATE_DIR"
  now="$(date +%s)"
  now_processed="$(processed_count)"

  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  cat >"tasks/judge_queue/10_judge_run_${ts}.md" <<'EOF'
# Judge Run: validate + commit

## Objective
Run tests + lint. If all pass, commit meaningful changes. If any fail, do not commit and create a fix ticket under `tasks/planner_queue/`.
EOF

  echo "$now" > "$LAST_TRIGGER_FILE"
  echo "$now_processed" > "$LAST_PROCESSED_FILE"
}

while true; do
  if [[ -d .git ]] && git_is_dirty; then
    # trigger when enough worker tickets were processed since last judge,
    # and enforce a cooldown to avoid spam.
    if cooldown_elapsed && should_trigger_due_to_worker_progress; then
      ensure_judge_ticket
    else
      # also allow the original "near-idle" trigger (cheaper than always-on)
      worker_pending="$(pending_md_count tasks/queue)"
      if cooldown_elapsed && [[ "$worker_pending" -le "$MAX_WORKER_PENDING" ]]; then
        ensure_judge_ticket
      fi
    fi
  fi
  sleep "$SLEEP_SECS"
done
