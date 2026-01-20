#!/usr/bin/env bash
set -euo pipefail

# log_cleanup.sh - interactive log cleanup helper
#
# this script helps safely clean up old logs with interactive confirmation
#
# usage: ./agent_factory/log_cleanup.sh [--dry-run] [--force]

AGENT_FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$AGENT_FACTORY_DIR/.." && pwd)"

if [[ -f "${AGENT_FACTORY_DIR}/config.sh" ]]; then
  source "${AGENT_FACTORY_DIR}/config.sh"
fi

DRY_RUN="${1:-}"
FORCE="${2:-}"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN="1"
  shift
fi
if [[ "${1:-}" == "--force" ]] || [[ "${2:-}" == "--force" ]]; then
  FORCE="1"
fi

log_dir="${REPO_ROOT}/${AGENT_RUNS_LOG_DIR}"
if [[ ! -d "$log_dir" ]]; then
  echo "log directory not found: $log_dir" >&2
  exit 1
fi

retention_count="${LOG_RETENTION_COUNT:-100}"
deletion_age_days="${LOG_DELETION_AGE_DAYS:-90}"
max_directory_size_mb="${LOG_MAX_DIRECTORY_SIZE_MB:-0}"

now_epoch="$(date +%s)"
deletion_threshold=$((now_epoch - deletion_age_days * 86400))

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Log Cleanup Helper"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# find logs beyond retention count
log_files=()
while IFS= read -r log_file; do
  [[ -z "$log_file" ]] && continue
  log_files+=("$log_file")
done < <(find "$log_dir" -type f -name '*.log' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null || true)

# find old compressed logs
compressed_files=()
while IFS= read -r -d '' compressed_file; do
  compressed_files+=("$compressed_file")
done < <(find "$log_dir" -type f -name '*.log.gz' -print0 2>/dev/null)

excess_logs=()
if [[ ${#log_files[@]} -gt $retention_count ]]; then
  for ((i=retention_count; i<${#log_files[@]}; i++)); do
    excess_logs+=("${log_files[$i]}")
  done
fi

old_compressed=()
for compressed_file in "${compressed_files[@]}"; do
  if [[ "$(uname)" == "Darwin" ]]; then
    file_mtime="$(stat -f "%m" "$compressed_file" 2>/dev/null || echo "$now_epoch")"
  else
    file_mtime="$(stat -c "%Y" "$compressed_file" 2>/dev/null || echo "$now_epoch")"
  fi
  
  if [[ "$file_mtime" -lt "$deletion_threshold" ]]; then
    old_compressed+=("$compressed_file")
  fi
done

# calculate total size to be freed
total_size_to_free=0
for log_file in "${excess_logs[@]}"; do
  if [[ "$(uname)" == "Darwin" ]]; then
    file_size="$(stat -f "%z" "$log_file" 2>/dev/null || echo "0")"
  else
    file_size="$(stat -c "%s" "$log_file" 2>/dev/null || echo "0")"
  fi
  total_size_to_free=$((total_size_to_free + file_size))
done

for compressed_file in "${old_compressed[@]}"; do
  if [[ "$(uname)" == "Darwin" ]]; then
    file_size="$(stat -f "%z" "$compressed_file" 2>/dev/null || echo "0")"
  else
    file_size="$(stat -c "%s" "$compressed_file" 2>/dev/null || echo "0")"
  fi
  total_size_to_free=$((total_size_to_free + file_size))
done

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

if [[ ${#excess_logs[@]} -eq 0 ]] && [[ ${#old_compressed[@]} -eq 0 ]]; then
  echo "  ✅ no logs eligible for cleanup"
  echo
  echo "  Current status:"
  echo "     uncompressed logs: ${#log_files[@]} (retention: $retention_count)"
  echo "     compressed logs: ${#compressed_files[@]}"
  echo "     old compressed logs (>${deletion_age_days} days): ${#old_compressed[@]}"
  echo
  exit 0
fi

echo "  Logs eligible for cleanup:"
echo "     uncompressed logs beyond retention: ${#excess_logs[@]} (retention: $retention_count)"
echo "     old compressed logs (>${deletion_age_days} days): ${#old_compressed[@]}"
echo "     total disk space to free: $(format_size $total_size_to_free)"
echo

if [[ ${#excess_logs[@]} -gt 0 ]]; then
  echo "  Uncompressed logs beyond retention (showing first 10):"
  for ((i=0; i<${#excess_logs[@]} && i<10; i++)); do
    log_file="${excess_logs[$i]}"
    log_name="$(basename "$log_file")"
    if [[ "$(uname)" == "Darwin" ]]; then
      log_time="$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$log_file" 2>/dev/null || echo 'unknown')"
    else
      log_time="$(stat -c "%y" "$log_file" 2>/dev/null | cut -d' ' -f1-2 || echo 'unknown')"
    fi
    echo "     - $log_name ($log_time)"
  done
  if [[ ${#excess_logs[@]} -gt 10 ]]; then
    echo "     ... and $(( ${#excess_logs[@]} - 10)) more"
  fi
  echo
fi

if [[ ${#old_compressed[@]} -gt 0 ]]; then
  echo "  Old compressed logs (showing first 10):"
  for ((i=0; i<${#old_compressed[@]} && i<10; i++)); do
    compressed_file="${old_compressed[$i]}"
    comp_name="$(basename "$compressed_file")"
    if [[ "$(uname)" == "Darwin" ]]; then
      comp_time="$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$compressed_file" 2>/dev/null || echo 'unknown')"
    else
      comp_time="$(stat -c "%y" "$compressed_file" 2>/dev/null | cut -d' ' -f1-2 || echo 'unknown')"
    fi
    echo "     - $comp_name ($comp_time)"
  done
  if [[ ${#old_compressed[@]} -gt 10 ]]; then
    echo "     ... and $(( ${#old_compressed[@]} - 10)) more"
  fi
  echo
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "  [DRY RUN] would delete ${#excess_logs[@]} uncompressed logs and ${#old_compressed[@]} old compressed logs"
  echo "  [DRY RUN] would free $(format_size $total_size_to_free)"
  echo
  exit 0
fi

if [[ "$FORCE" != "1" ]]; then
  echo "  ⚠️  this will permanently delete ${#excess_logs[@]} uncompressed logs and ${#old_compressed[@]} old compressed logs"
  echo "  ⚠️  this will free $(format_size $total_size_to_free) of disk space"
  echo
  echo -n "  proceed? (yes/no): "
  read -r response
  if [[ "$response" != "yes" ]]; then
    echo "  cleanup cancelled"
    exit 0
  fi
  echo
fi

deleted_count=0
failed_count=0

echo "  cleaning up logs..."
for log_file in "${excess_logs[@]}"; do
  if rm -f "$log_file" 2>/dev/null; then
    deleted_count=$((deleted_count + 1))
  else
    failed_count=$((failed_count + 1))
    echo "  warning: failed to delete $(basename "$log_file")" >&2
  fi
done

for compressed_file in "${old_compressed[@]}"; do
  if rm -f "$compressed_file" 2>/dev/null; then
    deleted_count=$((deleted_count + 1))
  else
    failed_count=$((failed_count + 1))
    echo "  warning: failed to delete $(basename "$compressed_file")" >&2
  fi
done

while IFS= read -r -d '' empty_dir; do
  rmdir "$empty_dir" 2>/dev/null || true
done < <(find "$log_dir" -mindepth 1 -type d -empty -print0 2>/dev/null || true)

echo
if [[ "$failed_count" -eq 0 ]]; then
  echo "  ✅ cleanup complete: deleted $deleted_count files, freed $(format_size $total_size_to_free)"
else
  echo "  ⚠️  cleanup partial: deleted $deleted_count files, $failed_count failed, freed $(format_size $total_size_to_free)"
fi
echo
