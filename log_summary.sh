#!/usr/bin/env bash
set -euo pipefail

# log_summary.sh - quick overview of log status
#
# provides a concise summary of log directory status, rotation health, and recent activity
#
# usage: ./agent_factory/log_summary.sh

AGENT_FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$AGENT_FACTORY_DIR/.." && pwd)"

if [[ -f "${AGENT_FACTORY_DIR}/config.sh" ]]; then
  source "${AGENT_FACTORY_DIR}/config.sh"
fi

log_dir="${REPO_ROOT}/${AGENT_RUNS_LOG_DIR}"
retention_count="${LOG_RETENTION_COUNT:-100}"
compression_enabled="${LOG_COMPRESSION_ENABLED:-1}"
compression_age_days="${LOG_COMPRESSION_AGE_DAYS:-7}"
deletion_age_days="${LOG_DELETION_AGE_DAYS:-90}"
max_directory_size_mb="${LOG_MAX_DIRECTORY_SIZE_MB:-0}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Log Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

if [[ ! -d "$log_dir" ]]; then
  echo "  📁 log directory: $log_dir (does not exist yet)"
  echo "     (this is normal if no agent runs have occurred)"
  echo
  exit 0
fi

# count files
uncompressed_count=0
compressed_count=0
uncompressed_size_bytes=0
compressed_size_bytes=0

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
    compressed_size_bytes=$((compressed_size_bytes + file_size))
  else
    uncompressed_count=$((uncompressed_count + 1))
    if [[ "$(uname)" == "Darwin" ]]; then
      file_size="$(stat -f "%z" "$log_file" 2>/dev/null || echo 0)"
    else
      file_size="$(stat -c "%s" "$log_file" 2>/dev/null || echo 0)"
    fi
    uncompressed_size_bytes=$((uncompressed_size_bytes + file_size))
  fi
done < <(find "$log_dir" -maxdepth 1 -type f \( -name '*.log' -o -name '*.log.gz' \) -print0 2>/dev/null || true)

total_count=$((uncompressed_count + compressed_count))
total_size_bytes=$((uncompressed_size_bytes + compressed_size_bytes))

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

# health status
health_status="healthy"
if [[ "$uncompressed_count" -gt $((retention_count * 2)) ]]; then
  health_status="critical"
elif [[ "$uncompressed_count" -gt "$retention_count" ]]; then
  health_status="warning"
fi

if [[ "$max_directory_size_mb" -gt 0 ]]; then
  total_size_mb=$((total_size_bytes / 1048576))
  if [[ "$total_size_mb" -gt "$max_directory_size_mb" ]]; then
    health_status="critical"
  elif [[ "$total_size_mb" -gt $((max_directory_size_mb * 80 / 100)) ]]; then
    if [[ "$health_status" == "healthy" ]]; then
      health_status="warning"
    fi
  fi
fi

# show status
case "$health_status" in
  healthy) echo "  ✅ Status: HEALTHY" ;;
  warning) echo "  ⚠️  Status: WARNING" ;;
  critical) echo "  ❌ Status: CRITICAL" ;;
esac
echo

# show statistics
echo "  Statistics:"
echo "     total logs: $total_count ($uncompressed_count uncompressed, $compressed_count compressed)"
echo "     disk usage: $(format_size $total_size_bytes)"
if [[ "$uncompressed_size_bytes" -gt 0 ]] || [[ "$compressed_size_bytes" -gt 0 ]]; then
  echo "     breakdown: $(format_size $uncompressed_size_bytes) uncompressed, $(format_size $compressed_size_bytes) compressed"
fi
echo

# show configuration
echo "  Configuration:"
echo "     retention: $retention_count uncompressed logs"
echo "     compression: $([ "$compression_enabled" == "1" ] && echo "enabled (after ${compression_age_days} days)" || echo "disabled")"
echo "     deletion: after ${deletion_age_days} days"
if [[ "$max_directory_size_mb" -gt 0 ]]; then
  echo "     max size: ${max_directory_size_mb}MB"
fi
echo

# show warnings
if [[ "$uncompressed_count" -gt "$retention_count" ]]; then
  excess=$((uncompressed_count - retention_count))
  echo "  ⚠️  $excess uncompressed logs exceed retention limit ($retention_count)"
  echo "     run: ./agent_factory/log_rotate.sh"
  echo
fi

if [[ "$max_directory_size_mb" -gt 0 ]]; then
  total_size_mb=$((total_size_bytes / 1048576))
  if [[ "$total_size_mb" -gt "$max_directory_size_mb" ]]; then
    excess_mb=$((total_size_mb - max_directory_size_mb))
    echo "  ❌ log directory size (${total_size_mb}MB) exceeds limit (${max_directory_size_mb}MB) by ${excess_mb}MB"
    echo "     run: ./agent_factory/log_rotate.sh"
    echo
  elif [[ "$total_size_mb" -gt $((max_directory_size_mb * 80 / 100)) ]]; then
    echo "  ⚠️  log directory size (${total_size_mb}MB) approaching limit (${max_directory_size_mb}MB)"
    echo "     run: ./agent_factory/log_rotate.sh"
    echo
  fi
fi

# show recent activity
echo "  Recent activity:"
recent_logs="$(find "$log_dir" -maxdepth 1 -type f -name '*.log' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -n 5 || true)"
if [[ -n "$recent_logs" ]]; then
  count=0
  while IFS= read -r log_file; do
    [[ -z "$log_file" ]] && continue
    [[ ! -f "$log_file" ]] && continue
    [[ "$count" -ge 5 ]] && break
    
    count=$((count + 1))
    log_name="$(basename "$log_file")"
    if [[ "$(uname)" == "Darwin" ]]; then
      log_time="$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$log_file" 2>/dev/null || echo 'unknown')"
    else
      log_time="$(stat -c "%y" "$log_file" 2>/dev/null | cut -d' ' -f1-2 || echo 'unknown')"
    fi
    
    echo "     [$count] $log_name ($log_time)"
  done <<< "$recent_logs"
else
  echo "     (no recent logs)"
fi
echo

# show quick commands
echo "  Quick commands:"
echo "     ./agent_factory/log_summary.sh          # this summary"
echo "     ./agent_factory/log_health.sh            # detailed health check"
echo "     ./agent_factory/log_rotate.sh            # rotate logs now"
echo "     ./agent_factory/log_search.sh --recent 10 # show recent logs"
echo "     ./agent_factory/log_search.sh --errors   # find errors"
echo "     ./agent_factory/monitor.sh --logs         # monitor view"
echo
