#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${AGENT_FACTORY_DIR}/config.sh" ]]; then
  source "${AGENT_FACTORY_DIR}/config.sh"
fi

project_id="$(basename "$repo_root" | tr -cs 'A-Za-z0-9' '_' | tr '[:upper:]' '[:lower:]' | sed -E 's/^_+|_+$//g')"
expected_jobs=6

python3 - "$repo_root" "$project_id" "$expected_jobs" <<'PY'
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

repo_root = Path(sys.argv[1])
project_id = sys.argv[2]
expected_jobs = int(sys.argv[3])

def launchd_running_count():
    try:
        output = subprocess.check_output(["launchctl", "list"], text=True)
    except Exception:
        return 0
    labels = [line.split()[-1] for line in output.splitlines() if line.strip()]
    return sum(1 for label in labels if label.startswith(f"com.{project_id}.agent_factory."))

def latest_log_mtime():
    logs_dir = repo_root / "logs" / "agent_runs"
    latest = 0
    if logs_dir.exists():
        for path in logs_dir.rglob("*.log"):
            try:
                latest = max(latest, int(path.stat().st_mtime))
            except OSError:
                continue
    return latest

def last_watchdog_check():
    watchdog_log = repo_root / "logs" / "watchdog.log"
    if not watchdog_log.exists():
        return ""
    try:
        lines = watchdog_log.read_text(errors="replace").splitlines()
    except OSError:
        return ""
    for line in reversed(lines):
        if line.strip():
            return line.split(" ", 1)[0]
    return ""

def watchdog_restarts_today():
    watchdog_log = repo_root / "logs" / "watchdog.log"
    if not watchdog_log.exists():
        return 0
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    count = 0
    try:
        for line in watchdog_log.read_text(errors="replace").splitlines():
            if line.startswith(today) and "restarting factory" in line:
                count += 1
    except OSError:
        return 0
    return count

def processed_today_count():
    processed_dir = repo_root / "tasks" / "queue" / "processed"
    if not processed_dir.exists():
        return 0
    today = datetime.now(timezone.utc).date()
    count = 0
    for path in processed_dir.glob("*.md*"):
        try:
            mtime = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc).date()
        except OSError:
            continue
        if mtime == today:
            count += 1
    return count

running = launchd_running_count()
last_mtime = latest_log_mtime()
now = int(datetime.now(timezone.utc).timestamp())
idle_minutes = 0
last_task_completed = ""
if last_mtime:
    idle_minutes = max(0, int((now - last_mtime) / 60))
    last_task_completed = datetime.fromtimestamp(last_mtime, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

queue_pending = 0
queue_dir = repo_root / "tasks" / "queue"
if queue_dir.exists():
    queue_pending = len([p for p in queue_dir.glob("*.md")])

warning_threshold = int(os.environ.get("WATCHDOG_MAX_IDLE_MINUTES", "45"))
critical_threshold = warning_threshold * 2

status = "healthy"
if running == 0 or idle_minutes > critical_threshold:
    status = "stopped"
elif running < expected_jobs or idle_minutes > warning_threshold:
    status = "degraded"

payload = {
    "status": status,
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "launchd_jobs": {
        "expected": expected_jobs,
        "running": running,
    },
    "queue": {
        "pending": queue_pending,
        "processed_today": processed_today_count(),
    },
    "activity": {
        "last_task_completed": last_task_completed,
        "idle_minutes": idle_minutes,
    },
    "watchdog": {
        "last_check": last_watchdog_check(),
        "restarts_today": watchdog_restarts_today(),
    },
}

print(json.dumps(payload, indent=2))
PY
