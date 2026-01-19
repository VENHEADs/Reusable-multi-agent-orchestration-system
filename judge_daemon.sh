#!/usr/bin/env bash
set -euo pipefail

# deterministic judge daemon
#
# consumes tickets from tasks/judge_queue/ and either:
# - commits whitelisted paths when checks pass
# - writes/updates a single actionable blocker ticket when checks fail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SLEEP_SECS="${SLEEP_SECS:-15}"
BLOCKER_TICKET_PATH="${BLOCKER_TICKET_PATH:-.agent_factory_state/judge_blocker.md}"
JUDGE_AUTO_PUSH="${JUDGE_AUTO_PUSH:-1}"
JUDGE_PUSH_REMOTE="${JUDGE_PUSH_REMOTE:-origin}"
JUDGE_WAIVERS_FILE="${JUDGE_WAIVERS_FILE:-agent_factory/judge_waivers.json}"

JUDGE_INCLUDE_PATHS_DEFAULT="agent_factory data_prep pricing_algorithms tests pyproject.toml requirements.txt analyze_historical_coverage.py"
JUDGE_INCLUDE_PATHS="${JUDGE_INCLUDE_PATHS:-$JUDGE_INCLUDE_PATHS_DEFAULT}"

mkdir -p tasks/judge_queue/processed
mkdir -p tasks/planner_queue
mkdir -p .agent_factory_state

log_status() {
  local msg="$1"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg"
}

effective_dirty_paths() {
  /usr/bin/python3 - <<'PY'
import subprocess
from pathlib import Path

ignore_prefixes = ("logs/", "tasks/", "archive/", ".agent_factory_state/")
try:
  out = subprocess.check_output(["git", "status", "--porcelain"], text=True)
except Exception:
  raise SystemExit(0)

paths = []
for line in out.splitlines():
  line = line.rstrip("\n")
  if not line:
    continue
  # format is: XY <path> (we only need the path token)
  parts = line.split(maxsplit=1)
  if len(parts) != 2:
    continue
  p = parts[1]
  # handle rename "a -> b" by taking the destination
  if " -> " in p:
    p = p.split(" -> ", 1)[1]
  if p.startswith(ignore_prefixes):
    continue
  paths.append(p)

for p in sorted(set(paths)):
  print(p)
PY
}

has_effective_dirty() {
  [[ -n "$(effective_dirty_paths || true)" ]]
}

claim_next_ticket() {
  /usr/bin/find tasks/judge_queue -maxdepth 1 -type f -name '*.md' 2>/dev/null | /usr/bin/sort | /usr/bin/head -n 1
}

write_blocker_ticket() {
  local title="$1"
  local body="$2"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  mkdir -p "$(dirname "$BLOCKER_TICKET_PATH")"
  {
    echo "# Blocker: judge cannot commit"
    echo
    echo "updated: ${now}"
    echo
    echo "## Summary"
    printf '%s\n' "$title"
    echo
    echo "## Details"
    printf '%b\n' "$body"
    echo
    echo "## Commands to rerun locally"
    echo "- python -m pytest"
    echo "- ruff format ."
    echo "- ruff check ."
    echo
  } >"$BLOCKER_TICKET_PATH"
  log_status "blocker updated: $(basename "$BLOCKER_TICKET_PATH")"
}

ensure_planner_blocker_notice() {
  local notice_path="tasks/planner_queue/00_judge_blocker_notice.md"
  if [[ -f "$notice_path" ]]; then
    return 0
  fi
  # if planner already has any blocker notice pending, avoid duplicates
  if /usr/bin/find tasks/planner_queue -maxdepth 1 -type f -name '00_judge_blocker_notice*.md' 2>/dev/null | /usr/bin/grep -q .; then
    return 0
  fi
  cat >"$notice_path" <<EOF
# Blocker notice: judge cannot commit

## Where to look
- canonical blocker file: \`${BLOCKER_TICKET_PATH}\`

## Action
Fix the issues described in the blocker file, then let the worker continue.
EOF
}

run_cmd_capture() {
  local label="$1"
  shift
  local out_file="$1"
  shift
  set +e
  {
    echo "== ${label}"
    echo "\$ $*"
    "$@"
  } >"$out_file" 2>&1
  rc="$?"
  set -e
  return "$rc"
}

extract_pytest_failures() {
  local pytest_output_file="$1"
  if [[ ! -f "$pytest_output_file" ]]; then
    return 0
  fi

  /usr/bin/python3 - <<'PY' <"$pytest_output_file"
import re
import sys

lines = sys.stdin.read().splitlines()
if not lines:
    print("(no pytest output captured)")
    raise SystemExit(0)

def find_index(pattern: str):
    rx = re.compile(pattern)
    for i, line in enumerate(lines):
        if rx.search(line):
            return i
    return None

failures_i = find_index(r"^=+\s+FAILURES\s+=+$")
summary_i = find_index(r"^=+\s+short test summary info\s+=+$")
failed_line_i = None
for i in range(len(lines) - 1, -1, -1):
    if "FAILED" in lines[i] or "ERROR" in lines[i]:
        failed_line_i = i
        break

out: list[str] = []
out.append(f"(pytest output lines: {len(lines)})")
if failures_i is not None:
    # include up to 220 lines from FAILURES section
    out.extend(lines[failures_i : min(len(lines), failures_i + 220)])
else:
    # fallback: tail (often contains the summaries)
    out.extend(lines[max(0, len(lines) - 220) :])

if summary_i is not None and summary_i not in range(failures_i or -1, (failures_i or -1) + 220):
    out.append("")
    out.extend(lines[summary_i : min(len(lines), summary_i + 80)])

if failed_line_i is not None:
    out.append("")
    out.append(lines[failed_line_i])

if len(out) < 20:
    out.append("")
    out.append("== pytest tail (fallback)")
    out.extend(lines[max(0, len(lines) - 80) :])

for line in out[:320]:
    print(line)
PY
}

classify_env_blockers() {
  local combined_file="$1"
  local blockers=""
  if /usr/bin/grep -qiE "___kmpc_dispatch_deinit|libomp|OpenMP|libxgboost\\.dylib|XGBoost Library.*could not be loaded" "$combined_file"; then
    blockers="${blockers}\n- xgboost/openmp runtime missing on macos (install 'libomp', then reinstall xgboost)\n"
  fi
  if /usr/bin/grep -qiE "No module named 'pytest'|ModuleNotFoundError:.*pytest" "$combined_file"; then
    blockers="${blockers}\n- pytest not available in environment (run ./ops/bootstrap_python.sh)\n"
  fi
  if /usr/bin/grep -qiE "ruff: command not found|No module named 'ruff'|ModuleNotFoundError:.*ruff" "$combined_file"; then
    blockers="${blockers}\n- ruff not available in environment (run ./ops/bootstrap_python.sh)\n"
  fi
  printf '%b' "$blockers"
}

ruff_unwaived_output() {
  local ruff_output_file="$1"
  if [[ ! -f "$JUDGE_WAIVERS_FILE" ]]; then
    cat "$ruff_output_file"
    return 0
  fi

  WAIVERS_FILE="$JUDGE_WAIVERS_FILE" /usr/bin/python3 - <<'PY' <"$ruff_output_file"
import json
import os
import sys
from fnmatch import fnmatch

waivers_path = os.environ["WAIVERS_FILE"]

try:
  waivers = json.loads(open(waivers_path, "r", encoding="utf-8").read())
except Exception:
  waivers = {"global": {"codes": []}, "files": []}

global_codes = set((waivers.get("global") or {}).get("codes") or [])
file_rules = waivers.get("files") or []

def is_waived(path: str, code: str) -> bool:
  if code in global_codes:
    return True
  for rule in file_rules:
    glob = rule.get("path_glob")
    codes = set(rule.get("codes") or [])
    if not glob or not codes:
      continue
    if fnmatch(path, glob) and code in codes:
      return True
  return False

for line in sys.stdin.read().splitlines():
  line = line.rstrip("\n")
  if not line.strip():
    continue
  # expected: path:line:col: CODE message
  parts = line.split(":", 3)
  if len(parts) < 4:
    print(line)
    continue
  path = parts[0]
  rest = parts[3].lstrip()
  if not rest:
    print(line)
    continue
  code = rest.split(maxsplit=1)[0]
  if not is_waived(path, code):
    print(line)
PY
}

commit_if_green() {
  local include_paths=()
  # shellcheck disable=SC2206
  include_paths=($JUDGE_INCLUDE_PATHS)

  git add -A -- "${include_paths[@]}" >/dev/null 2>&1 || true

  if git diff --cached --quiet; then
    return 0
  fi

  local file_count
  file_count="$(git diff --cached --name-only | /usr/bin/wc -l | tr -d ' ')"
  local sample
  sample="$(git diff --cached --name-only | /usr/bin/head -n 8)"

  git commit -m "$(cat <<EOF
chore: judge auto-commit (${file_count} files)

${sample}
EOF
)"

  if [[ "$JUDGE_AUTO_PUSH" != "1" ]]; then
    return 0
  fi

  if ! git remote get-url "$JUDGE_PUSH_REMOTE" >/dev/null 2>&1; then
    return 0
  fi

  set +e
  git push "$JUDGE_PUSH_REMOTE" HEAD >/dev/null 2>&1
  rc="$?"
  set -e
  if [[ "$rc" -ne 0 ]]; then
    write_blocker_ticket "push failed; commit exists locally but remote update did not happen" "### action\n- ensure git remote '${JUDGE_PUSH_REMOTE}' is configured and launchd has credentials to push\n"
    return 1
  fi
}

process_ticket() {
  local ticket_path="$1"
  local base_name
  base_name="$(basename "$ticket_path")"
  local claimed_file
  claimed_file="tasks/judge_queue/processed/${base_name}.$(date +%s).$$"

  if ! mv "$ticket_path" "$claimed_file" 2>/dev/null; then
    return 0
  fi

  log_status "judge ticket claimed: ${base_name}"

  if ! has_effective_dirty; then
    log_status "no effective dirty paths; skipping commit"
    return 0
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local ruff_format_out="${tmp_dir}/ruff_format.txt"
  local ruff_check_fix_out="${tmp_dir}/ruff_check_fix.txt"
  local ruff_check_out="${tmp_dir}/ruff_check.txt"
  local ruff_check_concise_out="${tmp_dir}/ruff_check_concise.txt"
  local pytest_out="${tmp_dir}/pytest.txt"
  local combined_out="${tmp_dir}/combined.txt"
  local unwaived_out="${tmp_dir}/ruff_unwaived.txt"

  local ok="1"

  if ! command -v ruff >/dev/null 2>&1; then
    ok="0"
    echo "ruff not found in PATH" >"$ruff_check_out"
  else
    # do not fail fast on --fix output; final gate is unwaived concise output.
    run_cmd_capture "ruff check --fix" "$ruff_check_fix_out" ruff check --fix . || true
    if ! run_cmd_capture "ruff format" "$ruff_format_out" ruff format .; then
      ok="0"
    fi

    # capture full ruff output for human readability
    run_cmd_capture "ruff check" "$ruff_check_out" ruff check . || true

    # capture concise output for waiver-aware gating
    set +e
    ruff check . --no-color --output-format concise >"$ruff_check_concise_out" 2>&1
    ruff_rc="$?"
    set -e

    if [[ "$ruff_rc" -ne 0 ]]; then
      WAIVERS_FILE="$JUDGE_WAIVERS_FILE" ruff_unwaived_output "$ruff_check_concise_out" >"$unwaived_out" || true
      if [[ -s "$unwaived_out" ]]; then
        ok="0"
      fi
    else
      : >"$unwaived_out"
    fi
  fi

  if ! run_cmd_capture "pytest" "$pytest_out" python -m pytest; then
    ok="0"
  fi

  # build a structured combined output that prioritizes pytest failures first,
  # then shows unwaived (blocking) and waived (non-blocking) ruff findings.
  {
    echo "== pytest"
    echo "\$ python -m pytest"
    if [[ -f "$pytest_out" ]]; then
      echo ""
      echo "-- pytest head (40 lines)"
      /usr/bin/head -n 40 "$pytest_out" 2>/dev/null || true
      echo ""
      echo "-- pytest tail (180 lines)"
      /usr/bin/tail -n 180 "$pytest_out" 2>/dev/null || true
    fi
    echo ""
    echo "== ruff unwaived (blocking)"
    echo "\$ ruff check . --no-color --output-format concise"
    if [[ -s "$unwaived_out" ]]; then
      cat "$unwaived_out"
    else
      echo "(none)"
    fi
    echo ""
    echo "== ruff waived (non-blocking)"
    echo "\$ ruff check . --no-color --output-format concise"
    if [[ -f "$ruff_check_concise_out" ]]; then
      WAIVERS_FILE="$JUDGE_WAIVERS_FILE" /usr/bin/python3 - <<'PY' <"$ruff_check_concise_out" || true
import json
import os
import sys
from fnmatch import fnmatch

waivers_path = os.environ["WAIVERS_FILE"]
try:
  waivers = json.loads(open(waivers_path, "r", encoding="utf-8").read())
except Exception:
  waivers = {"global": {"codes": []}, "files": []}

global_codes = set((waivers.get("global") or {}).get("codes") or [])
file_rules = waivers.get("files") or []

def is_waived(path: str, code: str) -> bool:
  if code in global_codes:
    return True
  for rule in file_rules:
    glob = rule.get("path_glob")
    codes = set(rule.get("codes") or [])
    if not glob or not codes:
      continue
    if fnmatch(path, glob) and code in codes:
      return True
  return False

waived = []
for line in sys.stdin.read().splitlines():
  line = line.rstrip("\n")
  if not line.strip():
    continue
  parts = line.split(":", 3)
  if len(parts) < 4:
    continue
  path = parts[0]
  rest = parts[3].lstrip()
  if not rest:
    continue
  code = rest.split(maxsplit=1)[0]
  if is_waived(path, code):
    waived.append(line)

for line in waived[:120]:
  print(line)
if len(waived) > 120:
  print(f"... ({len(waived) - 120} more waived ruff findings)")
PY
    fi
    echo ""
    echo "== raw ruff output (debug)"
    /usr/bin/head -n 80 "$ruff_check_out" 2>/dev/null || true
    echo ""
    echo "== raw ruff --fix output (debug)"
    /usr/bin/head -n 80 "$ruff_check_fix_out" 2>/dev/null || true
    echo ""
    echo "== raw ruff format output (debug)"
    /usr/bin/head -n 80 "$ruff_format_out" 2>/dev/null || true
  } >"$combined_out" 2>&1 || true

  if [[ "$ok" == "1" ]]; then
    rm -f "$BLOCKER_TICKET_PATH" >/dev/null 2>&1 || true
    log_status "checks passed; attempting commit"
    commit_if_green || true
    rm -rf "$tmp_dir" || true
    return 0
  fi

  local blockers
  blockers="$(classify_env_blockers "$combined_out")"
  local body
  body=""
  if [[ -n "$blockers" ]]; then
    body="${body}### environment blockers\n${blockers}\n\n"
  fi
  body="${body}### failing output (first 200 lines)\n\n\`\`\`\n$(/usr/bin/head -n 200 "$combined_out" 2>/dev/null || true)\n\`\`\`\n"

  write_blocker_ticket "validation failed; no commit made" "$body"
  ensure_planner_blocker_notice || true
  rm -rf "$tmp_dir" || true
}

while true; do
  next="$(claim_next_ticket || true)"
  if [[ -n "${next:-}" ]]; then
    process_ticket "$next" || true
  else
    log_status "idle: no judge tickets"
  fi
  /bin/sleep "$SLEEP_SECS"
done

