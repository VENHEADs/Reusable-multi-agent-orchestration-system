#!/usr/bin/env bash
# agent_factory/config.sh - centralized configuration for agent_factory
#
# this file defines default values for all agent_factory configuration variables.
# scripts can source this file to get defaults, then override via environment variables.
#
# ============================================================================
# usage
# ============================================================================
#
# option 1: source from script (recommended)
#   source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
#   # or from project root:
#   source agent_factory/config.sh
#
# option 2: override via environment variables (temporary changes)
#   export ORCHESTRATOR_SLEEP_SECS=10
#   ./agent_factory/orchestrator --profile Agent_profiles/worker.md --queue-dir tasks/queue
#
# option 3: edit this file directly (project-specific defaults)
#   # change: ORCHESTRATOR_SLEEP_SECS="${ORCHESTRATOR_SLEEP_SECS:-5}"
#   # to:     ORCHESTRATOR_SLEEP_SECS="${ORCHESTRATOR_SLEEP_SECS:-10}"
#
# ============================================================================
# configuration examples
# ============================================================================
#
# example 1: faster processing (reduce sleep intervals)
#   export ORCHESTRATOR_SLEEP_SECS=3
#   export JUDGE_SLEEP_SECS=10
#   export JUDGE_TRIGGER_SLEEP_SECS=10
#
# example 2: higher throughput (allow more pending tasks)
#   export MAX_WORKER_PENDING=10
#   export MAX_SUBPLANNER_PENDING=5
#   export JUDGE_PAUSE_ON_PENDING=0
#
# example 3: longer timeouts (for complex tasks)
#   export AGENT_EXECUTION_TIMEOUT_SECS=3600
#   export SHUTDOWN_TIMEOUT_SECS=120
#
# example 4: cost optimization (longer sleeps, cheaper models)
#   export ORCHESTRATOR_SLEEP_SECS=10
#   export FALLBACK_MODEL="gpt-4o-mini"
#
# example 5: aggressive judge triggering (faster commits)
#   export JUDGE_TRIGGER_COOLDOWN_SECS=300
#   export JUDGE_TRIGGER_PROCESSED_DELTA=3
#   export JUDGE_TRIGGER_MAX_WORKER_PENDING=1
#
# ============================================================================
# configuration priority (highest to lowest)
# ============================================================================
# 1. environment variables (export VAR=value) - highest priority
# 2. this file's defaults (config.sh) - source of truth for all defaults
# 
# note: all scripts source this file and use these defaults. there are no
# hardcoded defaults in scripts - this file is the single source of truth.
#
# ============================================================================
# per-project customization
# ============================================================================
# for project-specific defaults, edit this file directly. all scripts that
# source this file will automatically use your custom defaults.
#
# recommended: keep a backup of the original config.sh before making changes:
#   cp agent_factory/config.sh agent_factory/config.sh.backup

# detect script location
if [[ -z "${AGENT_FACTORY_DIR:-}" ]]; then
  if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    AGENT_FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  else
    AGENT_FACTORY_DIR="$(cd "$(dirname "$0")" && pwd)"
  fi
fi

# ============================================================================
# orchestrator configuration
# ============================================================================

# sleep interval between queue checks (seconds)
ORCHESTRATOR_SLEEP_SECS="${ORCHESTRATOR_SLEEP_SECS:-5}"

# max tasks to process per loop iteration
ORCHESTRATOR_MAX_SPAWNS="${ORCHESTRATOR_MAX_SPAWNS:-1}"

# max pending tasks in worker queue before throttling subplanner
MAX_WORKER_PENDING="${MAX_WORKER_PENDING:-5}"

# max pending tasks in subplanner queue before throttling planner
MAX_SUBPLANNER_PENDING="${MAX_SUBPLANNER_PENDING:-3}"

# pause worker/subplanner when judge has pending work (1=enabled, 0=disabled)
JUDGE_PAUSE_ON_PENDING="${JUDGE_PAUSE_ON_PENDING:-1}"

# agent CLI path (default: from $AGENT_BIN or PATH)
AGENT_BIN="${AGENT_BIN:-}"

# cursor API key (default: from $CURSOR_API_KEY)
CURSOR_API_KEY="${CURSOR_API_KEY:-}"

# fallback model name if rate limit hit
FALLBACK_MODEL="${FALLBACK_MODEL:-gpt-5.2-codex-low}"

# max retries for agent execution
ORCHESTRATOR_MAX_RETRIES="${ORCHESTRATOR_MAX_RETRIES:-3}"

# initial backoff delay for retries (seconds)
ORCHESTRATOR_BACKOFF_SECS="${ORCHESTRATOR_BACKOFF_SECS:-1}"

# maximum backoff delay cap (seconds) - prevents excessive delays on repeated failures
ORCHESTRATOR_MAX_BACKOFF_SECS="${ORCHESTRATOR_MAX_BACKOFF_SECS:-300}"

# agent execution timeout (seconds) - agents that exceed this are gracefully terminated (SIGTERM, then SIGKILL) and requeued
# default: 1800 seconds (30 minutes) - reasonable for most tasks, increase for complex/long-running tasks
# timeout events are logged clearly and tracked in provenance files for monitoring
AGENT_EXECUTION_TIMEOUT_SECS="${AGENT_EXECUTION_TIMEOUT_SECS:-1800}"

# graceful shutdown timeout (seconds) - processes will force exit after this time
SHUTDOWN_TIMEOUT_SECS="${SHUTDOWN_TIMEOUT_SECS:-60}"

# ============================================================================
# judge daemon configuration
# ============================================================================

# sleep interval between judge queue checks (seconds)
JUDGE_SLEEP_SECS="${JUDGE_SLEEP_SECS:-15}"

# path to blocker ticket file
BLOCKER_TICKET_PATH="${BLOCKER_TICKET_PATH:-.agent_factory_state/judge_blocker.md}"

# auto-push commits to remote (1=enabled, 0=disabled)
JUDGE_AUTO_PUSH="${JUDGE_AUTO_PUSH:-1}"

# git remote name for auto-push
JUDGE_PUSH_REMOTE="${JUDGE_PUSH_REMOTE:-origin}"

# path to judge waivers JSON file
JUDGE_WAIVERS_FILE="${JUDGE_WAIVERS_FILE:-agent_factory/judge_waivers.json}"

# pytest max failures before stopping
PYTEST_MAXFAIL="${PYTEST_MAXFAIL:-5}"

# default include paths for judge commits (space-separated)
JUDGE_INCLUDE_PATHS_DEFAULT="agent_factory data_prep pricing_algorithms tests pyproject.toml requirements.txt analyze_historical_coverage.py"
JUDGE_INCLUDE_PATHS="${JUDGE_INCLUDE_PATHS:-$JUDGE_INCLUDE_PATHS_DEFAULT}"

# ============================================================================
# judge trigger configuration
# ============================================================================

# sleep interval between trigger checks (seconds)
JUDGE_TRIGGER_SLEEP_SECS="${JUDGE_TRIGGER_SLEEP_SECS:-15}"

# max pending worker tasks before triggering judge
JUDGE_TRIGGER_MAX_WORKER_PENDING="${JUDGE_TRIGGER_MAX_WORKER_PENDING:-2}"

# cooldown period between judge triggers (seconds)
JUDGE_TRIGGER_COOLDOWN_SECS="${JUDGE_TRIGGER_COOLDOWN_SECS:-600}"

# number of processed tasks delta required to trigger judge
JUDGE_TRIGGER_PROCESSED_DELTA="${JUDGE_TRIGGER_PROCESSED_DELTA:-5}"

# ============================================================================
# paths and directories
# ============================================================================

# state directory for agent factory state files
AGENT_FACTORY_STATE_DIR="${AGENT_FACTORY_STATE_DIR:-.agent_factory_state}"

# log directory for agent runs
AGENT_RUNS_LOG_DIR="${AGENT_RUNS_LOG_DIR:-logs/agent_runs}"

# ============================================================================
# log rotation configuration
# ============================================================================

# number of recent log files to keep uncompressed (default: 100)
LOG_RETENTION_COUNT="${LOG_RETENTION_COUNT:-100}"

# enable log compression for old logs (1=enabled, 0=disabled)
LOG_COMPRESSION_ENABLED="${LOG_COMPRESSION_ENABLED:-1}"

# compress logs older than this many days (default: 7)
LOG_COMPRESSION_AGE_DAYS="${LOG_COMPRESSION_AGE_DAYS:-7}"

# delete compressed logs older than this many days (default: 90)
LOG_DELETION_AGE_DAYS="${LOG_DELETION_AGE_DAYS:-90}"

# maximum total log directory size in MB (0 = disabled, default: 0)
# when exceeded, oldest logs are compressed/deleted regardless of age
LOG_MAX_DIRECTORY_SIZE_MB="${LOG_MAX_DIRECTORY_SIZE_MB:-0}"

# interval for periodic log rotation checks in queue mode (seconds, default: 300 = 5 minutes)
LOG_ROTATION_CHECK_INTERVAL_SECS="${LOG_ROTATION_CHECK_INTERVAL_SECS:-300}"

# consider logs active if modified within this many seconds (default: 5)
LOG_ACTIVE_GRACE_SECS="${LOG_ACTIVE_GRACE_SECS:-5}"

# name of symlink pointing to latest log date directory (empty disables)
LOG_LATEST_SYMLINK_NAME="${LOG_LATEST_SYMLINK_NAME:-latest}"

# ============================================================================
# monitoring configuration
# ============================================================================

# stuck task threshold (seconds) - tasks older than this are considered stuck
MONITOR_STUCK_THRESHOLD="${MONITOR_STUCK_THRESHOLD:-3600}"

# warning threshold (seconds) - tasks older than this trigger warnings
MONITOR_WARNING_THRESHOLD="${MONITOR_WARNING_THRESHOLD:-1800}"

# monitor refresh interval (seconds) - sleep between refreshes in watch mode
MONITOR_REFRESH_INTERVAL_SECS="${MONITOR_REFRESH_INTERVAL_SECS:-2}"

# ============================================================================
# backward compatibility aliases
# ============================================================================

# maintain backward compatibility with old variable names
SLEEP_SECS="${SLEEP_SECS:-${ORCHESTRATOR_SLEEP_SECS}}"
COOLDOWN_SECS="${COOLDOWN_SECS:-${JUDGE_TRIGGER_COOLDOWN_SECS}}"
PROCESSED_DELTA="${PROCESSED_DELTA:-${JUDGE_TRIGGER_PROCESSED_DELTA}}"
STATE_DIR="${STATE_DIR:-${AGENT_FACTORY_STATE_DIR}}"

