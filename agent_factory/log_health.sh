#!/usr/bin/env bash
set -euo pipefail

# log_health.sh - check log rotation health and configuration
#
# this script verifies that log rotation is working correctly and
# provides recommendations for optimal log management
#
# usage: ./agent_factory/log_health.sh [--verbose]

AGENT_FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$AGENT_FACTORY_DIR/.." && pwd)"

if [[ -f "${AGENT_FACTORY_DIR}/config.sh" ]]; then
  source "${AGENT_FACTORY_DIR}/config.sh"
fi

VERBOSE="${1:-}"
if [[ "${1:-}" == "--verbose" ]]; then
  VERBOSE="1"
fi

log_dir="${REPO_ROOT}/${AGENT_RUNS_LOG_DIR}"
retention_count="${LOG_RETENTION_COUNT:-100}"
compression_enabled="${LOG_COMPRESSION_ENABLED:-1}"
compression_age_days="${LOG_COMPRESSION_AGE_DAYS:-7}"
deletion_age_days="${LOG_DELETION_AGE_DAYS:-90}"
max_directory_size_mb="${LOG_MAX_DIRECTORY_SIZE_MB:-0}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Log Rotation Health Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# check log directory exists
if [[ ! -d "$log_dir" ]]; then
  echo "  ⚠️  log directory does not exist: $log_dir"
  echo "     (this is normal if no agent runs have occurred yet)"
  echo
  exit 0
fi

# check log directory is writable
if [[ ! -w "$log_dir" ]]; then
  echo "  ❌ log directory is not writable: $log_dir"
  echo "     fix: chmod u+w $log_dir"
  echo
  exit 1
fi

# check gzip is available if compression is enabled
if [[ "$compression_enabled" == "1" ]] && ! command -v gzip >/dev/null 2>&1; then
  echo "  ❌ compression is enabled but gzip is not available"
  echo "     fix: install gzip or set LOG_COMPRESSION_ENABLED=0 in config.sh"
  echo
  exit 1
fi

# count log files
uncompressed_count=0
compressed_count=0
uncompressed_size_kb=0
compressed_size_kb=0

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
    compressed_size_kb=$((compressed_size_kb + file_size / 1024))
  else
    uncompressed_count=$((uncompressed_count + 1))
    if [[ "$(uname)" == "Darwin" ]]; then
      file_size="$(stat -f "%z" "$log_file" 2>/dev/null || echo 0)"
    else
      file_size="$(stat -c "%s" "$log_file" 2>/dev/null || echo 0)"
    fi
    uncompressed_size_kb=$((uncompressed_size_kb + file_size / 1024))
  fi
done < <(find "$log_dir" -maxdepth 1 -type f \( -name '*.log' -o -name '*.log.gz' \) -print0 2>/dev/null || true)

total_count=$((uncompressed_count + compressed_count))
total_size_kb=$((uncompressed_size_kb + compressed_size_kb))

# format sizes
format_size() {
  local kb="$1"
  if [[ "$kb" -lt 1024 ]]; then
    echo "${kb}KB"
  elif [[ "$kb" -lt 1048576 ]]; then
    echo "$((kb / 1024))MB"
  else
    echo "$((kb / 1048576))GB"
  fi
}

# check health status
health_status="healthy"
warnings=""
recommendations=""

# check uncompressed count
if [[ "$uncompressed_count" -gt $((retention_count * 2)) ]]; then
  health_status="critical"
  excess=$((uncompressed_count - retention_count))
  warnings="${warnings}${warnings:+$'\n'}  ❌ $excess uncompressed logs exceed retention limit (${retention_count})"
  recommendations="${recommendations}${recommendations:+$'\n'}  - run: ./agent_factory/log_rotate.sh"
elif [[ "$uncompressed_count" -gt "$retention_count" ]]; then
  if [[ "$health_status" == "healthy" ]]; then
    health_status="warning"
  fi
  excess=$((uncompressed_count - retention_count))
  warnings="${warnings}${warnings:+$'\n'}  ⚠️  $excess uncompressed logs exceed retention limit (${retention_count})"
  recommendations="${recommendations}${recommendations:+$'\n'}  - run: ./agent_factory/log_rotate.sh"
fi

# check directory size
if [[ "$max_directory_size_mb" -gt 0 ]]; then
  total_size_mb=$((total_size_kb / 1024))
  if [[ "$total_size_mb" -gt "$max_directory_size_mb" ]]; then
    health_status="critical"
    excess_mb=$((total_size_mb - max_directory_size_mb))
    warnings="${warnings}${warnings:+$'\n'}  ❌ log directory size (${total_size_mb}MB) exceeds limit (${max_directory_size_mb}MB) by ${excess_mb}MB"
    recommendations="${recommendations}${recommendations:+$'\n'}  - run: ./agent_factory/log_rotate.sh"
  elif [[ "$total_size_mb" -gt $((max_directory_size_mb * 80 / 100)) ]]; then
    if [[ "$health_status" == "healthy" ]]; then
      health_status="warning"
    fi
    warnings="${warnings}${warnings:+$'\n'}  ⚠️  log directory size (${total_size_mb}MB) approaching limit (${max_directory_size_mb}MB)"
  fi
fi

# check for old compressed logs
now_epoch="$(date +%s)"
deletion_threshold=$((now_epoch - deletion_age_days * 86400))
old_compressed=0

while IFS= read -r compressed_file; do
  [[ -z "$compressed_file" ]] && continue
  [[ ! -f "$compressed_file" ]] && continue
  
  if [[ "$(uname)" == "Darwin" ]]; then
    file_mtime="$(stat -f "%m" "$compressed_file" 2>/dev/null || echo "$now_epoch")"
  else
    file_mtime="$(stat -c "%Y" "$compressed_file" 2>/dev/null || echo "$now_epoch")"
  fi
  
  if [[ "$file_mtime" -lt "$deletion_threshold" ]]; then
    old_compressed=$((old_compressed + 1))
  fi
done < <(find "$log_dir" -maxdepth 1 -type f -name '*.log.gz' -print0 2>/dev/null || true)

if [[ "$old_compressed" -gt 0 ]]; then
  if [[ "$health_status" == "healthy" ]]; then
    health_status="warning"
  fi
  warnings="${warnings}${warnings:+$'\n'}  ⚠️  $old_compressed compressed logs older than ${deletion_age_days} days (eligible for deletion)"
  recommendations="${recommendations}${recommendations:+$'\n'}  - run: ./agent_factory/log_rotate.sh"
fi

# show status
case "$health_status" in
  healthy)
    echo "  ✅ Status: HEALTHY"
    ;;
  warning)
    echo "  ⚠️  Status: WARNING"
    ;;
  critical)
    echo "  ❌ Status: CRITICAL"
    ;;
esac
echo

# show statistics
echo "  Statistics:"
echo "     total logs: $total_count ($uncompressed_count uncompressed, $compressed_count compressed)"
echo "     disk usage: $(format_size $total_size_kb) (uncompressed: $(format_size $uncompressed_size_kb), compressed: $(format_size $compressed_size_kb))"
echo

# show configuration
echo "  Configuration:"
echo "     retention: $retention_count uncompressed logs"
echo "     compression: $([ "$compression_enabled" == "1" ] && echo "enabled" || echo "disabled")"
if [[ "$compression_enabled" == "1" ]]; then
  echo "     compress after: ${compression_age_days} days"
fi
echo "     delete after: ${deletion_age_days} days"
if [[ "$max_directory_size_mb" -gt 0 ]]; then
  echo "     max directory size: ${max_directory_size_mb}MB"
fi
echo

# show warnings
if [[ -n "$warnings" ]]; then
  echo "  Issues:"
  echo "$warnings"
  echo
fi

# show recommendations
if [[ -n "$recommendations" ]]; then
  echo "  Recommendations:"
  echo "$recommendations"
  echo
fi

# show rotation script status
if [[ -f "${AGENT_FACTORY_DIR}/log_rotate.sh" ]] && [[ -x "${AGENT_FACTORY_DIR}/log_rotate.sh" ]]; then
  echo "  ✅ log rotation script is available and executable"
else
  echo "  ❌ log rotation script is missing or not executable"
  echo "     expected: ${AGENT_FACTORY_DIR}/log_rotate.sh"
fi
echo

# verbose mode: show recent log files
if [[ "$VERBOSE" == "1" ]]; then
  echo "  Recent log files (last 10):"
  count=0
  while IFS= read -r log_file; do
    [[ -z "$log_file" ]] && continue
    [[ ! -f "$log_file" ]] && continue
    [[ "$count" -ge 10 ]] && break
    
    count=$((count + 1))
    log_name="$(basename "$log_file")"
    if [[ "$(uname)" == "Darwin" ]]; then
      log_time="$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$log_file" 2>/dev/null || echo 'unknown')"
      log_size="$(stat -f "%z" "$log_file" 2>/dev/null || echo 0)"
    else
      log_time="$(stat -c "%y" "$log_file" 2>/dev/null | cut -d' ' -f1-2 || echo 'unknown')"
      log_size="$(stat -c "%s" "$log_file" 2>/dev/null || echo 0)"
    fi
    
    size_str=""
    if [[ "$log_size" -lt 1024 ]]; then
      size_str="${log_size}B"
    elif [[ "$log_size" -lt 1048576 ]]; then
      size_str="$((log_size / 1024))KB"
    else
      size_str="$((log_size / 1048576))MB"
    fi
    
    echo "     [$count] $log_name ($log_time, $size_str)"
  done < <(find "$log_dir" -maxdepth 1 -type f \( -name '*.log' -o -name '*.log.gz' \) -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null || true)
  echo
fi

# exit with appropriate code
case "$health_status" in
  healthy)
    exit 0
    ;;
  warning)
    exit 0
    ;;
  critical)
    exit 1
    ;;
esac
