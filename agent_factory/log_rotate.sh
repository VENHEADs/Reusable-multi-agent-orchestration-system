#!/usr/bin/env bash
set -euo pipefail

# log_rotate.sh - rotate and compress old agent run logs
#
# this script:
# - keeps the most recent N log files uncompressed (configurable via LOG_RETENTION_COUNT)
# - compresses logs older than LOG_COMPRESSION_AGE_DAYS
# - deletes compressed logs older than LOG_DELETION_AGE_DAYS
#
# usage: ./agent_factory/log_rotate.sh [--dry-run] [--verbose]

AGENT_FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$AGENT_FACTORY_DIR/.." && pwd)"

if [[ -f "${AGENT_FACTORY_DIR}/config.sh" ]]; then
  source "${AGENT_FACTORY_DIR}/config.sh"
fi

DRY_RUN="${1:-}"
VERBOSE="0"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN="1"
  shift
fi
if [[ "${1:-}" == "--verbose" ]] || [[ "${2:-}" == "--verbose" ]]; then
  VERBOSE="1"
fi

log_dir="${REPO_ROOT}/${AGENT_RUNS_LOG_DIR}"
if [[ ! -d "$log_dir" ]]; then
  exit 0
fi

# validate log directory is writable
if [[ ! -w "$log_dir" ]]; then
  echo "error: log directory is not writable: $log_dir" >&2
  exit 1
fi

# lock file to prevent concurrent rotations (non-blocking)
lock_file="${log_dir}/.log_rotate.lock"
if [[ "$DRY_RUN" != "1" ]]; then
  # try to acquire lock (non-blocking)
  if command -v flock >/dev/null 2>&1; then
    # use flock if available (more robust)
    exec 200>"${lock_file}"
    if ! flock -n 200; then
      # another rotation is in progress, exit silently (non-blocking)
      exit 0
    fi
    # cleanup function to remove lock on exit
    cleanup_lock() {
      flock -u 200 2>/dev/null || true
      rm -f "$lock_file" 2>/dev/null || true
    }
    trap cleanup_lock EXIT
  else
    # fallback: check if lock file exists and is recent (within last 5 minutes)
    if [[ -f "$lock_file" ]]; then
      lock_age=0
      if [[ "$(uname)" == "Darwin" ]]; then
        lock_mtime="$(stat -f "%m" "$lock_file" 2>/dev/null || echo "0")"
      else
        lock_mtime="$(stat -c "%Y" "$lock_file" 2>/dev/null || echo "0")"
      fi
      now_epoch="$(date +%s)"
      lock_age=$((now_epoch - lock_mtime))
      if [[ "$lock_age" -lt 300 ]]; then
        # lock is recent, another rotation is likely in progress
        exit 0
      fi
      # lock is stale, remove it
      rm -f "$lock_file"
    fi
    # create lock file
    echo "$$" > "$lock_file"
    
    # cleanup function to remove lock on exit
    cleanup_lock() {
      rm -f "$lock_file" 2>/dev/null || true
    }
    trap cleanup_lock EXIT
  fi
fi

retention_count="${LOG_RETENTION_COUNT:-100}"
compression_enabled="${LOG_COMPRESSION_ENABLED:-1}"
compression_age_days="${LOG_COMPRESSION_AGE_DAYS:-7}"
deletion_age_days="${LOG_DELETION_AGE_DAYS:-90}"
max_directory_size_mb="${LOG_MAX_DIRECTORY_SIZE_MB:-0}"
active_grace_secs="${LOG_ACTIVE_GRACE_SECS:-5}"

# validate gzip is available if compression is enabled (check early)
if [[ "$compression_enabled" == "1" ]] && ! command -v gzip >/dev/null 2>&1; then
  echo "error: gzip is required for log compression but not found in PATH" >&2
  exit 1
fi

# get current timestamp for age calculations
now_epoch="$(date +%s)"
compression_threshold=$((now_epoch - compression_age_days * 86400))
deletion_threshold=$((now_epoch - deletion_age_days * 86400))

# check if a log file is actively being written
is_active_log() {
  local log_file="$1"
  if command -v lsof >/dev/null 2>&1; then
    if lsof "$log_file" >/dev/null 2>&1; then
      return 0
    fi
  fi
  local file_size_before=0
  local file_size_after=0
  if [[ "$(uname)" == "Darwin" ]]; then
    file_size_before="$(stat -f "%z" "$log_file" 2>/dev/null || echo "0")"
  else
    file_size_before="$(stat -c "%s" "$log_file" 2>/dev/null || echo "0")"
  fi
  sleep 0.2
  if [[ "$(uname)" == "Darwin" ]]; then
    file_size_after="$(stat -f "%z" "$log_file" 2>/dev/null || echo "0")"
  else
    file_size_after="$(stat -c "%s" "$log_file" 2>/dev/null || echo "0")"
  fi
  if [[ "$file_size_before" != "$file_size_after" ]]; then
    return 0
  fi
  local file_mtime=0
  if [[ "$(uname)" == "Darwin" ]]; then
    file_mtime="$(stat -f "%m" "$log_file" 2>/dev/null || echo "0")"
  else
    file_mtime="$(stat -c "%Y" "$log_file" 2>/dev/null || echo "0")"
  fi
  local age=$((now_epoch - file_mtime))
  if [[ "$age" -lt "$active_grace_secs" ]]; then
    return 0
  fi
  return 1
}

# find all .log files (uncompressed)
log_files=()
while IFS= read -r log_file; do
  [[ -z "$log_file" ]] && continue
  log_files+=("$log_file")
done < <(find "$log_dir" -type f -name '*.log' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null || true)

# find all .log.gz files (compressed)
compressed_files=()
while IFS= read -r -d '' compressed_file; do
  compressed_files+=("$compressed_file")
done < <(find "$log_dir" -type f -name '*.log.gz' -print0 2>/dev/null)

# calculate current directory size (for size-based rotation)
current_directory_size_mb=0
size_exceeded="0"
if [[ "$max_directory_size_mb" -gt 0 ]]; then
  current_directory_size_bytes=0
  while IFS= read -r -d '' log_file; do
    if [[ "$(uname)" == "Darwin" ]]; then
      file_size="$(stat -f "%z" "$log_file" 2>/dev/null || echo "0")"
    else
      file_size="$(stat -c "%s" "$log_file" 2>/dev/null || echo "0")"
    fi
    current_directory_size_bytes=$((current_directory_size_bytes + file_size))
  done < <(find "$log_dir" -type f \( -name '*.log' -o -name '*.log.gz' \) -print0 2>/dev/null || true)
  current_directory_size_mb=$((current_directory_size_bytes / 1048576))
  if [[ "$current_directory_size_mb" -gt "$max_directory_size_mb" ]]; then
    size_exceeded="1"
  fi
fi

# quick check: skip rotation if not needed (performance optimization)
# only proceed if we have files to compress or delete
needs_rotation="0"
if [[ "$compression_enabled" == "1" ]] && { [[ ${#log_files[@]} -gt $retention_count ]] || [[ "$size_exceeded" == "1" ]]; }; then
  needs_rotation="1"
fi
if [[ "$size_exceeded" == "1" ]]; then
  needs_rotation="1"
fi
if [[ ${#compressed_files[@]} -gt 0 ]]; then
  # check if any compressed files are old enough to delete
  for compressed_file in "${compressed_files[@]}"; do
    if [[ "$(uname)" == "Darwin" ]]; then
      file_mtime="$(stat -f "%m" "$compressed_file" 2>/dev/null || echo "$now_epoch")"
    else
      file_mtime="$(stat -c "%Y" "$compressed_file" 2>/dev/null || echo "$now_epoch")"
    fi
    if [[ "$file_mtime" -lt "$deletion_threshold" ]]; then
      needs_rotation="1"
      break
    fi
  done
fi

# exit early if no rotation needed (unless verbose mode)
if [[ "$needs_rotation" == "0" ]] && [[ "$VERBOSE" != "1" ]] && [[ "$DRY_RUN" != "1" ]]; then
  exit 0
fi

compressed_count=0
deleted_count=0
skipped_count=0
total_size_before=0
total_size_after=0

# compress old log files
if [[ "$compression_enabled" == "1" ]] && { [[ ${#log_files[@]} -gt $retention_count ]] || [[ "$size_exceeded" == "1" ]]; }; then
  keep_recent_count="$retention_count"
  if [[ "$size_exceeded" == "1" ]] && [[ ${#log_files[@]} -le $retention_count ]]; then
    keep_recent_count=1
  fi
  if [[ "$keep_recent_count" -lt 1 ]]; then
    keep_recent_count=1
  fi
  # skip the most recent N files, compress the rest
  for ((i=keep_recent_count; i<${#log_files[@]}; i++)); do
    log_file="${log_files[$i]}"
    
    # check file age
    if [[ "$(uname)" == "Darwin" ]]; then
      file_mtime="$(stat -f "%m" "$log_file" 2>/dev/null || echo "$now_epoch")"
    else
      file_mtime="$(stat -c "%Y" "$log_file" 2>/dev/null || echo "$now_epoch")"
    fi
    
    # compress if older than threshold OR if we have too many files OR if size limit exceeded
    should_compress="0"
    if [[ "$file_mtime" -lt "$compression_threshold" ]]; then
      should_compress="1"
    elif [[ ${#log_files[@]} -gt $((retention_count * 2)) ]]; then
      # if we have more than 2x retention count, compress even recent files to prevent unbounded growth
      should_compress="1"
    elif [[ "$size_exceeded" == "1" ]]; then
      # if directory size limit exceeded, compress regardless of age
      should_compress="1"
    fi
    
    if [[ "$should_compress" == "1" ]]; then
      compressed_file="${log_file}.gz"
      
      # skip if already compressed
      if [[ -f "$compressed_file" ]]; then
        skipped_count=$((skipped_count + 1))
        continue
      fi
      
      # calculate size before compression for reporting
      orig_file_size=0
      if [[ "$DRY_RUN" != "1" ]] || [[ "$VERBOSE" == "1" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
          orig_file_size="$(stat -f "%z" "$log_file" 2>/dev/null || echo "0")"
        else
          orig_file_size="$(stat -c "%s" "$log_file" 2>/dev/null || echo "0")"
        fi
        total_size_before=$((total_size_before + orig_file_size))
      fi
      
      # skip if file is currently being written or locked
      if [[ "$DRY_RUN" != "1" ]]; then
        if is_active_log "$log_file"; then
          skipped_count=$((skipped_count + 1))
          if [[ "$VERBOSE" == "1" ]]; then
            echo "skipping active file: $(basename "$log_file")" >&2
          fi
          continue
        fi
      fi
      
      if [[ "$DRY_RUN" == "1" ]]; then
        if [[ "$VERBOSE" == "1" ]]; then
          echo "[DRY RUN] would compress: $(basename "$log_file")"
        fi
        compressed_count=$((compressed_count + 1))
      else
        # use gzip with best effort (don't fail if file is being written)
        if gzip -q "$log_file" 2>/dev/null; then
          compressed_count=$((compressed_count + 1))
          # calculate compressed size for reporting
          if [[ "$VERBOSE" == "1" ]]; then
            compressed_size=0
            if [[ "$(uname)" == "Darwin" ]]; then
              compressed_size="$(stat -f "%z" "$compressed_file" 2>/dev/null || echo "0")"
            else
              compressed_size="$(stat -c "%s" "$compressed_file" 2>/dev/null || echo "0")"
            fi
            total_size_after=$((total_size_after + compressed_size))
            saved=$((orig_file_size - compressed_size))
            saved_pct=0
            if [[ "$orig_file_size" -gt 0 ]]; then
              saved_pct=$((saved * 100 / orig_file_size))
            fi
            echo "compressed: $(basename "$log_file") (saved ${saved_pct}%)" >&2
          fi
        else
          # log compression failure but continue
          echo "warning: failed to compress $(basename "$log_file")" >&2
          skipped_count=$((skipped_count + 1))
        fi
      fi
    fi
  done
fi

# delete old uncompressed logs when compression is disabled
if [[ "$compression_enabled" != "1" ]] && [[ ${#log_files[@]} -gt $retention_count ]]; then
  for ((i=retention_count; i<${#log_files[@]}; i++)); do
    log_file="${log_files[$i]}"
    if [[ "$DRY_RUN" != "1" ]] && is_active_log "$log_file"; then
      skipped_count=$((skipped_count + 1))
      if [[ "$VERBOSE" == "1" ]]; then
        echo "skipping active file: $(basename "$log_file")" >&2
      fi
      continue
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
      if [[ "$VERBOSE" == "1" ]]; then
        echo "[DRY RUN] would delete: $(basename "$log_file")"
      fi
      deleted_count=$((deleted_count + 1))
    else
      if rm -f "$log_file" 2>/dev/null; then
        deleted_count=$((deleted_count + 1))
      else
        echo "warning: failed to delete $(basename "$log_file")" >&2
      fi
    fi
  done
fi

# delete old compressed logs
for compressed_file in "${compressed_files[@]}"; do
  if [[ "$(uname)" == "Darwin" ]]; then
    file_mtime="$(stat -f "%m" "$compressed_file" 2>/dev/null || echo "$now_epoch")"
  else
    file_mtime="$(stat -c "%Y" "$compressed_file" 2>/dev/null || echo "$now_epoch")"
  fi
  
  if [[ "$file_mtime" -lt "$deletion_threshold" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[DRY RUN] would delete: $(basename "$compressed_file")"
      deleted_count=$((deleted_count + 1))
    else
      if rm -f "$compressed_file" 2>/dev/null; then
        deleted_count=$((deleted_count + 1))
      else
        echo "warning: failed to delete $(basename "$compressed_file")" >&2
      fi
    fi
  fi
done

# remove empty date directories after rotation
if [[ "$DRY_RUN" != "1" ]]; then
  while IFS= read -r -d '' empty_dir; do
    rmdir "$empty_dir" 2>/dev/null || true
  done < <(find "$log_dir" -mindepth 1 -type d -empty -print0 2>/dev/null || true)
fi

# format size helper
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

# calculate total size saved
total_saved=$((total_size_before - total_size_after))

if [[ "$DRY_RUN" != "1" ]]; then
  if [[ "$compressed_count" -gt 0 ]] || [[ "$deleted_count" -gt 0 ]]; then
    echo "log rotation complete:" >&2
    echo "  compressed: $compressed_count files" >&2
    if [[ "$deleted_count" -gt 0 ]]; then
      echo "  deleted: $deleted_count old compressed files" >&2
    fi
    if [[ "$skipped_count" -gt 0 ]]; then
      echo "  skipped: $skipped_count files (active or already compressed)" >&2
    fi
    if [[ "$total_saved" -gt 0 ]] && [[ "$VERBOSE" == "1" ]]; then
      echo "  disk space saved: $(format_size $total_saved)" >&2
    fi
    if [[ "$max_directory_size_mb" -gt 0 ]] && [[ "$VERBOSE" == "1" ]]; then
      echo "  directory size: ${current_directory_size_mb}MB / ${max_directory_size_mb}MB" >&2
    fi
  elif [[ "$VERBOSE" == "1" ]]; then
    size_info=""
    if [[ "$max_directory_size_mb" -gt 0 ]]; then
      size_info=" (${current_directory_size_mb}MB / ${max_directory_size_mb}MB)"
    fi
    echo "log rotation: no action needed (${#log_files[@]} uncompressed, ${#compressed_files[@]} compressed${size_info})" >&2
  fi
else
  if [[ "$compressed_count" -gt 0 ]] || [[ "$deleted_count" -gt 0 ]]; then
    echo "[DRY RUN] would compress $compressed_count files, delete $deleted_count old compressed files"
    if [[ "$skipped_count" -gt 0 ]]; then
      echo "[DRY RUN] would skip $skipped_count files (active or already compressed)"
    fi
    if [[ "$total_saved" -gt 0 ]]; then
      echo "[DRY RUN] estimated disk space saved: $(format_size $total_saved)"
    fi
  else
    echo "[DRY RUN] no rotation needed (${#log_files[@]} uncompressed, ${#compressed_files[@]} compressed)"
  fi
fi
