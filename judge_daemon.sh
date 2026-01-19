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
BLOCKER_TICKET_PATH="${BLOCKER_TICKET_PATH:-tasks/planner_queue/00_judge_blocker.md}"
JUDGE_AUTO_PUSH="${JUDGE_AUTO_PUSH:-1}"
JUDGE_PUSH_REMOTE="${JUDGE_PUSH_REMOTE:-origin}"

JUDGE_INCLUDE_PATHS_DEFAULT="agent_factory data_prep pricing_algorithms tests pyproject.toml requirements.txt analyze_historical_coverage.py"
JUDGE_INCLUDE_PATHS="${JUDGE_INCLUDE_PATHS:-$JUDGE_INCLUDE_PATHS_DEFAULT}"

mkdir -p tasks/judge_queue/processed
mkdir -p tasks/planner_queue

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

  if ! has_effective_dirty; then
    return 0
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local ruff_format_out="${tmp_dir}/ruff_format.txt"
  local ruff_check_out="${tmp_dir}/ruff_check.txt"
  local pytest_out="${tmp_dir}/pytest.txt"
  local combined_out="${tmp_dir}/combined.txt"

  local ok="1"

  if ! command -v ruff >/dev/null 2>&1; then
    ok="0"
    echo "ruff not found in PATH" >"$ruff_check_out"
  else
    if ! run_cmd_capture "ruff check --fix" "$ruff_check_out" ruff check --fix .; then
      ok="0"
    fi
    if ! run_cmd_capture "ruff format" "$ruff_format_out" ruff format .; then
      ok="0"
    fi
    if ! run_cmd_capture "ruff check" "$ruff_check_out" ruff check .; then
      ok="0"
    fi
  fi

  if ! run_cmd_capture "pytest" "$pytest_out" python -m pytest; then
    ok="0"
  fi

  cat "$ruff_format_out" "$ruff_check_out" "$pytest_out" >"$combined_out" 2>/dev/null || true

  if [[ "$ok" == "1" ]]; then
    rm -f "$BLOCKER_TICKET_PATH" >/dev/null 2>&1 || true
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
  rm -rf "$tmp_dir" || true
}

while true; do
  next="$(claim_next_ticket || true)"
  if [[ -n "${next:-}" ]]; then
    process_ticket "$next" || true
  fi
  /bin/sleep "$SLEEP_SECS"
done

