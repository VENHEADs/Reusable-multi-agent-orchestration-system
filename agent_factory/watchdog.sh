#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${AGENT_FACTORY_DIR}/config.sh" ]]; then
  source "${AGENT_FACTORY_DIR}/config.sh"
fi

log_dir="${repo_root}/logs"
mkdir -p "$log_dir"
log_file="${log_dir}/watchdog.log"

log_ts() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$log_file"
}

project_id="$(basename "$repo_root" | tr -cs 'A-Za-z0-9' '_' | tr '[:upper:]' '[:lower:]' | sed -E 's/^_+|_+$//g')"
user_id="$(id -u)"

restart_factory() {
  log_ts "restarting factory..."
  if ! "${repo_root}/agent_factory/launchd_start.sh" --project-id "$project_id" >/dev/null 2>&1; then
    log_ts "launchd_start failed; attempting launchd_reset"
    "${repo_root}/agent_factory/launchd_reset.sh" --project-id "$project_id" >/dev/null 2>&1 || true
  fi
}

log_ts "watchdog check starting"

# 1. check launchd job count
job_count="$(
  launchctl list 2>/dev/null | python3 - "$project_id" <<'PY'
import sys
project_id = sys.argv[1]
labels = [
    line.split()[-1]
    for line in sys.stdin.read().splitlines()
    if line.strip()
]
count = sum(1 for label in labels if label.startswith(f"com.{project_id}.agent_factory."))
print(count)
PY
)"

if [[ "${job_count:-0}" -eq 0 ]]; then
  log_ts "no launchd jobs running; triggering restart"
  restart_factory
fi

# 2. check last activity time (most recent log in logs/agent_runs/)
last_activity_epoch="$(
  python3 - "$repo_root" <<'PY'
import os
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
logs_dir = repo_root / "logs" / "agent_runs"
latest_mtime = 0

if logs_dir.exists():
    for path in logs_dir.rglob("*.log"):
        try:
            mtime = int(path.stat().st_mtime)
            if mtime > latest_mtime:
                latest_mtime = mtime
        except OSError:
            continue

print(latest_mtime)
PY
)"

if [[ "${last_activity_epoch:-0}" -gt 0 ]]; then
  now_epoch="$(date +%s)"
  idle_minutes=$(( (now_epoch - last_activity_epoch) / 60 ))
  if [[ "$idle_minutes" -gt "$WATCHDOG_MAX_IDLE_MINUTES" ]]; then
    log_ts "idle for ${idle_minutes} minutes (threshold: ${WATCHDOG_MAX_IDLE_MINUTES}); restarting"
    restart_factory
  fi
else
  log_ts "no recent agent_runs logs found; skipping idle check"
fi

# 3. check queue size and auto-replenish
queue_dir="${repo_root}/tasks/queue"
if [[ "$WATCHDOG_AUTO_REPLENISH" == "1" ]] && [[ -d "$queue_dir" ]]; then
  queue_count="$(find "$queue_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$queue_count" -lt "$WATCHDOG_MIN_QUEUE_SIZE" ]]; then
    seed_dir="${repo_root}/${SEED_TASKS_DIR}"
    if [[ -d "$seed_dir" ]]; then
      log_ts "queue below threshold (${queue_count} < ${WATCHDOG_MIN_QUEUE_SIZE}); replenishing from ${seed_dir}"
      if [[ "$SEED_SHUFFLE" == "1" ]] && command -v shuf >/dev/null 2>&1; then
        find "$seed_dir" -maxdepth 1 -type f -name '*.md' | shuf | head -n 10 | while IFS= read -r seed_file; do
          cp "$seed_file" "$queue_dir/" 2>/dev/null || true
        done
      else
        cp "$seed_dir"/*.md "$queue_dir/" 2>/dev/null || true
      fi
    else
      log_ts "seed dir missing: ${seed_dir}"
    fi
  fi
fi

# 4. remove stale blocker tickets older than BLOCKER_MAX_AGE_HOURS
if [[ -d "$queue_dir" ]]; then
  stale_minutes=$((BLOCKER_MAX_AGE_HOURS * 60))
  stale_dir="${queue_dir%/}/processed"
  mkdir -p "$stale_dir"
  while IFS= read -r stale_file; do
    [[ -z "$stale_file" ]] && continue
    base_name="$(basename "$stale_file")"
    log_ts "removing stale blocker ticket: $base_name"
    mv "$stale_file" "${stale_dir}/${base_name}.stale" 2>/dev/null || true
  done < <(find "$queue_dir" -maxdepth 1 -type f -name '00_BLOCKER*.md' -mmin "+${stale_minutes}" 2>/dev/null)
fi

log_ts "watchdog check complete"
