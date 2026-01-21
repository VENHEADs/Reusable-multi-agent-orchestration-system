#!/usr/bin/env bash
set -euo pipefail

# deterministic judge daemon
#
# consumes tickets from tasks/judge_queue/ and either:
# - commits whitelisted paths when checks pass
# - writes/updates a single actionable blocker ticket when checks fail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# load centralized configuration
AGENT_FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${AGENT_FACTORY_DIR}/config.sh" ]]; then
  source "${AGENT_FACTORY_DIR}/config.sh"
fi

# use config values with backward compatibility
# note: all defaults come from config.sh; these lines maintain backward compatibility with old env var names
SLEEP_SECS="${JUDGE_SLEEP_SECS:-${SLEEP_SECS}}"
BLOCKER_TICKET_PATH="${BLOCKER_TICKET_PATH}"
JUDGE_AUTO_PUSH="${JUDGE_AUTO_PUSH}"
JUDGE_PUSH_REMOTE="${JUDGE_PUSH_REMOTE}"
JUDGE_WAIVERS_FILE="${JUDGE_WAIVERS_FILE}"
PYTEST_MAXFAIL="${PYTEST_MAXFAIL}"
# JUDGE_INCLUDE_PATHS and JUDGE_INCLUDE_PATHS_DEFAULT are set in config.sh

mkdir -p tasks/judge_queue/processed
mkdir -p tasks/planner_queue
mkdir -p .agent_factory_state

shutdown_requested="0"
current_ticket_path=""
shutdown_timeout="${SHUTDOWN_TIMEOUT_SECS}"
shutdown_start_time=""

shutdown_handler() {
  if [[ "$shutdown_requested" == "0" ]]; then
    shutdown_requested="1"
    shutdown_start_time="$(date +%s)"
    local signal_name=""
    case "$1" in
      SIGTERM) signal_name="SIGTERM" ;;
      SIGINT) signal_name="SIGINT" ;;
      *) signal_name="UNKNOWN" ;;
    esac
    log_status "shutdown signal received ($signal_name); finishing current ticket..."
  fi
}

trap 'shutdown_handler SIGTERM' SIGTERM
trap 'shutdown_handler SIGINT' SIGINT

log_status() {
  local msg="$1"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg"
}

effective_dirty_paths() {
  python3 - <<'PY'
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
  
  # extract environment vs code blockers from body
  local env_section=""
  local code_section=""
  local has_env=false
  local has_code=false
  
  if echo "$body" | /usr/bin/grep -q "### environment blockers"; then
    has_env=true
    env_section="$(echo "$body" | /usr/bin/awk '/### environment blockers/,/### code blockers|### failing output|^$/{if (/### code blockers|### failing output/) exit; print}')"
  fi
  if echo "$body" | /usr/bin/grep -q "### code blockers"; then
    has_code=true
    code_section="$(echo "$body" | /usr/bin/awk '/### code blockers/,/### failing output|^$/{if (/### failing output/) exit; print}')"
  fi
  
  local failing_output=""
  if echo "$body" | /usr/bin/grep -q "### failing output"; then
    failing_output="$(echo "$body" | /usr/bin/awk '/### failing output/,0')"
  fi
  
  # detect specific failure types for targeted reproduction commands
  local has_pytest_failures=false
  local has_ruff_format_issues=false
  local has_ruff_check_issues=false
  local specific_test_files=""
  local pytest_failure_examples=""
  
  if echo "$body" | /usr/bin/grep -qiE "pytest.*fail|FAILED|ERROR.*test" || echo "$failing_output" | /usr/bin/grep -qiE "pytest.*fail|FAILED|ERROR.*test"; then
    has_pytest_failures=true
    # extract specific test file paths if available (improved pattern matching)
    # try multiple patterns to catch all test file references
    specific_test_files=$(echo "$body$failing_output" | /usr/bin/grep -oE "(tests/|pricing_algorithms/|data_prep/)[^:[:space:]]+\.py" | /usr/bin/sort -u | /usr/bin/head -n 5 | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')
    # also extract from test identifiers (format: path/to/test.py::test_name)
    if [[ -z "$specific_test_files" ]]; then
      specific_test_files=$(echo "$body$failing_output" | /usr/bin/grep -oE "[^[:space:]]+\.py::" | /usr/bin/sed 's/::$//' | /usr/bin/sort -u | /usr/bin/head -n 5 | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')
    fi
    # also try extracting from file:line patterns in tracebacks
    if [[ -z "$specific_test_files" ]]; then
      specific_test_files=$(echo "$body$failing_output" | /usr/bin/grep -oE "File\s+[\"']?([^\"']+\.py)[\"']?" | /usr/bin/sed -E "s/File\s+[\"']?([^\"']+\.py)[\"']?/\1/" | /usr/bin/grep -E "\.(py)$" | /usr/bin/sort -u | /usr/bin/head -n 5 | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')
    fi
    if [[ -n "$failing_output" ]]; then
      pytest_failure_examples=$(
        FAILING_OUTPUT="$failing_output" python3 - <<'PY'
import re
import os

lines = os.environ.get("FAILING_OUTPUT", "").splitlines()
summary_i = None
for i, line in enumerate(lines):
    if re.match(r"^=+\s+short test summary info\s+=+$", line):
        summary_i = i
        break

examples = []
if summary_i is not None:
    for line in lines[summary_i + 1 : min(len(lines), summary_i + 80)]:
        if re.match(r"^=+$", line):
            break
        match = re.search(r"([^\s]+\.py)::([^\s]+)\s+(FAILED|ERROR)", line)
        if not match:
            continue
        test_file = match.group(1)
        test_name = match.group(2)
        test_line = None
        for j in range(summary_i + 1, min(len(lines), summary_i + 200)):
            if test_file in lines[j] and test_name in lines[j]:
                line_match = re.search(rf"{re.escape(test_file)}:(\d+)", lines[j])
                if line_match:
                    test_line = line_match.group(1)
                    break
        if test_line:
            examples.append(f"{test_file}:{test_line} - {test_name}")
        else:
            examples.append(f"{test_file} - {test_name}")
        if len(examples) >= 3:
            break

print(", ".join(examples))
PY
      )
    fi
  fi
  
  if echo "$body" | /usr/bin/grep -qiE "ruff format|would reformat" || echo "$failing_output" | /usr/bin/grep -qiE "ruff format|would reformat"; then
    has_ruff_format_issues=true
  fi
  
  if echo "$body" | /usr/bin/grep -qiE "ruff check|E[0-9]|F[0-9]|W[0-9]" || echo "$failing_output" | /usr/bin/grep -qiE "ruff check|E[0-9]|F[0-9]|W[0-9]"; then
    has_ruff_check_issues=true
  fi
  
  {
    echo "# Blocker: judge cannot commit"
    echo
    echo "updated: ${now}"
    echo
    echo "## Summary"
    printf '%s\n' "$title"
    echo
    
    if [[ "$has_env" == "true" ]]; then
      echo "## 🔧 Environment Issues (CRITICAL - Fix First)"
      echo
      echo "**⚠️ CRITICAL**: these issues prevent validation from running. **you must fix these before addressing code issues.**"
      echo
      echo "**what are environment issues?**"
      echo "- missing dependencies (pytest, ruff, xgboost, etc.)"
      echo "- incorrect python versions"
      echo "- missing system libraries (libomp, etc.)"
      echo "- python executable not found or not in PATH"
      echo "- virtual environment not activated"
      echo
      echo "**how to identify**: look for error messages like \"command not found\", \"No module named\", \"Library not loaded\", or \"SyntaxError\""
      echo
      printf '%b\n' "$env_section"
      echo
      echo "**fixing environment issues (step-by-step):**"
      echo "1. **identify the issue**: review the problem description above"
      echo "2. **run the fix command**: use the exact command provided in the fix section"
      echo "3. **verify the fix**: run the verification command to confirm it worked"
      echo "4. **re-run validation**: \`python -m pytest --maxfail ${PYTEST_MAXFAIL} --tb=short -v && ruff format . --check && ruff check . --output-format concise\`"
      echo "5. **if validation passes**: the judge will automatically commit your changes"
      echo
      echo "---"
      echo
    fi
    
    if [[ "$has_code" == "true" ]]; then
      echo "## 💻 Code Issues"
      echo
      echo "**these issues require code changes. see validation output below for specific file paths, line numbers, and error details.**"
      echo
      echo "**what are code issues?**"
      echo "- **test failures** (pytest errors) - broken functionality that must be fixed"
      echo "- **linting errors** (ruff check) - code quality/style issues that need attention"
      echo "- **formatting problems** (ruff format) - code formatting inconsistencies (auto-fixable)"
      echo
      echo "**each issue shows:**"
      echo "- exact file path and line number where it occurs (format: \`file:line\` or \`file:line:column\`)"
      echo "- error code and descriptive message (e.g., \`E501\` line too long, \`F401\` unused import)"
      echo "- severity level (error ❌, warning ⚠️, etc.) with visual indicators"
      echo "- for pytest: test name, failure location, error type, and full traceback"
      echo
      echo "**how to identify**: look for pytest failures, ruff check errors, or ruff format issues in validation output below"
      echo
      printf '%b\n' "$code_section"
      echo
      echo "**fixing code issues (recommended order):**"
      echo "1. **formatting issues** (fastest, auto-fixable): \`ruff format .\`"
      echo "2. **auto-fix linting issues**: \`ruff check . --fix\` (fixes many issues automatically)"
      echo "3. **manually fix remaining linting issues**: see validation output for specific file paths, line numbers, and error codes"
      echo "4. **fix test failures**: see validation output for test names, file paths, line numbers, and error details"
      echo "5. **verify all fixes**: run the commands in the \"Commands to Reproduce Locally\" section below"
      echo
      echo "---"
      echo
    fi
    
    echo "## 📋 Validation Output"
    echo
    echo "**detailed validation results below. issues are prioritized by severity (pytest failures first, then format issues, then linting errors).**"
    echo
    echo "**how to use this section:**"
    echo ""
    echo "1. **pytest failures** (most critical - fix first):"
    echo "   - shows test names, file paths, line numbers, and detailed tracebacks"
    echo "   - indicates broken functionality that must be fixed"
    echo "   - each failure shows: test identifier, file location (file:line), error type, and full traceback"
    echo "   - use the test file paths and line numbers to navigate directly to failing tests"
    echo ""
    echo "2. **ruff format issues** (easy fix - auto-fixable):"
    echo "   - shows which files need formatting"
    echo "   - auto-fixable with single command: \`ruff format .\`"
    echo "   - fastest fix - run this first if you have format issues"
    echo ""
    echo "3. **ruff check errors** (need code changes):"
    echo "   - shows linting issues grouped by file and severity (errors ❌, warnings ⚠️, etc.)"
    echo "   - many are auto-fixable with \`ruff check . --fix\`"
    echo "   - each error shows: file path, line number, column, error code, and descriptive message"
    echo "   - fix errors (❌) first, then warnings (⚠️), then other issues"
    echo ""
    echo "4. **ruff waived findings** (informational only):"
    echo "   - these don't block commits"
    echo "   - shown for reference only"
    echo
    if [[ -n "$failing_output" ]]; then
      printf '%b\n' "$failing_output"
    else
      printf '%b\n' "$body"
    fi
    echo
    
    echo "## 🔄 Commands to Reproduce Locally"
    echo
    echo "**use these commands to reproduce and fix issues locally before committing**"
    echo
    echo "**how to use this section:**"
    echo "- commands are organized by issue type (pytest, ruff format, ruff check)"
    echo "- each section includes step-by-step instructions with clear explanations"
    echo "- targeted commands are provided when specific failures are detected (faster iteration)"
    echo "- comprehensive commands are always included for full validation (complete check)"
    echo "- copy and paste commands directly into your terminal"
    echo
    
    # provide targeted commands based on what failed
    if [[ "$has_pytest_failures" == "true" ]]; then
      echo "### reproduce pytest failures"
      echo
      echo "**when to use**: use these commands to reproduce and debug test failures locally"
      echo
      echo "**detected failures**: see validation output above for specific test names, file paths, and line numbers"
      if [[ -n "$pytest_failure_examples" ]]; then
        echo ""
        echo "**failure examples**: \`$pytest_failure_examples\`"
      fi
      if [[ -n "$specific_test_files" ]]; then
        echo ""
        echo "**detected test files**: \`$(echo "$specific_test_files" | /usr/bin/tr ' ' ',')\`"
        echo ""
        echo "**note**: these test files were automatically detected from the validation output. use the commands below to reproduce the failures."
      fi
      echo
      echo "\`\`\`bash"
      if [[ -n "$specific_test_files" ]]; then
        echo "# option 1: run specific failing tests (fastest, recommended for quick iteration)"
        echo "# these are the specific test files that failed (from validation output above):"
        for test_file in $specific_test_files; do
          echo "python -m pytest ${test_file} --tb=short -v"
        done
        echo ""
        echo "# option 2: run specific test with full traceback (for detailed debugging)"
        echo "# use this when you need to see the complete stack trace:"
        for test_file in $specific_test_files; do
          echo "python -m pytest ${test_file} --tb=long -v"
        done
        echo ""
        echo "# option 3: run all tests (same as judge, stops after ${PYTEST_MAXFAIL} failures)"
      else
        echo "# run all tests (same as judge, stops after ${PYTEST_MAXFAIL} failures)"
      fi
      echo "python -m pytest --maxfail ${PYTEST_MAXFAIL} --tb=short -v"
      echo ""
      echo "# to see full traceback for debugging (shows complete stack traces)"
      echo "python -m pytest --maxfail ${PYTEST_MAXFAIL} --tb=long -v"
      echo ""
      echo "# to run only failed tests from last run (useful after fixing some tests)"
      echo "python -m pytest --lf --tb=short -v"
      echo ""
      echo "# to see which tests failed without running them again (test collection only)"
      echo "python -m pytest --collect-only -q | grep -E 'FAILED|ERROR'"
      echo ""
      echo "# to run a specific test by name (useful for debugging individual tests)"
      echo "# format: python -m pytest path/to/test_file.py::test_class::test_name --tb=short -v"
      echo "# example: python -m pytest tests/test_example.py::TestExample::test_something --tb=short -v"
      echo "\`\`\`"
      echo
      echo "**tips**:"
      echo "- start with option 1 (specific tests) for fastest iteration"
      echo "- use \`--tb=long\` when you need to see the full stack trace"
      echo "- use \`--lf\` to rerun only failed tests after making fixes"
      echo "- check the validation output above for exact file paths and line numbers"
      echo "- use \`file:line\` format from validation output to jump directly to failing code in your editor"
      echo
    fi
    
    if [[ "$has_ruff_format_issues" == "true" ]]; then
      echo "### fix formatting issues"
      echo
      echo "**when to use**: formatting issues are the easiest to fix - they're auto-fixable with one command"
      echo
      echo "\`\`\`bash"
      echo "# step 1: check what would be reformatted (dry run)"
      echo "ruff format . --check"
      echo ""
      echo "# step 2: apply formatting fixes automatically (recommended - fixes all issues at once)"
      echo "ruff format ."
      echo ""
      echo "# step 3: verify formatting is fixed (should show no issues)"
      echo "ruff format . --check"
      echo "\`\`\`"
      echo
      echo "**note**: formatting issues are auto-fixable. run \`ruff format .\` to fix all formatting problems at once."
      echo "**tip**: always run this first - it's the fastest fix and doesn't require any code changes."
      echo
    fi
    
    if [[ "$has_ruff_check_issues" == "true" ]]; then
      echo "### fix ruff check issues"
      echo
      echo "**when to use**: linting errors need code changes. many can be auto-fixed, but some require manual fixes."
      echo
      echo "**detected issues**: see validation output above for specific file paths, line numbers, error codes, and severity levels"
      echo
      echo "\`\`\`bash"
      echo "# step 1: see all issues grouped by file (human-readable, recommended first)"
      echo "ruff check ."
      echo ""
      echo "# step 2: auto-fix what can be fixed automatically (many issues are auto-fixable)"
      echo "ruff check . --fix"
      echo ""
      echo "# step 3: see remaining issues in concise format (matches judge output)"
      echo "ruff check . --output-format concise"
      echo ""
      echo "# step 4: check specific files (if you know which files have issues from validation output)"
      echo "# format: ruff check path/to/file.py --output-format concise"
      echo "# example: ruff check pricing_algorithms/validation/input_validator.py --output-format concise"
      echo ""
      echo "# step 5: verify all issues are fixed (should show no unwaived errors)"
      echo "ruff check . --output-format concise"
      echo "\`\`\`"
      echo
      echo "**fix order** (by severity):"
      echo "1. ❌ **ERROR** (E, F codes) - critical issues that block commits - fix these first"
      echo "2. ⚠️ **WARNING** (W codes) - issues that should be addressed - may cause problems"
      echo "3. 🐛 **BUGBEAR** (B codes) - potential bugs or code smells - best practices"
      echo "4. 🔀 **COMPLEXITY** (C4 codes) - code complexity issues - maintainability concerns"
      echo "5. 🏷️ **NAMING** (N codes) - naming convention violations - style issues"
      echo "6. ℹ️ **OTHER** - other linting issues - informational"
      echo
      echo "**note**: many ruff check issues can be auto-fixed. run \`ruff check . --fix\` first, then manually fix remaining issues."
      echo "**tip**: check the validation output above for exact file paths, line numbers, and error codes. use \`file:line:column\` format to jump directly to issues in your editor."
      echo
    fi
    
    # always include comprehensive commands
    echo "### run all checks (comprehensive)"
    echo "\`\`\`bash"
    echo "# run all validation checks in the same order as judge"
    echo "# step 1: run tests"
    echo "python -m pytest --maxfail ${PYTEST_MAXFAIL} --tb=short -v"
    echo ""
    echo "# step 2: check formatting"
    echo "ruff format . --check"
    echo ""
    echo "# step 3: check linting"
    echo "ruff check . --output-format concise"
    echo ""
    echo "# or run all at once (format will auto-fix, check will show issues)"
    echo "ruff format . && ruff check ."
    echo "\`\`\`"
    echo
    
    # if we detected specific issues, provide quick fix commands
    if [[ "$has_pytest_failures" == "true" ]] || [[ "$has_ruff_format_issues" == "true" ]] || [[ "$has_ruff_check_issues" == "true" ]]; then
      echo "### quick fix workflow (recommended order)"
      echo
      echo "**follow these steps in order to fix all issues efficiently:**"
      echo
      echo "\`\`\`bash"
      echo "# step 1: fix formatting first (fastest, no thinking required, auto-fixable)"
      if [[ "$has_ruff_format_issues" == "true" ]]; then
        echo "ruff format ."
        echo "# verify: ruff format . --check  # should show no issues"
      else
        echo "# ruff format .  # (no formatting issues detected)"
      fi
      echo ""
      echo "# step 2: auto-fix ruff check issues (fixes many issues automatically)"
      if [[ "$has_ruff_check_issues" == "true" ]]; then
        echo "ruff check . --fix"
        echo "# verify: ruff check . --output-format concise  # check remaining issues"
      else
        echo "# ruff check . --fix  # (no ruff check issues detected)"
      fi
      echo ""
      echo "# step 3: manually fix remaining ruff check issues (if any)"
      if [[ "$has_ruff_check_issues" == "true" ]]; then
        echo "# check what's left: ruff check . --output-format concise"
        echo "# fix issues shown in validation output above (use file:line:column format to navigate)"
        echo "# then verify: ruff check . --output-format concise"
      else
        echo "# (no ruff check issues to fix manually)"
      fi
      echo ""
      echo "# step 4: fix test failures (requires code changes, most time-consuming)"
      if [[ "$has_pytest_failures" == "true" ]]; then
        echo "# run tests to see failures:"
        echo "python -m pytest --maxfail ${PYTEST_MAXFAIL} --tb=short -v"
        echo "# fix failing tests shown in validation output above (use file:line format to navigate)"
        echo "# then verify: python -m pytest --maxfail ${PYTEST_MAXFAIL} --tb=short -v"
      else
        echo "# python -m pytest --maxfail ${PYTEST_MAXFAIL} --tb=short -v  # (no test failures detected)"
      fi
      echo ""
      echo "# step 5: final verification (run all checks to ensure everything passes)"
      echo "python -m pytest --maxfail ${PYTEST_MAXFAIL} --tb=short -v && ruff format . --check && ruff check . --output-format concise"
      echo "\`\`\`"
      echo
    fi
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

  python3 - "$pytest_output_file" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text(errors="replace").splitlines()
if not lines:
    print("(no pytest output captured)")
    raise SystemExit(0)

def find_index(pattern: str):
    rx = re.compile(pattern)
    for i, line in enumerate(lines):
        if rx.search(line):
            return i
    return None

# extract test summary info first
summary_i = find_index(r"^=+\s+short test summary info\s+=+$")
failed_tests = []
test_details = {}  # test_name -> {file, line, error_type}
if summary_i is not None:
    for i in range(summary_i + 1, min(len(lines), summary_i + 100)):
        line = lines[i]
        if re.match(r"^=+$", line):
            break
        if "FAILED" in line or "ERROR" in line:
            # extract test path and name: "path/to/test.py::test_name FAILED"
            match = re.search(r"([^\s]+::[^\s]+)\s+(FAILED|ERROR)", line)
            if match:
                test_id = match.group(1)
                failed_tests.append(test_id)
                # extract file path and test name
                parts = test_id.split("::")
                if len(parts) >= 2:
                    test_file = parts[0]
                    test_name = parts[-1]
                    # try to find line number in test file by searching for test definition
                    test_line = None
                    failure_location = None
                    # method 1: search in failures/errors section for this test
                    failures_i = find_index(r"^=+\s+FAILURES\s+=+$")
                    errors_i = find_index(r"^=+\s+ERRORS\s+=+$")
                    for section_start in [failures_i, errors_i]:
                        if section_start is None:
                            continue
                        # search in this section for the test
                        for j in range(section_start + 1, min(len(lines), section_start + 500)):
                            if test_id in lines[j] or (test_file in lines[j] and test_name in lines[j]):
                                # look for line number in traceback - prioritize test file references
                                for k in range(j, min(len(lines), j + 30)):
                                    # match "File \"path/to/file.py\", line 123" pattern (most common)
                                    file_line_match = re.search(rf'File\s+["\']?{re.escape(test_file)}["\']?,\s+line\s+(\d+)', lines[k])
                                    if file_line_match:
                                        test_line = file_line_match.group(1)
                                        break
                                    file_any_match = re.search(r'File\s+["\']?([^"\']+\.py)["\']?,\s+line\s+(\d+)', lines[k])
                                    if file_any_match and not failure_location:
                                        other_file = file_any_match.group(1)
                                        if other_file != test_file:
                                            failure_location = f"{other_file}:{file_any_match.group(2)}"
                                    # also match pytest format: "path/to/file.py:123:" or "path/to/file.py:123"
                                    pytest_line_match = re.search(rf'{re.escape(test_file)}:(\d+)[:\s]', lines[k])
                                    if pytest_line_match:
                                        test_line = pytest_line_match.group(1)
                                        break
                                    pytest_any_match = re.search(r'^([^:]+\.py):(\d+):', lines[k].strip())
                                    if pytest_any_match and not failure_location:
                                        other_file = pytest_any_match.group(1)
                                        if other_file != test_file:
                                            failure_location = f"{other_file}:{pytest_any_match.group(2)}"
                                    # match "  File \"path/to/file.py\", line 123, in test_function" (with function name)
                                    func_line_match = re.search(rf'File\s+["\']?{re.escape(test_file)}["\']?,\s+line\s+(\d+),\s+in\s+', lines[k])
                                    if func_line_match:
                                        test_line = func_line_match.group(1)
                                        break
                                    # match pytest's error format: "file.py:123: in test_function"
                                    pytest_func_match = re.search(rf'{re.escape(test_file)}:(\d+):\s+in\s+', lines[k])
                                    if pytest_func_match:
                                        test_line = pytest_func_match.group(1)
                                        break
                                if test_line:
                                    break
                        if test_line:
                            break
                    # method 2: if not found, search backwards from summary for test definition
                    if not test_line:
                        for j in range(i - 1, max(0, i - 200), -1):
                            if test_file in lines[j] and test_name in lines[j]:
                                # look for line number pattern: "def test_name" or "class TestClass"
                                line_match = re.search(rf"^\s*(def|class)\s+{re.escape(test_name.split('.')[-1])}", lines[j])
                                if line_match:
                                    # find line number in traceback or file reference
                                    for k in range(j, min(len(lines), j + 15)):
                                        file_line_match = re.search(rf'File\s+["\']?{re.escape(test_file)}["\']?,\s+line\s+(\d+)', lines[k])
                                        if file_line_match:
                                            test_line = file_line_match.group(1)
                                            break
                                        # also check for pytest format
                                        pytest_line_match = re.search(rf'{re.escape(test_file)}:(\d+)[:\s]', lines[k])
                                        if pytest_line_match:
                                            test_line = pytest_line_match.group(1)
                                            break
                                    break
                    # method 3: extract from test summary line if it contains line number
                    if not test_line and ":" in test_id:
                        # check if test_id itself contains line number (e.g., "file.py::TestClass::test_method[param]")
                        # or check the summary line for pytest's line number format
                        summary_line_match = re.search(rf'{re.escape(test_file)}:(\d+):', lines[i] if i < len(lines) else "")
                        if summary_line_match:
                            test_line = summary_line_match.group(1)
                    # method 4: search for test definition in the file itself (if we have file path)
                    if not test_line and test_file:
                        # try to find line number from pytest's collection output or error messages
                        for j in range(max(0, i - 50), min(len(lines), i + 50)):
                            if test_file in lines[j] and test_name.split('.')[-1] in lines[j]:
                                # look for line number pattern in this line or nearby
                                line_match = re.search(rf'{re.escape(test_file)}:(\d+)', lines[j])
                                if line_match:
                                    test_line = line_match.group(1)
                                    break
                    test_details[test_id] = {
                        "file": test_file,
                        "test_name": test_name,
                        "error_type": match.group(2),
                        "line": test_line,
                        "failure_location": failure_location
                    }

failures_i = find_index(r"^=+\s+FAILURES\s+=+$")
errors_i = find_index(r"^=+\s+ERRORS\s+=+$")
failed_line_i = None
for i in range(len(lines) - 1, -1, -1):
    if "FAILED" in lines[i] or "ERROR" in lines[i]:
        failed_line_i = i
        break

out: list[str] = []

# show failed test summary at top with file paths and line numbers
if failed_tests:
    out.append("**failed tests summary:**")
    out.append("")
    out.append(f"**total: {len(failed_tests)} test(s) failed**")
    out.append("")
    out.append("**format**: `file_path:line_number` - test_name [ERROR/FAILED]")
    out.append("")
    for test_id in failed_tests[:20]:
        detail = test_details.get(test_id, {})
        file_path = detail.get("file", test_id.split("::")[0] if "::" in test_id else test_id)
        test_name = detail.get("test_name", test_id.split("::")[-1] if "::" in test_id else test_id)
        error_type = detail.get("error_type", "")
        test_line = detail.get("line")
        # format: file path:line (if available) - test name [ERROR/FAILED]
        failure_location = detail.get("failure_location")
        if test_line and failure_location:
            out.append(f"❌ `{file_path}:{test_line}` - `{test_name}` [{error_type}] (failure: `{failure_location}`)")
        elif test_line:
            out.append(f"❌ `{file_path}:{test_line}` - `{test_name}` [{error_type}]")
        elif failure_location:
            out.append(f"❌ `{file_path}` - `{test_name}` [{error_type}] (failure: `{failure_location}`)")
        else:
            out.append(f"❌ `{file_path}` - `{test_name}` [{error_type}]")
    if len(failed_tests) > 20:
        out.append(f"")
        out.append(f"   ... ({len(failed_tests) - 20} more failures - see detailed traces below)")
    out.append("")
    out.append("**what to look for:**")
    out.append("- **test names and file paths** (shown above) - identifies which tests failed")
    out.append("- **line numbers** where tests are defined and where failures occur - navigate directly to the problem")
    out.append("- **error types** (AssertionError, ImportError, etc.) - indicates the nature of the failure")
    out.append("- **error messages and assertion details** - provides context about what went wrong")
    out.append("")
    out.append("**navigation tips:**")
    out.append("- use `file:line` format from the summary above to jump directly to the failing code in your editor")
    out.append("- test file location shows where the test is defined (where to look for the test code)")
    out.append("- failure location shows where the actual error occurred (may differ from test location - this is where the bug likely is)")
    out.append("- detailed traces below show the full stack trace with all file:line references")
    out.append("")

# include detailed failure traces with file:line context
if failures_i is not None:
    out.append("**detailed failure traces:**")
    out.append("")
    i = failures_i + 1
    failure_count = 0
    while i < len(lines) and i < failures_i + 500 and failure_count < 10:
        line = lines[i]
        # detect test file path and line number: "tests/file.py::test_class::test_name"
        if re.match(r"^[^:]+\.py::[^:]+", line.strip()):
            failure_count += 1
            out.append("")
            # extract file path and test name from header
            test_header = line.strip()
            # extract file path from test header
            test_file_match = re.search(r"^([^:]+\.py)::", test_header)
            test_file = test_file_match.group(1) if test_file_match else "unknown"
            out.append(f"")
            out.append(f"**Test**: `{test_header}`")
            
            # look for file path and line number in traceback (format: "file.py:123:")
            test_file_line = None
            j = i + 1
            found_location = False
            error_message = ""
            error_type = ""
            source_locations = []
            assertion_details = ""
            failure_location = None  # track where the actual failure occurred (not just test definition)
            while j < len(lines) and j < i + 50:
                trace_line = lines[j]
                # match file:line patterns like "  File \"/path/to/file.py\", line 123, in function"
                location_match = re.search(r'File\s+["\']?([^"\']+\.py)["\']?,\s+line\s+(\d+)', trace_line)
                if location_match:
                    file_path = location_match.group(1)
                    line_num = location_match.group(2)
                    # normalize file paths (handle relative vs absolute)
                    if not file_path.startswith('/') and '/' not in file_path:
                        # might be just filename, try to match with test_file
                        if test_file.endswith(file_path):
                            file_path = test_file
                    # prioritize test file locations for test definition
                    if test_file in file_path and not test_file_line:
                        test_file_line = f"{file_path}:{line_num}"
                    # track failure location (first non-test-file location is usually where failure occurred)
                    if test_file not in file_path and not failure_location:
                        failure_location = f"{file_path}:{line_num}"
                    # collect all source locations (limit to first 3 for clarity)
                    if len(source_locations) < 3 and file_path not in [loc[0] for loc in source_locations]:
                        source_locations.append((file_path, line_num))
                    if not found_location:
                        # show test file location first, then failure location
                        if test_file in file_path:
                            out.append(f"**Test location**: `{file_path}:{line_num}`")
                        else:
                            out.append(f"**Failure location**: `{file_path}:{line_num}`")
                        found_location = True
                # also match pytest's format: "tests/file.py:123: AssertionError"
                pytest_match = re.match(r'^([^:]+\.py):(\d+):\s*(.+)', trace_line.strip())
                if pytest_match:
                    file_path = pytest_match.group(1)
                    line_num = pytest_match.group(2)
                    error_msg = pytest_match.group(3)
                    # normalize file paths
                    if test_file in file_path or file_path in test_file:
                        if not test_file_line:
                            test_file_line = f"{file_path}:{line_num}"
                        if not found_location:
                            out.append(f"**Location**: `{file_path}:{line_num}`")
                            error_message = error_msg
                            found_location = True
                
                # extract error type and message from assertion or exception
                if not error_type:
                    if "AssertionError" in trace_line:
                        error_type = "AssertionError"
                        # try to extract assertion details from next few lines
                        for k in range(j + 1, min(len(lines), j + 5)):
                            if lines[k].strip() and not lines[k].strip().startswith(">"):
                                assertion_details = lines[k].strip()
                                break
                    elif "Exception" in trace_line or "Error" in trace_line:
                        # match various error patterns: "ErrorType: message", "ErrorType(message)", etc.
                        # improved pattern matching for better error extraction
                        error_match = re.search(r'(\w+Error|\w+Exception|KeyError|ValueError|TypeError|AttributeError|ImportError|NameError|RuntimeError|OSError|FileNotFoundError|PermissionError)(?:\s*:\s*|\s*\(|\s+)(.+)', trace_line)
                        if error_match:
                            error_type = error_match.group(1)
                            if not error_message and error_match.group(2):
                                error_message = error_match.group(2).strip().rstrip(')').rstrip('"').rstrip("'")
                        # also try simpler pattern if first didn't match
                        if not error_type:
                            simple_match = re.search(r'(\w+Error|\w+Exception|KeyError|ValueError|TypeError|AttributeError|ImportError|NameError|RuntimeError|OSError|FileNotFoundError|PermissionError)', trace_line)
                            if simple_match:
                                error_type = simple_match.group(1)
                
                # capture assertion details if present
                if not assertion_details and ("assert" in trace_line.lower() or "AssertionError" in trace_line):
                    # look for assertion details in next lines (skip traceback markers)
                    for k in range(j + 1, min(len(lines), j + 5)):
                        detail_line = lines[k].strip()
                        # skip traceback markers, empty lines, and file references
                        if detail_line and not detail_line.startswith(">") and not detail_line.startswith("File ") and "line " not in detail_line:
                            # extract meaningful assertion details (limit length for readability)
                            assertion_details = detail_line[:300]  # increased limit for better context
                            break
                        # also check for assertion details in the same line
                        if "assert" in detail_line.lower() and "AssertionError" not in detail_line:
                            assertion_details = detail_line[:300]
                            break
                
                # indent traceback lines for readability
                if trace_line.strip():
                    out.append(f"    {trace_line}")
                else:
                    out.append(trace_line)
                # stop at next test or section boundary
                if j < len(lines) - 1 and (re.match(r"^[^:]+\.py::", lines[j + 1].strip()) or 
                                           re.match(r"^=+", lines[j + 1].strip())):
                    break
                j += 1
            
            # add error summary if we found one (insert after location for better readability)
            if error_type or error_message or assertion_details:
                error_summary = []
                if error_type:
                    error_summary.append(f"**Error type**: `{error_type}`")
                if error_message:
                    # clean up error message (remove extra quotes, whitespace, limit length)
                    clean_msg = error_message[:250].strip().rstrip('"').rstrip("'").rstrip('.')
                    if clean_msg:
                        error_summary.append(f"**Error message**: {clean_msg}")
                if assertion_details:
                    # clean up assertion details (remove extra quotes, whitespace, limit length)
                    clean_details = assertion_details[:300].strip().rstrip('"').rstrip("'").rstrip('.')
                    if clean_details:
                        error_summary.append(f"**Assertion details**: `{clean_details}`")
                if error_summary:
                    # find the test header and insert error summary after location
                    for idx, out_line in enumerate(out):
                        if f"**Test**: `{test_header}`" in out_line:
                            # find the next location line or insert after header
                            insert_idx = idx + 1
                            for k in range(idx + 1, min(len(out), idx + 5)):
                                if "**Location**:" in out[k] or "**Test location**:" in out[k] or "**Failure location**:" in out[k]:
                                    insert_idx = k + 1
                                    break
                            # format error summary with line breaks for readability
                            out.insert(insert_idx, "\n".join(error_summary))
                            break
            
            # show test file line number if found (insert after test header)
            if test_file_line:
                # find the test header line and insert after it
                for idx, out_line in enumerate(out):
                    if f"**Test**: `{test_header}`" in out_line:
                        out.insert(idx + 1, f"**Test file**: `{test_file_line}`")
                        break
            
            # show failure location if different from test location
            if failure_location and failure_location != test_file_line:
                # find where to insert (after test file or test header)
                for idx, out_line in enumerate(out):
                    if f"**Test**: `{test_header}`" in out_line or f"**Test file**: `{test_file_line}`" in out_line:
                        # check if failure location already shown
                        if "**Failure location**:" not in "\n".join(out[idx:idx+5]):
                            out.insert(idx + 2, f"**Failure location**: `{failure_location}`")
                        break
            
            if error_message and not found_location:
                out.append(f"**Error**: {error_message}")
            
            i = j
        else:
            i += 1

# handle errors section separately
if errors_i is not None:
    out.append("")
    out.append("**test errors (setup/teardown failures):**")
    out.append("")
    i = errors_i + 1
    error_count = 0
    while i < len(lines) and i < errors_i + 300 and error_count < 5:
        line = lines[i]
        if re.match(r"^[^:]+\.py::", line.strip()):
            error_count += 1
            out.append("")
            # extract file path from error header
            test_file_match = re.search(r"^([^:]+\.py)::", line.strip())
            test_file = test_file_match.group(1) if test_file_match else "unknown"
            out.append(f"")
            out.append(f"**Test**: `{line.strip()}`")
            out.append(f"**File**: `{test_file}`")
            # include next 20 lines for error context
            for j in range(i + 1, min(len(lines), i + 21)):
                out.append(f"   {lines[j]}")
            i = min(len(lines), i + 21)
        else:
            i += 1

# add summary section if not already included
if summary_i is not None:
    out.append("")
    out.append("**test summary:**")
    out.append("")
    out.extend(lines[summary_i : min(len(lines), summary_i + 100)])

# fallback if we didn't capture enough
if len([l for l in out if l.strip()]) < 10:
    out.append("")
    out.append("**full output tail (fallback):**")
    out.append("")
    out.extend(lines[max(0, len(lines) - 150) :])

for line in out[:500]:
    print(line)
PY
}

classify_env_blockers() {
  local combined_file="$1"
  local env_blockers=""
  local code_blockers=""
  
  # environment blockers - xgboost/openmp
  if /usr/bin/grep -qiE "___kmpc_dispatch_deinit|libomp|OpenMP|libxgboost\\.dylib|XGBoost Library.*could not be loaded|dlopen.*libomp|Library not loaded.*libomp" "$combined_file"; then
    env_blockers="${env_blockers}\n- **🔧 xgboost/openmp runtime missing on macOS**\n  - **problem**: xgboost library cannot load required OpenMP runtime (common on macOS)\n  - **symptoms**: errors like \"Library not loaded: libomp\", \"dlopen.*libomp\", or \"XGBoost Library could not be loaded\"\n  - **fix**: \`brew install libomp && pip install --force-reinstall xgboost\`\n  - **verify**: \`python -c 'import xgboost; print(xgboost.__version__)'\` (should print version without errors)\n  - **troubleshooting**: if issue persists, check that brew-installed libomp is in library path: \`brew list libomp\`\n"
  fi
  
  # environment blockers - pytest
  if /usr/bin/grep -qiE "No module named 'pytest'|ModuleNotFoundError:.*pytest|pytest: command not found|python.*pytest.*not found" "$combined_file"; then
    env_blockers="${env_blockers}\n- **🔧 pytest not available in environment**\n  - **problem**: pytest module or command not found in current python environment\n  - **symptoms**: errors like \"No module named 'pytest'\", \"pytest: command not found\", or \"ModuleNotFoundError: pytest\"\n  - **fix**: \`./ops/bootstrap_python.sh\` (recommended) or \`pip install pytest\` (if virtual environment is active)\n  - **verify**: \`python -m pytest --version\` (should print pytest version without errors)\n  - **troubleshooting**: ensure virtual environment is activated if using one: \`which python\` should point to .venv/bin/python\n"
  fi
  
  # environment blockers - ruff
  if /usr/bin/grep -qiE "ruff: command not found|No module named 'ruff'|ModuleNotFoundError:.*ruff|ruff.*not found" "$combined_file"; then
    env_blockers="${env_blockers}\n- **🔧 ruff not available in environment**\n  - **problem**: ruff command or module not found in current python environment\n  - **symptoms**: errors like \"ruff: command not found\", \"No module named 'ruff'\", or \"ModuleNotFoundError: ruff\"\n  - **fix**: \`./ops/bootstrap_python.sh\` (recommended) or \`pip install ruff\` (if virtual environment is active)\n  - **verify**: \`ruff --version\` (should print ruff version without errors)\n  - **troubleshooting**: ensure virtual environment is activated if using one: \`which python\` should point to .venv/bin/python\n"
  fi
  
  # environment blockers - python version
  if /usr/bin/grep -qiE "SyntaxError.*invalid syntax|requires Python.*but.*running|Python.*is required|invalid syntax.*python|SyntaxError.*python|f-string.*requires.*python|walrus operator.*requires.*python" "$combined_file"; then
    env_blockers="${env_blockers}\n- **🔧 python version mismatch**\n  - **problem**: code requires python 3.9+ but different version is running\n  - **fix**: ensure python 3.9+ is available (\`python3 --version\`)\n  - **verify**: \`which python3 && python3 --version\`\n  - **troubleshooting**: check if virtual environment is using correct python version\n"
  fi
  
  # environment blockers - missing python executable
  if /usr/bin/grep -qiE "python.*not found|/usr/bin/python.*No such file|command not found.*python|python3.*not found" "$combined_file"; then
    env_blockers="${env_blockers}\n- **🔧 python executable not found**\n  - **problem**: python executable not in PATH or not installed\n  - **fix**: install python 3.9+ or set PATH correctly\n  - **verify**: \`which python3 && python3 --version\`\n  - **troubleshooting**: check PATH environment variable, verify python installation location\n"
  fi
  
  # environment blockers - virtual environment issues
  if /usr/bin/grep -qiE "venv.*not found|virtualenv.*not found|\.venv.*not found|No module named.*venv|Activate.*venv|activate.*script" "$combined_file"; then
    env_blockers="${env_blockers}\n- **🔧 virtual environment not activated or missing**\n  - **problem**: python virtual environment not activated or not found\n  - **fix**: activate virtual environment with \`source .venv/bin/activate\` or create one with \`python3 -m venv .venv\`\n  - **verify**: \`which python\` should point to .venv/bin/python when activated\n"
  fi
  
  # environment blockers - permission issues
  if /usr/bin/grep -qiE "Permission denied|EACCES|permission.*denied|cannot.*write|read-only" "$combined_file"; then
    env_blockers="${env_blockers}\n- **🔧 file permission issues**\n  - **problem**: insufficient permissions to read/write files or directories\n  - **fix**: check file permissions with \`ls -la\` and fix with \`chmod\` or \`chown\` as needed\n  - **verify**: ensure user has read/write access to project directory and files\n"
  fi
  
  # environment blockers - disk space issues
  if /usr/bin/grep -qiE "No space left|disk.*full|ENOSPC|quota.*exceeded" "$combined_file"; then
    env_blockers="${env_blockers}\n- **🔧 disk space issues**\n  - **problem**: insufficient disk space for operations\n  - **fix**: free up disk space (\`df -h\` to check, remove unnecessary files)\n  - **verify**: \`df -h .\` should show available space\n"
  fi
  
  # environment blockers - missing dependencies (not pytest/ruff/xgboost)
  if /usr/bin/grep -qiE "ModuleNotFoundError|ImportError.*cannot import" "$combined_file"; then
    # extract specific missing module names (improved pattern matching with multiple formats)
    # handle both single and double quotes, and various error message formats
    missing_modules=$(/usr/bin/grep -iE "ModuleNotFoundError.*No module named ['\"]([^'\"]+)['\"]|ImportError.*cannot import name ['\"]([^'\"]+)['\"]|ImportError.*cannot import ['\"]([^'\"]+)['\"]|No module named ['\"]([^'\"]+)['\"]" "$combined_file" | \
      /usr/bin/sed -E "s/.*No module named ['\"]([^'\"]+)['\"].*/\1/" | \
      /usr/bin/sed -E "s/.*cannot import name ['\"]([^'\"]+)['\"].*/\1/" | \
      /usr/bin/sed -E "s/.*cannot import ['\"]([^'\"]+)['\"].*/\1/" | \
      /usr/bin/grep -vE "^(pytest|ruff|xgboost)$" | \
      /usr/bin/sort -u | /usr/bin/head -n 5 | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//')
    
    # check if it's a known env tool (pytest/ruff/xgboost) - if so, skip (already handled above)
    if ! echo "$missing_modules" | /usr/bin/grep -qiE "pytest|ruff|xgboost"; then
      if [[ -n "$missing_modules" ]]; then
        # format module list for better readability
        module_list=$(echo "$missing_modules" | /usr/bin/tr ',' '\n' | /usr/bin/sed 's/^/    - /' | /usr/bin/tr '\n' '|' | /usr/bin/sed 's/|$//' | /usr/bin/sed 's/|/\\n/g')
        # use first module for verification command
        first_module=$(echo "$missing_modules" | /usr/bin/cut -d',' -f1)
        env_blockers="${env_blockers}\n- **🔧 missing python dependencies**\n  - **problem**: required python packages not installed\n  - **missing modules**: ${missing_modules}\n  - **fix**: add to requirements.txt and run \`pip install -r requirements.txt\`\n  - **verify**: \`python -c 'import ${first_module}'\` (should import without errors)\n  - **troubleshooting**: if import still fails, check validation output above for specific error messages\n"
      else
        env_blockers="${env_blockers}\n- **🔧 missing python dependencies**\n  - **problem**: required python packages not installed (check requirements.txt)\n  - **fix**: \`pip install -r requirements.txt\`\n  - **verify**: check validation output above for specific missing module names\n  - **troubleshooting**: review validation output for exact error messages and module names\n"
      fi
    fi
  fi
  
  # output structured format
  if [[ -n "$env_blockers" ]]; then
    printf '%b' "### environment blockers\n${env_blockers}\n"
  fi
  if [[ -n "$code_blockers" ]]; then
    printf '%b' "### code blockers\n${code_blockers}\n"
  fi
}

ruff_unwaived_output() {
  local ruff_output_file="$1"
  if [[ ! -f "$JUDGE_WAIVERS_FILE" ]]; then
    cat "$ruff_output_file"
    return 0
  fi

  WAIVERS_FILE="$JUDGE_WAIVERS_FILE" python3 - "$ruff_output_file" <<'PY'
import json
import os
import sys
from fnmatch import fnmatch
from pathlib import Path

waivers_path = os.environ["WAIVERS_FILE"]
input_path = Path(sys.argv[1])

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

for line in input_path.read_text(errors="replace").splitlines():
  line = line.rstrip("\n")
  if not line.strip():
    continue
  # expected: path:line:col: CODE message
  parts = line.split(":", 3)
  if len(parts) < 4:
    continue
  path = parts[0]
  rest = parts[3].lstrip()
  if not rest:
    continue
  code = rest.split(maxsplit=1)[0]
  if not is_waived(path, code):
    print(line)
PY
}

ruff_severity_summary() {
  local ruff_output_file="$1"
  if [[ ! -f "$ruff_output_file" ]]; then
    return 0
  fi

  python3 - "$ruff_output_file" <<'PY'
import sys
from collections import Counter
from pathlib import Path

input_path = Path(sys.argv[1])

severity_map = {
    "E": "error", "F": "error", "W": "warning", "I": "info", "N": "naming",
    "UP": "upgrade", "B": "bugbear", "C4": "complexity", "SIM": "simplify",
    "T20": "flake8-print", "PT": "pytest", "Q": "flake8-quotes", "RUF": "ruff",
    "PL": "pylint", "PERF": "performance", "FBT": "flake8-boolean-trap",
    "PIE": "flake8-pie", "A": "flake8-builtins", "COM": "flake8-commas",
    "C90": "mccabe", "DTZ": "flake8-datetimez", "EM": "flake8-errmsg",
    "EXE": "flake8-executable", "FA": "flake8-future-annotations",
    "ISC": "flake8-implicit-str-concat", "ICN": "flake8-import-conventions",
    "INP": "flake8-no-pep420", "TID": "flake8-tidy-imports",
    "ARG": "flake8-unused-arguments", "PTH": "flake8-use-pathlib",
    "ERA": "eradicate", "PD": "pandas-vet", "PGH": "pygrep-hooks",
    "PLR": "pylint-refactor", "PLW": "pylint-warning", "TRY": "tryceratops",
    "NPY": "numpy", "AIR": "airflow", "S": "flake8-bandit", "BLE": "flake8-blind-except",
    "YTT": "flake8-2020", "ANN": "flake8-annotations", "ASYNC": "flake8-async",
    "S101": "flake8-bandit", "G": "flake8-logging-format"
}

counter = Counter()
for line in input_path.read_text(errors="replace").splitlines():
    line = line.rstrip("\n")
    if not line.strip():
        continue
    parts = line.split(":", 3)
    if len(parts) < 4:
        continue
    rest = parts[3].lstrip()
    if not rest:
        continue
    code = rest.split(maxsplit=1)[0]
    severity = "other"
    matched = False
    for prefix, sev in sorted(severity_map.items(), key=lambda x: -len(x[0])):
        if code.startswith(prefix):
            severity = sev
            matched = True
            break
    if not matched and code:
        first_char = code[0]
        if first_char in severity_map:
            severity = severity_map[first_char]
    counter[severity] += 1

order = ["error", "warning", "bugbear", "complexity", "naming", "other", "upgrade", "performance", "pytest", "ruff", "simplify", "info"]
parts = []
for key in order:
    if counter.get(key):
        parts.append(f"{key}={counter[key]}")

if parts:
    print(", ".join(parts))
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

  current_ticket_path="$claimed_file"
  log_status "judge ticket claimed: ${base_name}"
  
  # check for shutdown before processing
  if [[ "$shutdown_requested" == "1" ]]; then
    log_status "shutdown requested before ticket processing; requeueing: ${base_name}"
    mv "$claimed_file" "tasks/judge_queue/$base_name" 2>/dev/null || true
    current_ticket_path=""
    return 0
  fi

  if ! has_effective_dirty; then
    log_status "no effective dirty paths; skipping commit"
    return 0
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local ruff_format_out="${tmp_dir}/ruff_format.txt"
  local ruff_check_out="${tmp_dir}/ruff_check.txt"
  local ruff_check_concise_out="${tmp_dir}/ruff_check_concise.txt"
  local pytest_quick_out="${tmp_dir}/pytest_quick.txt"
  local pytest_out="${tmp_dir}/pytest.txt"
  local combined_out="${tmp_dir}/combined.txt"
  local unwaived_out="${tmp_dir}/ruff_unwaived.txt"

  local ok="1"
  
  # check for shutdown before starting validation
  if [[ "$shutdown_requested" == "1" ]]; then
    log_status "shutdown requested before validation; requeueing: ${base_name}"
    mv "$claimed_file" "tasks/judge_queue/$base_name" 2>/dev/null || true
    current_ticket_path=""
    return 0
  fi

  # fast pytest for actionable failure tracebacks
  if ! run_cmd_capture "pytest (maxfail)" "$pytest_quick_out" python -m pytest --maxfail "$PYTEST_MAXFAIL" --tb=short; then
    ok="0"
  else
    # only run full suite if quick run passed
    if ! run_cmd_capture "pytest" "$pytest_out" python -m pytest; then
      ok="0"
    fi
  fi

  # check for shutdown before running ruff checks
  if [[ "$shutdown_requested" == "1" ]]; then
    log_status "shutdown requested during validation; requeueing: ${base_name}"
    mv "$claimed_file" "tasks/judge_queue/$base_name" 2>/dev/null || true
    rm -rf "$tmp_dir" || true
    current_ticket_path=""
    return 0
  fi

  if ! command -v ruff >/dev/null 2>&1; then
    ok="0"
    echo "ruff not found in PATH" >"$ruff_check_out"
  else
    if ! run_cmd_capture "ruff format --check" "$ruff_format_out" ruff format --check .; then
      ok="0"
    fi

    # capture full ruff output for human readability
    run_cmd_capture "ruff check" "$ruff_check_out" ruff check . || true

    # capture concise output for waiver-aware gating
    set +e
    ruff check . --output-format concise >"$ruff_check_concise_out" 2>&1
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
  # check for shutdown after validation
  if [[ "$shutdown_requested" == "1" ]]; then
    log_status "shutdown requested after validation; requeueing: ${base_name}"
    mv "$claimed_file" "tasks/judge_queue/$base_name" 2>/dev/null || true
    rm -rf "$tmp_dir" || true
    current_ticket_path=""
    return 0
  fi

  # build a structured combined output that prioritizes actionable information:
  # 1. pytest failures (most critical)
  # 2. ruff format issues (easy to fix)
  # 3. ruff check blocking errors (need code changes)
  # 4. ruff check non-blocking (waived, informational)
  {
    # prioritize pytest failures - most actionable
    if [[ -s "$pytest_quick_out" ]] && /usr/bin/grep -qiE "FAILED|ERROR" "$pytest_quick_out" 2>/dev/null; then
      echo "=== ❌ pytest failures (fix first) ==="
      echo ""
      echo "**most critical: test failures indicate broken functionality. fix these before addressing formatting or linting issues.**"
      echo ""
      extract_pytest_failures "$pytest_quick_out" || true
      if [[ -f "$pytest_out" ]] && /usr/bin/grep -qiE "FAILED|ERROR" "$pytest_out" 2>/dev/null; then
        echo ""
        echo "=== pytest full run summary ==="
        echo "\$ python -m pytest"
        /usr/bin/tail -n 80 "$pytest_out" 2>/dev/null || true
      fi
      echo ""
      echo "**command that produced this output:**"
      echo "\`\`\`bash"
      echo "python -m pytest --maxfail ${PYTEST_MAXFAIL} --tb=short -v"
      echo "\`\`\`"
      echo ""
    fi
    
    # ruff format issues - easy to auto-fix
    if [[ -s "$ruff_format_out" ]] && /usr/bin/grep -q "would reformat" "$ruff_format_out" 2>/dev/null; then
      echo "=== ⚠️  ruff format issues (auto-fixable) ==="
      echo ""
      echo "**easy fix: these are formatting issues that can be automatically fixed. run \`ruff format .\` to fix all formatting problems at once.**"
      echo ""
      echo "**note**: formatting issues are non-blocking for functionality but must be fixed before commits."
      echo ""
      /usr/bin/grep -E "would reformat|reformatted" "$ruff_format_out" 2>/dev/null | /usr/bin/head -n 20 || true
      echo ""
      echo "**command that produced this output:**"
      echo "\`\`\`bash"
      echo "ruff format . --check"
      echo "\`\`\`"
      echo ""
    fi
    
    # ruff check blocking errors - need code changes
    echo "=== ❌ ruff check errors (blocking) ==="
    echo ""
    echo "**these errors must be fixed before commits can proceed. many can be auto-fixed with \`ruff check . --fix\`**"
    echo ""
    if [[ -s "$unwaived_out" ]]; then
      # group by file and severity
      WAIVERS_FILE="$JUDGE_WAIVERS_FILE" python3 - "$unwaived_out" <<'PY' || true
import sys
from collections import defaultdict
from pathlib import Path

input_path = Path(sys.argv[1])

errors_by_file = defaultdict(list)
severity_map = {
    "E": "error", "F": "error", "W": "warning", "I": "info", "N": "naming",
    "UP": "upgrade", "B": "bugbear", "C4": "complexity", "SIM": "simplify",
    "T20": "flake8-print", "PT": "pytest", "Q": "flake8-quotes", "RUF": "ruff",
    "PL": "pylint", "PERF": "performance", "FBT": "flake8-boolean-trap",
    "PIE": "flake8-pie", "A": "flake8-builtins", "COM": "flake8-commas",
    "C90": "mccabe", "DTZ": "flake8-datetimez", "EM": "flake8-errmsg",
    "EXE": "flake8-executable", "FA": "flake8-future-annotations",
    "ISC": "flake8-implicit-str-concat", "ICN": "flake8-import-conventions",
    "INP": "flake8-no-pep420", "PIE": "flake8-pie", "TID": "flake8-tidy-imports",
    "ARG": "flake8-unused-arguments", "PTH": "flake8-use-pathlib",
    "ERA": "eradicate", "PD": "pandas-vet", "PGH": "pygrep-hooks",
    "PLR": "pylint-refactor", "PLW": "pylint-warning", "TRY": "tryceratops",
    "NPY": "numpy", "AIR": "airflow", "S": "flake8-bandit", "BLE": "flake8-blind-except",
    "F": "pyflakes", "I": "isort", "N": "pep8-naming", "W": "pycodestyle",
    "E": "pycodestyle", "UP": "pyupgrade", "YTT": "flake8-2020", "ANN": "flake8-annotations",
    "ASYNC": "flake8-async", "S101": "flake8-bandit", "G": "flake8-logging-format"
}

for line in input_path.read_text(errors="replace").splitlines():
    line = line.rstrip("\n")
    if not line.strip():
        continue
    parts = line.split(":", 3)
    if len(parts) < 4:
        print(line)
        continue
    file_path = parts[0]
    line_num = parts[1]
    col_num = parts[2]
    rest = parts[3].lstrip()
    if not rest:
        print(line)
        continue
    code = rest.split(maxsplit=1)[0]
    message = rest.split(maxsplit=1)[1] if len(rest.split(maxsplit=1)) > 1 else ""
    
    # determine severity with better code matching
    severity = "other"
    # try exact prefix match first (for multi-character codes like UP, C4, SIM, etc.)
    # sort by length descending to match longer prefixes first
    matched = False
    for prefix, sev in sorted(severity_map.items(), key=lambda x: -len(x[0])):
        if code.startswith(prefix):
            severity = sev
            matched = True
            break
    # fallback to single character match if no prefix matched
    if not matched and len(code) > 0:
        first_char = code[0]
        if first_char in severity_map:
            severity = severity_map[first_char]
        # also check for numeric codes (e.g., S101, C90)
        elif len(code) > 1 and code[0].isalpha() and code[1].isdigit():
            # check if first letter matches a severity category
            if first_char in severity_map:
                severity = severity_map[first_char]
    
    errors_by_file[file_path].append({
        "line": line_num,
        "col": col_num,
        "code": code,
        "message": message,
        "severity": severity
    })

# group by file, then by severity
total_errors = sum(len(errs) for errs in errors_by_file.values())
if total_errors > 0:
    print(f"**total: {total_errors} unwaived error(s) across {len(errors_by_file)} file(s)**")
    print("")
    print("**fix order**: errors first (❌), then warnings (⚠️), then other issues")
    print("")
    print("**how to read**: each error shows `file:line:column` - `code` - message")
    print("")
    print("**quick actions**:")
    print("- auto-fix many issues: `ruff check . --fix`")
    print("- check specific file: `ruff check path/to/file.py --output-format concise`")
    print("- see all issues (human-readable): `ruff check .`")
    print("- see concise format (matches judge): `ruff check . --output-format concise`")
    print("")
    print("**severity guide**:")
    print("- ❌ **ERROR** (E, F codes): critical issues that block commits - fix these first")
    print("- ⚠️ **WARNING** (W codes): issues that should be addressed - may cause problems")
    print("- 🐛 **BUGBEAR** (B codes): potential bugs or code smells - best practices")
    print("- 🔀 **COMPLEXITY** (C4 codes): code complexity issues - maintainability concerns")
    print("- 🏷️ **NAMING** (N codes): naming convention violations - style issues")
    print("- ℹ️ **OTHER**: other linting issues - informational")
    print("")

for file_path in sorted(errors_by_file.keys()):
    file_errors = errors_by_file[file_path]
    print(f"")
    print(f"**File**: `{file_path}` ({len(file_errors)} error(s))")
    print("")
    
    # group by severity
    by_severity = defaultdict(list)
    for err in file_errors:
        by_severity[err["severity"]].append(err)
    
    # severity order: errors first, then warnings, then others
    severity_order = ["error", "warning", "bugbear", "complexity", "naming", "other"]
    severity_icons = {
        "error": "❌",
        "warning": "⚠️",
        "bugbear": "🐛",
        "complexity": "🔀",
        "naming": "🏷️",
        "other": "ℹ️"
    }
    severity_descriptions = {
        "error": "critical issues that must be fixed (blocks commits)",
        "warning": "issues that should be addressed (may cause problems)",
        "bugbear": "potential bugs or code smells (best practices)",
        "complexity": "code complexity issues (maintainability)",
        "naming": "naming convention violations (style)",
        "other": "other linting issues (informational)"
    }
    for severity in severity_order:
        if severity not in by_severity:
            continue
        sev_errors = by_severity[severity]
        if not sev_errors:
            continue
        icon = severity_icons.get(severity, "•")
        desc = severity_descriptions.get(severity, "")
        print(f"{icon} **{severity.upper()}** ({len(sev_errors)}) - {desc}:")
        # group consecutive line numbers for readability
        sorted_errors = sorted(sev_errors, key=lambda x: (int(x["line"]), int(x["col"])))
        for err in sorted_errors:
            # format: file:line:col - CODE - message
            # add line number context for easier navigation
            line_num = err['line']
            col_num = err['col']
            code_str = err['code']
            msg = err['message']
            # format with consistent spacing and clear separators
            print(f"  - `{file_path}:{line_num}:{col_num}` - `{code_str}` - {msg}")
    print("")
    print("**command that produced this output:**")
    print("```bash")
    print("ruff check . --output-format concise")
    print("```")
PY
    else
      echo "(none - all ruff checks passed or waived)"
      echo ""
      echo "**command that produced this output:**"
      echo "\`\`\`bash"
      echo "ruff check . --output-format concise"
      echo "\`\`\`"
      echo ""
    fi
    
    # ruff waived (non-blocking, informational only)
    if [[ -f "$ruff_check_concise_out" ]]; then
      echo "=== ℹ️  ruff waived findings (non-blocking) ==="
      echo ""
      echo "**informational only: these findings are waived and do not block commits.**"
      echo ""
      WAIVERS_FILE="$JUDGE_WAIVERS_FILE" python3 - "$ruff_check_concise_out" <<'PY' || true
import json
import os
import sys
from fnmatch import fnmatch
from pathlib import Path

waivers_path = os.environ["WAIVERS_FILE"]
input_path = Path(sys.argv[1])
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
for line in input_path.read_text(errors="replace").splitlines():
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

if waived:
  print(f"(showing {min(20, len(waived))} of {len(waived)} waived findings)")
  for line in waived[:20]:
    print(line)
  if len(waived) > 20:
    print(f"... ({len(waived) - 20} more waived ruff findings)")
else:
  print("(none)")
PY
      echo ""
      echo "**command that produced this output:**"
      echo "\`\`\`bash"
      echo "ruff check . --output-format concise"
      echo "\`\`\`"
      echo ""
    fi
    
    # debug output only if there are issues and we need more context
    if [[ "$ok" != "1" ]]; then
      echo "=== 🔍 debug output (for troubleshooting) ==="
      if [[ -s "$ruff_check_out" ]]; then
        echo ""
        echo "--- raw ruff check output ---"
        /usr/bin/head -n 40 "$ruff_check_out" 2>/dev/null || true
      fi
      if [[ -s "$ruff_format_out" ]] && ! /usr/bin/grep -q "would reformat" "$ruff_format_out" 2>/dev/null; then
        echo ""
        echo "--- raw ruff format output ---"
        /usr/bin/head -n 40 "$ruff_format_out" 2>/dev/null || true
      fi
    fi
  } >"$combined_out" 2>&1 || true

  if [[ "$ok" == "1" ]]; then
    rm -f "$BLOCKER_TICKET_PATH" >/dev/null 2>&1 || true
    rm -f "tasks/planner_queue/00_judge_blocker_notice.md" >/dev/null 2>&1 || true
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
    body="${body}${blockers}\n"
  fi
  
  # check if there are code issues (pytest failures or ruff errors)
  local has_code_issues=false
  local code_issue_details=""
  
    if [[ -s "$pytest_quick_out" ]] && /usr/bin/grep -qiE "FAILED|ERROR" "$pytest_quick_out" 2>/dev/null; then
    has_code_issues=true
    # count failed tests (improved counting)
    failed_count=$(/usr/bin/grep -cE "FAILED|ERROR" "$pytest_quick_out" 2>/dev/null || echo "0")
    # also try to extract test names for better context
    test_names=$(/usr/bin/grep -oE "[^[:space:]]+\.py::[^[:space:]]+.*(FAILED|ERROR)" "$pytest_quick_out" 2>/dev/null | /usr/bin/head -n 3 | /usr/bin/sed 's/ (FAILED\|ERROR)//' | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || echo "")
    if [[ "$failed_count" -gt 0 ]]; then
      if [[ -n "$test_names" ]]; then
        code_issue_details="${code_issue_details}\n- **pytest failures**: ${failed_count} test(s) failed (examples: \`${test_names}\` - see validation output for full details)"
      else
        code_issue_details="${code_issue_details}\n- **pytest failures**: ${failed_count} test(s) failed (see validation output for details)"
      fi
    fi
  fi
  
  if [[ -s "$unwaived_out" ]]; then
    has_code_issues=true
    # count ruff errors (improved counting)
    ruff_count=$(/usr/bin/wc -l < "$unwaived_out" 2>/dev/null | /usr/bin/tr -d ' ' || echo "0")
    # also extract file paths for better context
    ruff_files=$(/usr/bin/cut -d':' -f1 "$unwaived_out" 2>/dev/null | /usr/bin/sort -u | /usr/bin/head -n 3 | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || echo "")
    ruff_severity="$(ruff_severity_summary "$unwaived_out" || true)"
    if [[ "$ruff_count" -gt 0 ]]; then
      if [[ -n "$ruff_files" ]]; then
        if [[ -n "$ruff_severity" ]]; then
          code_issue_details="${code_issue_details}\n- **ruff check errors**: ${ruff_count} unwaived error(s) in files like \`${ruff_files}\` (severity breakdown: ${ruff_severity}) (see validation output for full details)"
        else
          code_issue_details="${code_issue_details}\n- **ruff check errors**: ${ruff_count} unwaived error(s) in files like \`${ruff_files}\` (see validation output for full details)"
        fi
      else
        if [[ -n "$ruff_severity" ]]; then
          code_issue_details="${code_issue_details}\n- **ruff check errors**: ${ruff_count} unwaived error(s) (severity breakdown: ${ruff_severity}) (see validation output for details)"
        else
          code_issue_details="${code_issue_details}\n- **ruff check errors**: ${ruff_count} unwaived error(s) (see validation output for details)"
        fi
      fi
    fi
  fi
  
  if [[ -s "$ruff_format_out" ]] && /usr/bin/grep -q "would reformat" "$ruff_format_out" 2>/dev/null; then
    has_code_issues=true
    # count files needing formatting
    format_count=$(/usr/bin/grep -c "would reformat" "$ruff_format_out" 2>/dev/null || echo "0")
    if [[ "$format_count" -gt 0 ]]; then
      code_issue_details="${code_issue_details}\n- **ruff format issues**: ${format_count} file(s) need formatting (auto-fixable with \`ruff format .\`)"
    fi
  fi
  
  if [[ "$has_code_issues" == "true" && -z "$blockers" ]]; then
    body="${body}### code blockers${code_issue_details}\n\n"
  elif [[ "$has_code_issues" == "true" && -n "$blockers" ]]; then
    # add code issues to existing blockers
    body="${body}### code blockers${code_issue_details}\n\n"
  fi
  
  body="${body}### failing output\n\n\`\`\`\n$(/usr/bin/head -n 300 "$combined_out" 2>/dev/null || true)\n\`\`\`\n"

  write_blocker_ticket "validation failed; no commit made" "$body"
  ensure_planner_blocker_notice || true
  rm -rf "$tmp_dir" || true
  
  # check shutdown timeout after ticket processing
  if [[ "$shutdown_requested" == "1" && -n "$shutdown_start_time" ]]; then
    local elapsed
    elapsed=$(($(date +%s) - shutdown_start_time))
    if [[ $elapsed -ge $shutdown_timeout ]]; then
      log_status "shutdown timeout exceeded (${elapsed}s > ${shutdown_timeout}s); forcing exit"
      current_ticket_path=""
      return 1
    fi
  fi
  
  current_ticket_path=""
}

while [[ "$shutdown_requested" == "0" ]]; do
  next="$(claim_next_ticket || true)"
  if [[ -n "${next:-}" ]]; then
    process_ticket "$next" || true
  else
    if [[ "$shutdown_requested" == "1" ]]; then
      break
    fi
    log_status "idle: no judge tickets"
  fi
  if [[ "$shutdown_requested" == "1" ]]; then
    break
  fi
  /bin/sleep "$SLEEP_SECS"
done

if [[ -n "$current_ticket_path" && -f "$current_ticket_path" ]]; then
  base_name="$(basename "$current_ticket_path" | sed -E 's/\.[0-9]+\.[0-9]+$//')"
  log_status "shutdown during ticket processing; requeueing: ${base_name}"
  mv "$current_ticket_path" "tasks/judge_queue/$base_name" 2>/dev/null || true
fi

if [[ "$shutdown_requested" == "1" ]]; then
  log_status "judge daemon shutdown complete"
else
  log_status "judge daemon stopped"
fi

