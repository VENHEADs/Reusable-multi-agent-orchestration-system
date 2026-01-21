#!/usr/bin/env bash
set -euo pipefail

# requeue_failed.sh - Requeue failed tasks from processed directory
#
# Usage: ./agent_factory/requeue_failed.sh [--queue-dir <dir>] [--dry-run]

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

AGENT_FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${AGENT_FACTORY_DIR}/config.sh" ]]; then
  source "${AGENT_FACTORY_DIR}/config.sh" 2>/dev/null || true
fi

QUEUE_DIR="tasks/queue"
DRY_RUN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --queue-dir)
      QUEUE_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="1"
      shift
      ;;
    *)
      echo "unknown option: $1" >&2
      echo "usage: $0 [--queue-dir <dir>] [--dry-run]"
      exit 1
      ;;
  esac
done

if [[ ! -d "$QUEUE_DIR" ]]; then
  echo "Queue directory not found: $QUEUE_DIR" >&2
  exit 1
fi

processed_dir="$QUEUE_DIR/processed"
if [[ ! -d "$processed_dir" ]]; then
  echo "No processed tasks found in $processed_dir"
  exit 0
fi

log_dir="${REPO_ROOT}/${AGENT_RUNS_LOG_DIR:-logs/agent_runs}"
if [[ ! -d "$log_dir" ]]; then
  echo "No agent logs found in $log_dir"
  exit 0
fi

echo "🔍 Scanning for failed tasks..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

requeued=0
skipped=0

# find all processed task files
for processed_file in "$processed_dir"/*.md.*; do
  [[ ! -f "$processed_file" ]] && continue
  
  # extract original task name (before timestamp and PID)
  task_name="$(basename "$processed_file" | sed -E 's/\.([0-9]+\.)+[0-9]+$//')"
  
  # find corresponding log file
  log_file="$(find "$log_dir" -name "*_${task_name}.log" -type f | sort -r | head -n 1)"
  
  if [[ -z "$log_file" ]] || [[ ! -f "$log_file" ]]; then
    # no log found, skip
    continue
  fi
  
  # check for failure indicators (order matters: check specific errors first)
  # error categories match orchestrator's error handling for consistency
  is_failed="0"
  failure_reason=""
  error_category=""
  
  # check for timeout errors (most specific, matches orchestrator return code 4)
  if grep -qiE "(TIMEOUT:|execution.*timeout|exceeded.*timeout|agent execution exceeded.*timeout)" "$log_file" 2>/dev/null; then
    is_failed="1"
    failure_reason="timeout"
    error_category="timeout"
  # check for empty output (enhanced detection with content validation, matches orchestrator return code 2)
  # also check for content analysis messages from improved detection
  elif grep -qiE "(empty output|empty agent output|log file size.*0 bytes|lines.*[0-2]|has meaningful content.*0|content analysis|WARNING: empty output detected|ERROR: empty agent output detected)" "$log_file" 2>/dev/null || [[ ! -s "$log_file" ]] || [[ "$(wc -l < "$log_file" | tr -d ' ')" -lt 3 ]]; then
    # check if it's a fail-fast after retries or initial detection
    if grep -qiE "(fail fast after|empty output detected.*fail fast|has meaningful content.*0|ERROR: empty output detected.*fail fast)" "$log_file" 2>/dev/null; then
      # check if fallback model was attempted
      if grep -qiE "(switching to fallback|fallback model|RETRY ATTEMPT.*empty output)" "$log_file" 2>/dev/null; then
        is_failed="1"
        failure_reason="empty output (fail fast after retries with fallback)"
        error_category="empty_output"
      else
        is_failed="1"
        failure_reason="empty output (fail fast after retries)"
        error_category="empty_output"
      fi
    elif [[ ! -s "$log_file" ]] || [[ "$(wc -l < "$log_file" | tr -d ' ')" -lt 3 ]]; then
      is_failed="1"
      failure_reason="empty output"
      error_category="empty_output"
    else
      # check for meaningful content (enhanced validation)
      local has_content="0"
      if [[ -f "$log_file" ]] && [[ -r "$log_file" ]] && [[ -s "$log_file" ]]; then
        local content_lines
        content_lines="$(grep -vE "^[[:space:]]*$|^[[:space:]]*━━|^[0-9]{4}-[0-9]{2}-[0-9]{2}T" "$log_file" 2>/dev/null | grep -E "[^[:space:]]" | wc -l | tr -d ' ' || echo "0")"
        if [[ "$content_lines" -lt 3 ]]; then
          is_failed="1"
          failure_reason="empty output (no meaningful content)"
          error_category="empty_output"
        fi
      fi
    fi
  # check for NEED-INFO (enhanced detection patterns, matches orchestrator return code 3)
  # also check for question patterns that indicate agent is asking for information
  elif grep -qiE "NEED-INFO:|NEED INFO:|need-info:|agent requested additional information|INFO: agent requested additional information" "$log_file" 2>/dev/null || \
       grep -qiE "^(I need|I require|please provide|can you provide|missing information|need more information|requires additional|need clarification|need to know|what is|which|where is|how do|when should|why does)" "$log_file" 2>/dev/null; then
    is_failed="1"
    failure_reason="NEED-INFO"
    error_category="need_info"
  # check for authentication errors (non-retryable, matches orchestrator error_category)
  elif grep -qiE "(unauthorized|forbidden|401|403|authentication.*failed|invalid.*api.*key|api.*key.*expired|api.*key.*invalid|auth_error)" "$log_file" 2>/dev/null; then
    is_failed="1"
    failure_reason="authentication error"
    error_category="auth_error"
  # check for rate limit (even after fallback attempt, including retry-after headers)
  # enhanced detection: also check for RATE LIMIT DETECTED log messages
  # expanded patterns to match orchestrator improvements (matches orchestrator error_category)
  elif grep -qiE "(hit your hard limit|rate limit|429|quota|ActionRequiredError|too many requests|request.*limit|throttled|rate.*exceeded|retry.*after|x-ratelimit|RATE LIMIT DETECTED|rate.*limit.*exceeded|quota.*exceeded|requests.*per.*minute|requests.*per.*hour|rate.*limit.*reached|throttling|rate.*throttle)" "$log_file" 2>/dev/null; then
    error_category="rate_limit"
    # check if fallback was attempted and also failed
    if grep -qiE "(switching to fallback|fallback model|RETRY ATTEMPT.*fallback)" "$log_file" 2>/dev/null; then
      # fallback was attempted, check if it also failed
      if ! grep -qiE "(successfully completed|Task.*completed|successfully completed with fallback)" "$log_file" 2>/dev/null; then
        # check if all retries were exhausted
        if grep -qiE "(retry attempts.*3/3|after.*3 attempts|max retries|all retries exhausted|ERROR:.*rate limit.*after.*attempts)" "$log_file" 2>/dev/null; then
          is_failed="1"
          failure_reason="rate limit (fallback failed, all retries exhausted)"
        else
          is_failed="1"
          failure_reason="rate limit (fallback also failed)"
        fi
      fi
    else
      # no fallback attempted yet, or fallback not configured
      # check if all retries were exhausted
      if grep -qiE "(retry attempts.*3/3|after.*3 attempts|max retries|all retries exhausted|ERROR:.*rate limit.*after.*attempts)" "$log_file" 2>/dev/null; then
        is_failed="1"
        failure_reason="rate limit (all retries exhausted)"
      else
        is_failed="1"
        failure_reason="rate limit"
      fi
    fi
  # check for network errors (transient, matches orchestrator error_category)
  elif grep -qiE "(connection.*refused|connection.*reset|connection.*timeout|network.*error|502|503|504|temporary.*failure|dns.*error|name.*resolution|econnrefused|econnreset|etimedout|network.*unreachable|network_error)" "$log_file" 2>/dev/null; then
    is_failed="1"
    failure_reason="network error"
    error_category="network_error"
  # check for API errors (transient, matches orchestrator error_category)
  elif grep -qiE "(internal.*error|service.*unavailable|bad.*gateway|502|503|504|gateway.*timeout|upstream.*error|server.*error|http.*error|api.*error|api_error)" "$log_file" 2>/dev/null; then
    is_failed="1"
    failure_reason="API error"
    error_category="api_error"
  # check for request errors (non-retryable, matches orchestrator error_category)
  elif grep -qiE "(bad.*request|400|malformed|invalid.*request|syntax.*error|parse.*error|request_error)" "$log_file" 2>/dev/null; then
    is_failed="1"
    failure_reason="request error"
    error_category="request_error"
  # check for log file errors (matches orchestrator error_category)
  elif grep -qiE "(log file.*missing|log file.*unreadable|log_error|ERROR: log file)" "$log_file" 2>/dev/null; then
    is_failed="1"
    failure_reason="log file error"
    error_category="log_error"
  # check for signal errors (process killed)
  elif grep -qiE "(signal.*error|killed|terminated|SIGTERM|SIGKILL|signal_error)" "$log_file" 2>/dev/null; then
    is_failed="1"
    failure_reason="signal error"
    error_category="signal_error"
  # check for unknown errors (non-zero exit code without matching pattern, matches orchestrator error_category)
  elif grep -qiE "(unknown error|non-zero exit code.*no known error pattern|treating as potentially transient|unknown_error|WARNING: non-zero exit code)" "$log_file" 2>/dev/null; then
    # check if retries were exhausted
    if grep -qiE "(retry attempts.*3/3|after.*3 attempts|max retries|all retries exhausted|ERROR:.*after.*attempts)" "$log_file" 2>/dev/null; then
      is_failed="1"
      failure_reason="unknown error (all retries exhausted)"
      error_category="unknown_error"
    else
      is_failed="1"
      failure_reason="unknown error"
      error_category="unknown_error"
    fi
  # check for other error patterns (but not if it looks successful, matches orchestrator error_category)
  elif grep -qiE "(ERROR:|execution.*failed|agent.*failed|non-retryable.*error|execution_error|execution_failure)" "$log_file" 2>/dev/null; then
    # only mark as failed if it doesn't look like a successful completion
    if ! grep -qiE "(Task.*completed|Summary|successfully|all tests passed|successfully completed)" "$log_file" 2>/dev/null; then
      is_failed="1"
      failure_reason="execution error"
      error_category="execution_error"
    fi
  fi
  
  # log error category for better tracking (if available)
  if [[ "$is_failed" == "1" ]] && [[ -n "$error_category" ]]; then
    # error category is set, can be used for filtering/grouping
    :
  fi
  
    if [[ "$is_failed" == "1" ]]; then
      target_file="$QUEUE_DIR/$task_name"
      
      if [[ -f "$target_file" ]]; then
        echo "  ⚠️  $task_name (already in queue, skipping)"
        skipped=$((skipped + 1))
        continue
      fi
      
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "  [DRY-RUN] Would requeue: $task_name ($failure_reason)"
        requeued=$((requeued + 1))
      else
        if mv "$processed_file" "$target_file" 2>/dev/null; then
          echo "  ✅ Requeued: $task_name ($failure_reason)"
          requeued=$((requeued + 1))
        else
          echo "  ❌ Failed to requeue: $task_name" >&2
        fi
      fi
    fi
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "  [DRY-RUN] Would requeue: $requeued tasks, skipped: $skipped"
else
  echo "  Requeued: $requeued tasks, skipped: $skipped"
fi
echo
