#!/usr/bin/env bash
set -euo pipefail

# log_search.sh - search and query agent run logs
#
# usage:
#   ./agent_factory/log_search.sh [pattern]              # search in uncompressed logs
#   ./agent_factory/log_search.sh --all [pattern]        # search in all logs (including compressed)
#   ./agent_factory/log_search.sh --errors                # find logs with errors
#   ./agent_factory/log_search.sh --recent N              # show recent N logs
#   ./agent_factory/log_search.sh --grep "pattern"        # grep across all logs

AGENT_FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$AGENT_FACTORY_DIR/.." && pwd)"

if [[ -f "${AGENT_FACTORY_DIR}/config.sh" ]]; then
  source "${AGENT_FACTORY_DIR}/config.sh"
fi

log_dir="${REPO_ROOT}/${AGENT_RUNS_LOG_DIR}"
if [[ ! -d "$log_dir" ]]; then
  echo "log directory not found: $log_dir" >&2
  exit 1
fi

SEARCH_ALL="${SEARCH_ALL:-0}"
SHOW_ERRORS="${SHOW_ERRORS:-0}"
SHOW_RECENT="${SHOW_RECENT:-0}"
SHOW_SIZE="${SHOW_SIZE:-0}"
SHOW_CLEANUP="${SHOW_CLEANUP:-0}"
RECENT_COUNT="${RECENT_COUNT:-10}"
GREP_PATTERN="${GREP_PATTERN:-}"
TASK_PATTERN="${TASK_PATTERN:-}"
DATE_FILTER="${DATE_FILTER:-}"
SINCE_DAYS="${SINCE_DAYS:-}"
MIN_SIZE_MB="${MIN_SIZE_MB:-0}"
MAX_SIZE_MB="${MAX_SIZE_MB:-0}"
ERROR_TYPE="${ERROR_TYPE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      SEARCH_ALL="1"
      shift
      ;;
    --errors)
      SHOW_ERRORS="1"
      shift
      ;;
    --recent)
      SHOW_RECENT="1"
      RECENT_COUNT="${2:-10}"
      shift 2
      ;;
    --grep)
      GREP_PATTERN="${2:-}"
      SEARCH_ALL="1"
      shift 2
      ;;
    --size)
      SHOW_SIZE="1"
      shift
      ;;
    --cleanup)
      SHOW_CLEANUP="1"
      shift
      ;;
    --task)
      TASK_PATTERN="${2:-}"
      shift 2
      ;;
    --date)
      DATE_FILTER="${2:-}"
      shift 2
      ;;
    --since)
      SINCE_DAYS="${2:-}"
      shift 2
      ;;
    --min-size)
      MIN_SIZE_MB="${2:-}"
      shift 2
      ;;
    --max-size)
      MAX_SIZE_MB="${2:-}"
      shift 2
      ;;
    --error-type)
      ERROR_TYPE="${2:-}"
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
usage: ./agent_factory/log_search.sh [options] [pattern]

options:
  --all              search in all logs (including compressed .gz files)
  --errors            find logs containing error patterns
  --recent N          show recent N log files (default: 10)
  --grep PATTERN      grep for pattern across all logs
  --size              show log file sizes and disk usage
  --cleanup           show logs that can be safely deleted (older than retention)
  --task PATTERN      filter logs by task name pattern
  --date YYYY-MM-DD   filter logs by date (YYYY-MM-DD format)
  --since DAYS        show logs from last N days
  --min-size MB       filter logs by minimum size (MB)
  --max-size MB       filter logs by maximum size (MB)
  --error-type TYPE   filter logs by error type (rate_limit, timeout, need_info, empty_output, network_error)
  -h, --help          show this help

examples:
  ./agent_factory/log_search.sh "NEED-INFO"
  ./agent_factory/log_search.sh --all "rate limit"
  ./agent_factory/log_search.sh --errors
  ./agent_factory/log_search.sh --recent 5
  ./agent_factory/log_search.sh --grep "TIMEOUT"
  ./agent_factory/log_search.sh --size
  ./agent_factory/log_search.sh --cleanup
  ./agent_factory/log_search.sh --task "fix_linting"
  ./agent_factory/log_search.sh --date 2026-01-19
  ./agent_factory/log_search.sh --since 7
  ./agent_factory/log_search.sh --min-size 10 --max-size 100
  ./agent_factory/log_search.sh --error-type timeout
EOF
      exit 0
      ;;
    *)
      if [[ -z "$GREP_PATTERN" ]] && [[ "$SHOW_ERRORS" == "0" ]] && [[ "$SHOW_RECENT" == "0" ]] && [[ "$SHOW_SIZE" == "0" ]] && [[ "$SHOW_CLEANUP" == "0" ]]; then
        GREP_PATTERN="$1"
        SEARCH_ALL="1"
      fi
      shift
      ;;
  esac
done

# helper function to check if log file matches filters
matches_filters() {
  local log_file="$1"
  local log_name="$(basename "$log_file")"
  
  # task name pattern filter
  if [[ -n "$TASK_PATTERN" ]]; then
    if ! echo "$log_name" | grep -qiE "$TASK_PATTERN" >/dev/null 2>&1; then
      return 1
    fi
  fi
  
  # date filter (YYYY-MM-DD format)
  if [[ -n "$DATE_FILTER" ]]; then
    local expected_date="${DATE_FILTER//-/}"
    local log_date=""
    # extract date from filename (format: YYYYMMDD_HHMMSS_task.log)
    if echo "$log_name" | grep -qE '^[0-9]{8}_'; then
      log_date="$(echo "$log_name" | sed -E 's/^([0-9]{8})_.*/\1/')"
    fi
    if [[ "$log_date" != "$expected_date" ]]; then
      return 1
    fi
  fi
  
  # since days filter
  if [[ -n "$SINCE_DAYS" ]]; then
    local now_epoch
    now_epoch="$(date +%s)"
    local threshold=$((now_epoch - SINCE_DAYS * 86400))
    local file_mtime
    if [[ "$(uname)" == "Darwin" ]]; then
      file_mtime="$(stat -f "%m" "$log_file" 2>/dev/null || echo "0")"
    else
      file_mtime="$(stat -c "%Y" "$log_file" 2>/dev/null || echo "0")"
    fi
    if [[ "$file_mtime" -lt "$threshold" ]]; then
      return 1
    fi
  fi
  
  # size filters
  if [[ -n "$MIN_SIZE_MB" ]] || [[ -n "$MAX_SIZE_MB" ]]; then
    local file_size
    if [[ "$(uname)" == "Darwin" ]]; then
      file_size="$(stat -f "%z" "$log_file" 2>/dev/null || echo "0")"
    else
      file_size="$(stat -c "%s" "$log_file" 2>/dev/null || echo "0")"
    fi
    local file_size_mb=$((file_size / 1048576))
    
    if [[ -n "$MIN_SIZE_MB" ]] && [[ "$file_size_mb" -lt "$MIN_SIZE_MB" ]]; then
      return 1
    fi
    if [[ -n "$MAX_SIZE_MB" ]] && [[ "$file_size_mb" -gt "$MAX_SIZE_MB" ]]; then
      return 1
    fi
  fi
  
  return 0
}

if [[ "$SHOW_RECENT" == "1" ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Recent $RECENT_COUNT log files"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  
  count=0
  while IFS= read -r log_file; do
    [[ -z "$log_file" ]] && continue
    [[ ! -f "$log_file" ]] && continue
    
    # apply filters
    if ! matches_filters "$log_file"; then
      continue
    fi
    
    count=$((count + 1))
    log_name="$(basename "$log_file")"
    
    if [[ "$(uname)" == "Darwin" ]]; then
      log_time="$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$log_file" 2>/dev/null || echo 'unknown')"
      log_size="$(stat -f "%z" "$log_file" 2>/dev/null || echo 0)"
    else
      log_time="$(stat -c "%y" "$log_file" 2>/dev/null | cut -d' ' -f1-2 || echo 'unknown')"
      log_size="$(stat -c "%s" "$log_file" 2>/dev/null || echo 0)"
    fi
    
    # format size
    if [[ "$log_size" -lt 1024 ]]; then
      size_str="${log_size}B"
    elif [[ "$log_size" -lt 1048576 ]]; then
      size_str="$((log_size / 1024))KB"
    else
      size_str="$((log_size / 1048576))MB"
    fi
    
    echo "  [$count] $log_name"
    echo "      $log_time | $size_str"
    
    if [[ "$count" -ge "$RECENT_COUNT" ]]; then
      break
    fi
  done < <(find "$log_dir" -type f \( -name '*.log' -o -name '*.log.gz' \) -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null || true)
  
  if [[ "$count" -eq 0 ]]; then
    echo "  No log files found"
  fi
  echo
  exit 0
fi

if [[ "$SHOW_SIZE" == "1" ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Log File Sizes and Disk Usage"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  
  uncompressed_count=0
  compressed_count=0
  uncompressed_size=0
  compressed_size=0
  
  while IFS= read -r log_file; do
    [[ -z "$log_file" ]] && continue
    [[ ! -f "$log_file" ]] && continue
    
    if [[ "$log_file" == *.gz ]]; then
      compressed_count=$((compressed_count + 1))
      if [[ "$(uname)" == "Darwin" ]]; then
        file_size="$(stat -f "%z" "$log_file" 2>/dev/null || echo 0)"
      else
        file_size="$(stat -c "%s" "$log_file" 2>/dev/null || echo 0)"
      fi
      compressed_size=$((compressed_size + file_size))
    else
      uncompressed_count=$((uncompressed_count + 1))
      if [[ "$(uname)" == "Darwin" ]]; then
        file_size="$(stat -f "%z" "$log_file" 2>/dev/null || echo 0)"
      else
        file_size="$(stat -c "%s" "$log_file" 2>/dev/null || echo 0)"
      fi
      uncompressed_size=$((uncompressed_size + file_size))
    fi
  done < <(find "$log_dir" -type f \( -name '*.log' -o -name '*.log.gz' \) -print0 2>/dev/null || true)
  
  total_size=$((uncompressed_size + compressed_size))
  
  # format sizes
  format_size() {
    local bytes="$1"
    if [[ "$bytes" -lt 1024 ]]; then
      echo "${bytes}B"
    elif [[ "$bytes" -lt 1048576 ]]; then
      echo "$((bytes / 1024))KB"
    elif [[ "$bytes" -lt 1073741824 ]]; then
      echo "$((bytes / 1048576))MB"
    else
      echo "$((bytes / 1073741824))GB"
    fi
  }
  
  echo "  Uncompressed: $uncompressed_count files, $(format_size $uncompressed_size)"
  echo "  Compressed:   $compressed_count files, $(format_size $compressed_size)"
  echo "  Total:        $((uncompressed_count + compressed_count)) files, $(format_size $total_size)"
  echo
  
  retention_count="${LOG_RETENTION_COUNT:-100}"
  if [[ "$uncompressed_count" -gt "$retention_count" ]]; then
    excess=$((uncompressed_count - retention_count))
    echo "  ⚠️  $excess uncompressed logs exceed retention limit ($retention_count)"
    echo "     run: ./agent_factory/log_rotate.sh"
  else
    echo "  ✅ log rotation: healthy ($uncompressed_count/$retention_count uncompressed)"
  fi
  echo
  exit 0
fi

if [[ "$SHOW_CLEANUP" == "1" ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Logs Eligible for Cleanup"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  
  retention_count="${LOG_RETENTION_COUNT:-100}"
  deletion_age_days="${LOG_DELETION_AGE_DAYS:-90}"
  now_epoch="$(date +%s)"
  deletion_threshold=$((now_epoch - deletion_age_days * 86400))
  
  # find logs beyond retention count
  log_files=()
  while IFS= read -r -d '' log_file; do
    log_files+=("$log_file")
  done < <(find "$log_dir" -type f -name '*.log' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null || true)
  
  compressed_files=()
  while IFS= read -r -d '' compressed_file; do
    compressed_files+=("$compressed_file")
  done < <(find "$log_dir" -type f -name '*.log.gz' -print0 2>/dev/null)
  
  excess_count=0
  old_compressed_count=0
  
  if [[ ${#log_files[@]} -gt $retention_count ]]; then
    excess_count=$((${#log_files[@]} - retention_count))
    echo "  Uncompressed logs beyond retention ($retention_count):"
    for ((i=retention_count; i<${#log_files[@]} && i<retention_count+10; i++)); do
      log_file="${log_files[$i]}"
      log_name="$(basename "$log_file")"
      if [[ "$(uname)" == "Darwin" ]]; then
        log_time="$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$log_file" 2>/dev/null || echo 'unknown')"
      else
        log_time="$(stat -c "%y" "$log_file" 2>/dev/null | cut -d' ' -f1-2 || echo 'unknown')"
      fi
      echo "     - $log_name ($log_time)"
    done
    if [[ "$excess_count" -gt 10 ]]; then
      echo "     ... and $((excess_count - 10)) more"
    fi
    echo
  fi
  
  for compressed_file in "${compressed_files[@]}"; do
    if [[ "$(uname)" == "Darwin" ]]; then
      file_mtime="$(stat -f "%m" "$compressed_file" 2>/dev/null || echo "$now_epoch")"
    else
      file_mtime="$(stat -c "%Y" "$compressed_file" 2>/dev/null || echo "$now_epoch")"
    fi
    
    if [[ "$file_mtime" -lt "$deletion_threshold" ]]; then
      old_compressed_count=$((old_compressed_count + 1))
      if [[ "$old_compressed_count" -le 10 ]]; then
        if [[ "$old_compressed_count" -eq 1 ]]; then
          echo "  Compressed logs older than ${deletion_age_days} days:"
        fi
        comp_name="$(basename "$compressed_file")"
        if [[ "$(uname)" == "Darwin" ]]; then
          comp_time="$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$compressed_file" 2>/dev/null || echo 'unknown')"
        else
          comp_time="$(stat -c "%y" "$compressed_file" 2>/dev/null | cut -d' ' -f1-2 || echo 'unknown')"
        fi
        echo "     - $comp_name ($comp_time)"
      fi
    fi
  done
  
  if [[ "$old_compressed_count" -gt 10 ]]; then
    echo "     ... and $((old_compressed_count - 10)) more"
  fi
  
  if [[ "$excess_count" -eq 0 ]] && [[ "$old_compressed_count" -eq 0 ]]; then
    echo "  ✅ no logs eligible for cleanup"
  else
    echo
    echo "  To clean up:"
    if [[ "$excess_count" -gt 0 ]]; then
      echo "     ./agent_factory/log_rotate.sh  # compress excess logs"
    fi
    if [[ "$old_compressed_count" -gt 0 ]]; then
      echo "     ./agent_factory/log_rotate.sh  # delete old compressed logs"
    fi
  fi
  echo
  exit 0
fi

if [[ "$SHOW_ERRORS" == "1" ]] || [[ -n "$ERROR_TYPE" ]]; then
  if [[ -n "$ERROR_TYPE" ]]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Logs with error type: $ERROR_TYPE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  else
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Logs with error patterns"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  fi
  echo
  
  # define error patterns by type
  declare -A error_patterns_map
  error_patterns_map[rate_limit]="rate limit|429|quota|throttled|rate.*exceeded"
  error_patterns_map[timeout]="TIMEOUT:|execution.*timeout|exceeded.*timeout"
  error_patterns_map[need_info]="NEED-INFO|NEED INFO|need-info"
  error_patterns_map[empty_output]="empty agent output|empty output|log file size.*0"
  error_patterns_map[network_error]="connection.*refused|connection.*reset|network.*error|502|503|504"
  
  if [[ -n "$ERROR_TYPE" ]]; then
    if [[ -n "${error_patterns_map[$ERROR_TYPE]:-}" ]]; then
      error_patterns=("${error_patterns_map[$ERROR_TYPE]}")
    else
      echo "error: unknown error type '$ERROR_TYPE'" >&2
      echo "valid types: rate_limit, timeout, need_info, empty_output, network_error" >&2
      exit 1
    fi
  else
    error_patterns=("NEED-INFO" "empty agent output" "rate limit" "ActionRequiredError" "failed to process" "TIMEOUT:" "ERROR:")
  fi
  
  found_count=0
  
  while IFS= read -r log_file; do
    [[ -z "$log_file" ]] && continue
    [[ ! -f "$log_file" ]] && continue
    
    # apply filters
    if ! matches_filters "$log_file"; then
      continue
    fi
    
    # check if compressed
    if [[ "$log_file" == *.gz ]]; then
      matches="$(gunzip -c "$log_file" 2>/dev/null | grep -qiE "$(IFS='|'; echo "${error_patterns[*]}")" && echo "1" || echo "0")"
    else
      matches="$(grep -qiE "$(IFS='|'; echo "${error_patterns[*]}")" "$log_file" 2>/dev/null && echo "1" || echo "0")"
    fi
    
    if [[ "$matches" == "1" ]]; then
      found_count=$((found_count + 1))
      log_name="$(basename "$log_file")"
      echo "  ❌ $log_name"
    fi
  done < <(find "$log_dir" -type f \( -name '*.log' -o -name '*.log.gz' \) -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null || true)
  
  if [[ "$found_count" -eq 0 ]]; then
    echo "  ✅ No error patterns found in logs"
  else
    echo
    echo "  Found $found_count log file(s) with error patterns"
  fi
  echo
  exit 0
fi

if [[ -n "$GREP_PATTERN" ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Searching for: $GREP_PATTERN"
  if [[ -n "$TASK_PATTERN" ]]; then
    echo "  Task filter: $TASK_PATTERN"
  fi
  if [[ -n "$DATE_FILTER" ]]; then
    echo "  Date filter: $DATE_FILTER"
  fi
  if [[ -n "$SINCE_DAYS" ]]; then
    echo "  Since: last $SINCE_DAYS days"
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  
  match_count=0
  
  while IFS= read -r log_file; do
    [[ -z "$log_file" ]] && continue
    [[ ! -f "$log_file" ]] && continue
    
    # apply filters
    if ! matches_filters "$log_file"; then
      continue
    fi
    
    log_name="$(basename "$log_file")"
    
    # search in file
    if [[ "$log_file" == *.gz ]]; then
      if gunzip -c "$log_file" 2>/dev/null | grep -qiE "$GREP_PATTERN" 2>/dev/null; then
        match_count=$((match_count + 1))
        echo "  📄 $log_name"
        echo "  ────────────────────────────────────────────────────────────────────────────"
        gunzip -c "$log_file" 2>/dev/null | grep -iE "$GREP_PATTERN" 2>/dev/null | head -n 5 | sed 's/^/    /'
        echo
      fi
    else
      if grep -qiE "$GREP_PATTERN" "$log_file" 2>/dev/null; then
        match_count=$((match_count + 1))
        echo "  📄 $log_name"
        echo "  ────────────────────────────────────────────────────────────────────────────"
        grep -iE "$GREP_PATTERN" "$log_file" 2>/dev/null | head -n 5 | sed 's/^/    /'
        echo
      fi
    fi
  done < <(find "$log_dir" -type f \( -name '*.log' -o -name '*.log.gz' \) -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null || true)
  
  if [[ "$match_count" -eq 0 ]]; then
    echo "  No matches found"
  else
    echo "  Found $match_count matching log file(s)"
  fi
  echo
  exit 0
fi

# default: show help if no pattern provided
if [[ -z "$GREP_PATTERN" ]] && [[ "$SHOW_ERRORS" == "0" ]] && [[ "$SHOW_RECENT" == "0" ]] && [[ "$SHOW_SIZE" == "0" ]] && [[ "$SHOW_CLEANUP" == "0" ]] && [[ -z "$TASK_PATTERN" ]] && [[ -z "$DATE_FILTER" ]] && [[ -z "$SINCE_DAYS" ]] && [[ -z "$ERROR_TYPE" ]]; then
  cat <<'EOF'
usage: ./agent_factory/log_search.sh [options] [pattern]

options:
  --all              search in all logs (including compressed .gz files)
  --errors            find logs containing error patterns
  --recent N          show recent N log files (default: 10)
  --grep PATTERN      grep for pattern across all logs
  --size              show log file sizes and disk usage
  --cleanup           show logs that can be safely deleted (older than retention)
  --task PATTERN      filter logs by task name pattern
  --date YYYY-MM-DD   filter logs by date (YYYY-MM-DD format)
  --since DAYS        show logs from last N days
  --min-size MB       filter logs by minimum size (MB)
  --max-size MB       filter logs by maximum size (MB)
  --error-type TYPE   filter logs by error type (rate_limit, timeout, need_info, empty_output, network_error)
  -h, --help          show this help

examples:
  ./agent_factory/log_search.sh "NEED-INFO"
  ./agent_factory/log_search.sh --all "rate limit"
  ./agent_factory/log_search.sh --errors
  ./agent_factory/log_search.sh --recent 5
  ./agent_factory/log_search.sh --grep "TIMEOUT"
  ./agent_factory/log_search.sh --size
  ./agent_factory/log_search.sh --cleanup
  ./agent_factory/log_search.sh --task "fix_linting"
  ./agent_factory/log_search.sh --date 2026-01-19
  ./agent_factory/log_search.sh --since 7
  ./agent_factory/log_search.sh --min-size 10 --max-size 100
  ./agent_factory/log_search.sh --error-type timeout
EOF
  exit 0
fi
