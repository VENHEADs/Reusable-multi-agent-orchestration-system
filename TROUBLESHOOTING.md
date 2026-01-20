# Agent Factory Troubleshooting Guide

This guide covers common issues, error patterns, and debugging strategies for agent_factory.

## Documentation Status

This troubleshooting guide is comprehensive and covers all essential troubleshooting scenarios:

✅ **Quick Reference** - Essential commands, decision trees, and one-command diagnostics
✅ **Common Errors** - Agent CLI, authentication, empty output, NEED-INFO, rate limits, timeouts
✅ **Queue Issues** - Tasks not processing, stuck tasks, queue imbalances
✅ **Agent Execution Problems** - No changes, wrong changes, hanging processes
✅ **Judge Validation Failures** - Pytest, ruff format, ruff check, environment issues
✅ **Performance Issues** - Slow processing, high API usage, optimization strategies
✅ **Launchd Problems** - Jobs not starting, crashing, not processing
✅ **Configuration Issues** - Config not applied, wrong defaults
✅ **Real-World Scenarios** - Practical examples with step-by-step solutions
✅ **Advanced Troubleshooting** - Intermittent failures, validation inconsistencies, queue deadlocks
✅ **Migration Troubleshooting** - Updating agent_factory in existing projects

For best practices, performance tuning, security considerations, and configuration examples, see [README.md](README.md).

## Navigation

**Quick Start:**
- [Quick Reference](#quick-reference) - Essential commands and decision trees
- [One-Command Diagnostics](#one-command-diagnostics) - Fast diagnostic commands

**Common Issues:**
- [Common Errors](#common-errors) - Agent CLI, authentication, empty output, NEED-INFO, rate limits, timeouts
- [Queue Issues](#queue-issues) - Tasks not processing, stuck tasks, queue imbalances
- [Agent Execution Problems](#agent-execution-problems) - No changes, wrong changes, hanging processes
- [Judge Validation Failures](#judge-validation-failures) - Pytest, ruff format, ruff check, environment issues

**Advanced Troubleshooting:**
- [Performance Issues](#performance-issues) - Slow processing, high API usage
- [Launchd Problems](#launchd-problems) - Jobs not starting, crashing, not processing
- [Configuration Issues](#configuration-issues) - Config not applied, wrong defaults
- [Migration Troubleshooting](#migration-troubleshooting) - Updating agent_factory in existing projects
- [Real-World Troubleshooting Scenarios](#real-world-troubleshooting-scenarios) - Practical examples

**Related Documentation:**
- [README.md](README.md) - Complete agent_factory documentation including best practices
- [documentation.md](../../documentation.md) - Project-specific documentation

## Quick Reference

### Essential Commands Cheat Sheet

**System Status:**
```bash
./agent_factory/monitor.sh              # full status dashboard
./agent_factory/monitor.sh --health    # health check only
./agent_factory/queue_status.sh        # quick queue overview
```

**Agent Control:**
```bash
./ops/agent_factory/start.sh           # start all agents
./ops/agent_factory/stop.sh            # stop all agents
./ops/agent_factory/status.sh         # check agent status
```

**Logs and Debugging:**
```bash
./agent_factory/watch_logs.sh          # latest agent run
./agent_factory/log_search.sh --errors # find errors
./agent_factory/provenance_summary.sh  # task execution history
```

**Common Fixes:**
```bash
# restart everything (fixes most issues)
./ops/agent_factory/stop.sh && ./ops/agent_factory/start.sh

# fix environment
./ops/bootstrap_python.sh

# check judge blockers
cat .agent_factory_state/judge_blocker.md
```

### Quick Diagnosis by Symptom

**Symptom: Nothing is happening**
```bash
# 1. Check if agents are running
ps aux | grep orchestrator

# 2. Check launchd jobs
./agent_factory/monitor.sh --launchd

# 3. Check queue status
./agent_factory/queue_status.sh

# 4. Quick fix: restart
./ops/agent_factory/stop.sh && ./ops/agent_factory/start.sh
```

**Symptom: Tasks stuck in queue**
```bash
# 1. Check for stuck tasks
./agent_factory/monitor.sh --health

# 2. Check task ages
find tasks/queue -maxdepth 1 -name "*.md" -type f -exec stat -f "%Sm %N" -t "%Y-%m-%d %H:%M:%S" {} \; | sort

# 3. Check latest errors
./agent_factory/log_search.sh --errors --recent 5

# 4. Quick fix: restart and check goal file
./ops/agent_factory/stop.sh && ./ops/agent_factory/start.sh
test -f goal.md || cp agent_factory/goal_template.md goal.md
```

**Symptom: Judge not committing**
```bash
# 1. Check blocker ticket
cat .agent_factory_state/judge_blocker.md

# 2. Fix environment issues first (🔧 section)
./ops/bootstrap_python.sh

# 3. Fix code issues (💻 section)
source .venv/bin/activate
pytest && ruff format --check . && ruff check .

# 4. Judge will commit automatically on next run
```

**Symptom: Frequent rate limit errors**
```bash
# 1. Check fallback usage
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | select(.agent_model.used_fallback == true)] | length'

# 2. Switch to cheaper model
vim Agent_profiles/worker.md  # change to --model gpt-4o-mini

# 3. Increase sleep intervals
export ORCHESTRATOR_SLEEP_SECS=10
# or edit agent_factory/config.sh
```

**Symptom: Tasks taking too long**
```bash
# 1. Check average execution time
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | .execution_duration_secs] | add / length'

# 2. Find slow tasks
./agent_factory/provenance_summary.sh --detailed | \
  grep -E "duration.*[5-9][0-9]m|duration.*[1-9]h"

# 3. Break large tasks into smaller ones
# Split 50 LOC task into 3-4 atomic tasks

# 4. Use faster model
vim Agent_profiles/worker.md  # change to --model gpt-4o-mini
```

### Decision Tree: What to Do When Something Goes Wrong

**Problem: Tasks not processing**
```
1. Check if agents are running:
   → ps aux | grep orchestrator
   → If not running: ./ops/agent_factory/start.sh

2. Check queue status:
   → ./agent_factory/queue_status.sh
   → If tasks pending: check health status

3. Check for stuck tasks:
   → ./agent_factory/monitor.sh --health
   → If stuck: restart agents

4. Check latest logs:
   → ./agent_factory/watch_logs.sh --tail 50
   → Look for errors or empty output
```

**Problem: Judge not committing**
```
1. Check blocker ticket:
   → cat .agent_factory_state/judge_blocker.md
   → Fix environment issues first (🔧 section)
   → Then fix code issues (💻 section)

2. Run validation manually:
   → source .venv/bin/activate
   → pytest && ruff format --check . && ruff check .
   → Fix any failures

3. Judge will commit automatically on next run
```

**Problem: Frequent rate limit errors**
```
1. Check fallback usage:
   → ./agent_factory/provenance_summary.sh --json | \
     jq '[.[] | select(.agent_model.used_fallback == true)] | length'

2. Switch to cheaper model:
   → Edit Agent_profiles/worker.md: use --model gpt-4o-mini

3. Increase sleep intervals:
   → export ORCHESTRATOR_SLEEP_SECS=10
   → Or edit agent_factory/config.sh

4. Reduce concurrency:
   → export ORCHESTRATOR_MAX_SPAWNS=1
```

**Problem: Tasks taking too long**
```
1. Check average execution time:
   → ./agent_factory/provenance_summary.sh --json | \
     jq '[.[] | .execution_duration_secs] | add / length'

2. Find slow tasks:
   → ./agent_factory/provenance_summary.sh --detailed | \
     grep -E "duration.*[5-9][0-9]m|duration.*[1-9]h"

3. Break large tasks into smaller ones:
   → Split 50 LOC task into 3-4 atomic tasks

4. Use faster model:
   → Edit Agent_profiles/worker.md: use --model gpt-4o-mini
```

### One-Command Diagnostics

```bash
# full system status
./agent_factory/monitor.sh

# queue health check
./agent_factory/monitor.sh --health

# recent errors only
./agent_factory/log_search.sh --errors --recent 5

# failed tasks summary
./agent_factory/provenance_summary.sh --failed-only

# restart everything (fixes most issues)
./ops/agent_factory/stop.sh && ./ops/agent_factory/start.sh
```

### Quick Fixes by Symptom

**Tasks not processing:**
```bash
./ops/agent_factory/stop.sh && ./ops/agent_factory/start.sh
```

**Judge not committing:**
```bash
cat .agent_factory_state/judge_blocker.md
# fix issues shown, then judge will commit on next run
```

**Rate limit errors:**
```bash
# switch to cheaper model
vim Agent_profiles/worker.md  # change to --model gpt-4o-mini
```

**Empty output errors:**
```bash
# check environment
./ops/bootstrap_python.sh
# verify goal file
test -f goal.md || cp agent_factory/goal_template.md goal.md
```

**Timeout errors:**
```bash
# increase timeout or break task into smaller pieces
export AGENT_EXECUTION_TIMEOUT_SECS=3600
# or edit agent_factory/config.sh
```

**Stuck tasks:**
```bash
# check health
./agent_factory/monitor.sh --health
# restart if needed
./ops/agent_factory/stop.sh && ./ops/agent_factory/start.sh
```

### Common Fixes

| Problem | Quick Fix |
|---------|-----------|
| Tasks not processing | `./ops/agent_factory/stop.sh && ./ops/agent_factory/start.sh` |
| Judge not committing | `cat .agent_factory_state/judge_blocker.md` then fix issues |
| Rate limit errors | Edit `Agent_profiles/worker.md` to use `gpt-4o-mini` |
| Empty output | Check `./agent_factory/watch_logs.sh --tail 50` |
| NEED-INFO responses | Update task file with missing information |
| Timeout errors | Increase `AGENT_EXECUTION_TIMEOUT_SECS` in `config.sh` |

### Error Code Reference

| Code | Meaning | Action |
|------|---------|--------|
| 0 | Success | None needed |
| 1 | Execution failure | Check logs, may need code fixes |
| 2 | Empty output | Check environment, verify goal file |
| 3 | NEED-INFO | Update task with missing information |
| 4 | Timeout | Increase timeout or break task into smaller pieces |

### Diagnostic Command Cheat Sheet

```bash
# system status
./agent_factory/monitor.sh                    # full status
./agent_factory/monitor.sh --health           # health check only
./agent_factory/monitor.sh --watch            # auto-refresh

# queue status
./agent_factory/queue_status.sh               # quick overview
find tasks/queue -name "*.md" | wc -l         # count pending

# logs
./agent_factory/watch_logs.sh                 # latest run
./agent_factory/watch_logs.sh --follow        # follow in real-time
./agent_factory/log_search.sh "error"         # search logs
./agent_factory/log_search.sh --errors       # find errors

# provenance
./agent_factory/provenance_summary.sh         # summary stats
./agent_factory/provenance_summary.sh --failed-only  # failures only
./agent_factory/provenance_summary.sh --detailed     # detailed info

# agents
ps aux | grep orchestrator                    # check if running
launchctl list | grep YOUR_PROJECT            # launchd status

# configuration
source agent_factory/config.sh
echo "SLEEP=$ORCHESTRATOR_SLEEP_SECS"         # check config
```

## Table of Contents

- [Quick Reference](#quick-reference)
- [Common Errors](#common-errors)
- [Debugging Strategies](#debugging-strategies)
- [Queue Issues](#queue-issues)
- [Agent Execution Problems](#agent-execution-problems)
- [Judge Validation Failures](#judge-validation-failures)
- [Performance Issues](#performance-issues)
- [Launchd Problems](#launchd-problems)
- [Configuration Issues](#configuration-issues)
- [Migration Troubleshooting](#migration-troubleshooting)
- [Real-World Troubleshooting Scenarios](#real-world-troubleshooting-scenarios)
- [Summary: Best Practices for Troubleshooting](#summary-best-practices-for-troubleshooting)

## Common Errors

### Agent CLI Not Found

**Symptoms:**
```
error: agent command not found
```

**Solutions:**
```bash
# check if agent is installed
command -v agent || echo "not installed"

# install agent CLI
curl -fsS https://cursor.com/install | bash

# verify installation
agent --version

# ensure agent is in PATH
export PATH="$HOME/.local/bin:$PATH"
```

**Prevention:**
- add `~/.local/bin` to your PATH in `~/.zshrc` or `~/.bashrc`
- verify agent is accessible before starting launchd jobs

### Authentication Errors

**Symptoms:**
```
error: authentication failed
error: invalid API key
```

**Solutions:**
```bash
# check auth status
agent status

# login interactively
agent login

# or store API key in macOS Keychain
security add-generic-password -a "$USER" -s "cursor_cli_api_key" -w
# paste API key when prompted

# verify keychain storage
security find-generic-password -a "$USER" -s "cursor_cli_api_key" -w
```

**Prevention:**
- always run `agent login` after installation
- use Keychain for persistent storage (recommended for launchd jobs)
- verify authentication before starting background jobs

### Empty Agent Output

**Symptoms:**
- task is requeued with return code 2
- log file shows empty output
- provenance shows `status: "failed"` with `error_code: "empty_output"`

**Diagnosis:**
```bash
# check latest agent run log
./agent_factory/watch_logs.sh --tail 50

# search for empty output errors
./agent_factory/log_search.sh "empty output"

# check provenance for empty output
./agent_factory/provenance_summary.sh --failed-only --detailed | grep -i empty
```

**Common Causes:**
1. **environment issues**: missing dependencies, wrong python version
2. **empty prompts**: goal file or profile is empty/malformed
3. **rate limits**: agent hit rate limit before producing output
4. **timeout**: agent execution exceeded timeout (check `AGENT_EXECUTION_TIMEOUT_SECS`)

**Solutions:**
```bash
# check environment
python3 --version
which pytest
which ruff

# verify goal file exists and is readable
cat goal.md

# verify agent profile is valid
cat Agent_profiles/worker.md

# check for rate limit errors in logs
./agent_factory/log_search.sh "rate limit"

# increase timeout if needed
export AGENT_EXECUTION_TIMEOUT_SECS=3600
```

**Prevention:**
- always verify goal file and profiles before starting agents
- ensure all dependencies are installed (`./ops/bootstrap_python.sh`)
- monitor rate limits and configure fallback models

### NEED-INFO Responses

**Symptoms:**
- task is requeued with return code 3
- log file contains "NEED-INFO:" message
- agent is asking questions instead of implementing

**Diagnosis:**
```bash
# find NEED-INFO responses
./agent_factory/log_search.sh "NEED-INFO"

# check specific task log
./agent_factory/watch_logs.sh --tail 100 | grep -A 10 "NEED-INFO"
```

**Common Causes:**
1. **ambiguous task description**: task lacks required information
2. **missing context**: agent profile doesn't provide enough guidance
3. **blocker dependencies**: task depends on uncompleted work

**Solutions:**
```bash
# update task with missing information
vim tasks/queue/problematic_task.md

# update agent profile to be more explicit
vim Agent_profiles/worker.md

# create blocker ticket if dependencies are missing
echo "# BLOCKER: Missing dependency X" > tasks/queue/00_BLOCKER_missing_dependency.md
```

**Prevention:**
- write clear, specific task descriptions
- include all required context in task files
- ensure agent profiles explicitly forbid questions
- create blocker tickets for missing prerequisites

### Rate Limit Errors

**Symptoms:**
- task fails with rate limit error
- orchestrator automatically retries with fallback model
- log shows "rate limit" or "429" errors

**Diagnosis:**
```bash
# check for rate limit errors
./agent_factory/log_search.sh "rate limit"

# check provenance for fallback usage
./agent_factory/provenance_summary.sh --detailed | grep -i fallback

# check model usage
./agent_factory/provenance_summary.sh --json | jq '.[] | select(.agent_model.used_fallback == true)'
```

**Solutions:**
```bash
# configure fallback model (already done by default)
export FALLBACK_MODEL="gpt-5.2-codex-low"

# reduce concurrency to avoid rate limits
export ORCHESTRATOR_MAX_SPAWNS=1

# increase sleep intervals
export ORCHESTRATOR_SLEEP_SECS=10

# use lower-tier models for workers
# edit Agent_profiles/worker.md to use --model gpt-4o-mini
```

**Prevention:**
- always configure fallback models
- monitor rate limit usage
- use appropriate models for each agent role
- implement exponential backoff (already done)

### Timeout Errors

**Symptoms:**
- task is requeued with return code 4
- log shows "timeout" or "exceeded timeout"
- provenance shows `error_code: "timeout"`

**Diagnosis:**
```bash
# find timeout errors
./agent_factory/log_search.sh "timeout"

# check execution durations
./agent_factory/provenance_summary.sh --detailed | grep -i duration

# check timeout configuration
grep AGENT_EXECUTION_TIMEOUT_SECS agent_factory/config.sh
```

**Solutions:**
```bash
# increase timeout (default: 1800 seconds = 30 minutes)
export AGENT_EXECUTION_TIMEOUT_SECS=3600

# or edit config.sh
vim agent_factory/config.sh
# change: AGENT_EXECUTION_TIMEOUT_SECS="${AGENT_EXECUTION_TIMEOUT_SECS:-3600}"

# break large tasks into smaller ones
# split complex tasks into multiple atomic tasks
```

**Prevention:**
- keep tasks atomic (≤15 LOC or one shell command)
- break complex tasks into smaller subtasks
- set appropriate timeout for your use case
- monitor task execution durations

## Debugging Strategies

### Check System Status

```bash
# comprehensive status check
./agent_factory/monitor.sh

# specific sections
./agent_factory/monitor.sh --queues    # queue status
./agent_factory/monitor.sh --logs      # log statistics
./agent_factory/monitor.sh --git       # git status
./agent_factory/monitor.sh --launchd   # launchd jobs
./agent_factory/monitor.sh --health    # health checks
```

### Examine Latest Agent Run

```bash
# show last 80 lines
./agent_factory/watch_logs.sh

# follow in real-time
./agent_factory/watch_logs.sh --follow

# show last N lines
./agent_factory/watch_logs.sh --tail 200
```

### Search Logs

```bash
# search for pattern
./agent_factory/log_search.sh "error message"

# search in all logs (including compressed)
./agent_factory/log_search.sh --all "pattern"

# find logs with errors
./agent_factory/log_search.sh --errors

# show recent N logs
./agent_factory/log_search.sh --recent 10

# grep across all logs
./agent_factory/log_search.sh --grep "TIMEOUT"
```

### Analyze Provenance

```bash
# summary statistics
./agent_factory/provenance_summary.sh

# detailed information
./agent_factory/provenance_summary.sh --detailed

# filter by status
./agent_factory/provenance_summary.sh --failed-only --detailed
./agent_factory/provenance_summary.sh --requeued-only --detailed

# filter by queue
./agent_factory/provenance_summary.sh --queue-dir tasks/queue --detailed

# filter by model
./agent_factory/provenance_summary.sh --model gpt-4 --detailed

# JSON output for scripting
./agent_factory/provenance_summary.sh --json | jq '.[] | select(.status == "failed")'
```

### Test Agent Execution Manually

```bash
# run orchestrator manually with verbose output
./agent_factory/run_orchestrator \
  --profile Agent_profiles/worker.md \
  --goal-file goal.md \
  --queue-dir tasks/queue \
  --max 1 \
  --once

# check exit code
echo $?

# examine log file
ls -lt logs/agent_runs/ | head -1
tail -100 logs/agent_runs/$(ls -1t logs/agent_runs | head -1)
```

## Queue Issues

### Tasks Not Processing

**Symptoms:**
- tasks remain in queue directory
- no agent activity
- launchd jobs not running

**Diagnosis:**
```bash
# check launchd job status
./agent_factory/monitor.sh --launchd

# check if orchestrator is running
ps aux | grep orchestrator

# check queue status
./agent_factory/queue_status.sh

# check for stuck tasks
./agent_factory/monitor.sh --health
```

**Solutions:**
```bash
# restart launchd jobs
./ops/agent_factory/stop.sh
./ops/agent_factory/start.sh

# verify jobs are loaded
launchctl list | grep com.YOUR_PROJECT

# check job logs
launchctl print gui/$(id -u)/com.YOUR_PROJECT.worker | grep -i error

# manually run orchestrator to test
./agent_factory/run_orchestrator \
  --profile Agent_profiles/worker.md \
  --goal-file goal.md \
  --queue-dir tasks/queue \
  --max 1 \
  --once
```

### Tasks Stuck in Queue

**Symptoms:**
- tasks older than 1 hour remain pending
- health check shows "critical" status
- no processing activity

**Diagnosis:**
```bash
# check for stuck tasks
./agent_factory/monitor.sh --health

# check task ages
find tasks/queue -maxdepth 1 -name "*.md" -type f -exec stat -f "%Sm %N" -t "%Y-%m-%d %H:%M:%S" {} \; | sort

# check if tasks are being claimed
ls -la tasks/queue/processed/ | tail -10
```

**Solutions:**
```bash
# check if agent is actually running
ps aux | grep -E "(orchestrator|agent)"

# check for errors in logs
./agent_factory/log_search.sh --errors --recent 5

# verify goal file exists
test -f goal.md || echo "ERROR: goal.md missing"

# verify agent profile exists
test -f Agent_profiles/worker.md || echo "ERROR: worker profile missing"

# manually process a task to test
./agent_factory/run_orchestrator \
  --profile Agent_profiles/worker.md \
  --goal-file goal.md \
  --queue-dir tasks/queue \
  --max 1 \
  --once
```

### Queue Imbalances

**Symptoms:**
- upstream queue empty, downstream queue full
- planner_queue empty but subplanner_queue has many tasks
- health check shows "warning" for queue imbalance

**Diagnosis:**
```bash
# check queue health
./agent_factory/monitor.sh --health

# check queue counts
./agent_factory/queue_status.sh

# check processing rates
./agent_factory/provenance_summary.sh --json | jq '[.[] | select(.queue_dir == "tasks/planner_queue")] | length'
```

**Solutions:**
```bash
# check if planner is running
launchctl list | grep planner

# check planner logs
./agent_factory/watch_logs.sh | grep -i planner

# manually trigger planner
./agent_factory/run_orchestrator \
  --profile Agent_profiles/primary_planner.md \
  --goal-file goal.md \
  --queue-dir tasks/planner_queue \
  --max 1 \
  --once

# adjust throttling thresholds if needed
vim agent_factory/config.sh
# increase MAX_SUBPLANNER_PENDING if subplanner is too slow
```

## Agent Execution Problems

### Agent Produces No Changes

**Symptoms:**
- task completes successfully but no files changed
- git status shows no modifications
- provenance shows `newly_dirty_files: []`

**Diagnosis:**
```bash
# check task description
cat tasks/queue/problematic_task.md

# check agent output
./agent_factory/watch_logs.sh --tail 200

# check provenance
./agent_factory/provenance_summary.sh --detailed | grep -A 5 "problematic_task"
```

**Common Causes:**
1. **task already completed**: agent determined work was already done
2. **task description unclear**: agent didn't understand what to do
3. **agent profile too restrictive**: profile prevents agent from making changes

**Solutions:**
```bash
# verify task is clear and actionable
cat tasks/queue/problematic_task.md

# check agent profile for restrictions
grep -i "do not\|never\|avoid" Agent_profiles/worker.md

# update task with more specific instructions
vim tasks/queue/problematic_task.md
```

### Agent Makes Wrong Changes

**Symptoms:**
- agent modifies wrong files
- changes don't match task requirements
- test failures after agent execution

**Diagnosis:**
```bash
# check what files were changed
git diff --name-only

# check agent output
./agent_factory/watch_logs.sh --tail 200

# check task description
cat tasks/queue/problematic_task.md
```

**Solutions:**
```bash
# revert changes
git checkout -- .

# update task with more specific file paths
vim tasks/queue/problematic_task.md
# add explicit "File Paths" section

# update agent profile to be more explicit
vim Agent_profiles/worker.md
# add guidance about reading task file paths carefully
```

### Agent Execution Hangs

**Symptoms:**
- agent process running but no output
- task not completing
- timeout not triggering

**Diagnosis:**
```bash
# check if agent process is running
ps aux | grep -E "(agent|orchestrator)"

# check process age
ps -eo pid,etime,cmd | grep agent

# check timeout configuration
grep AGENT_EXECUTION_TIMEOUT_SECS agent_factory/config.sh
```

**Solutions:**
```bash
# kill hanging process
pkill -f "agent.*worker"

# check for infinite loops in agent output
./agent_factory/watch_logs.sh --tail 500 | grep -i "loop\|infinite\|recursive"

# increase timeout if task is legitimately long-running
export AGENT_EXECUTION_TIMEOUT_SECS=7200

# break task into smaller pieces
# split large task into multiple atomic tasks
```

## Judge Validation Failures

### Pytest Failures

**Symptoms:**
- judge creates blocker ticket
- pytest fails with test errors
- blocker ticket shows "code issues" section

**Diagnosis:**
```bash
# check blocker ticket
cat .agent_factory_state/judge_blocker.md

# run pytest manually
source .venv/bin/activate
pytest

# check specific test failures
pytest -v --tb=short
```

**Solutions:**
```bash
# fix test failures locally
pytest -v

# update code to fix failures
# then verify tests pass
pytest

# judge will automatically pick up fixes on next run
```

### Ruff Format Errors

**Symptoms:**
- judge creates blocker ticket
- ruff format check fails
- blocker ticket shows formatting issues

**Diagnosis:**
```bash
# check blocker ticket
cat .agent_factory_state/judge_blocker.md

# run ruff format check manually
source .venv/bin/activate
ruff format --check .

# see what needs formatting
ruff format --diff .
```

**Solutions:**
```bash
# auto-format code
ruff format .

# verify formatting
ruff format --check .

# judge will automatically pick up fixes on next run
```

### Ruff Check Errors

**Symptoms:**
- judge creates blocker ticket
- ruff check fails with lint errors
- blocker ticket shows lint issues grouped by file

**Diagnosis:**
```bash
# check blocker ticket
cat .agent_factory_state/judge_blocker.md

# run ruff check manually
source .venv/bin/activate
ruff check .

# check specific errors
ruff check . --output-format=concise
```

**Solutions:**
```bash
# fix lint errors
ruff check . --fix

# verify all errors fixed
ruff check .

# judge will automatically pick up fixes on next run
```

### Environment Issues

**Symptoms:**
- judge creates blocker ticket
- blocker ticket shows "environment issues" section
- pytest or ruff not found

**Diagnosis:**
```bash
# check blocker ticket
cat .agent_factory_state/judge_blocker.md

# check python environment
which python3
python3 --version

# check if venv exists
test -d .venv && echo "venv exists" || echo "venv missing"

# check if dependencies installed
source .venv/bin/activate
which pytest
which ruff
```

**Solutions:**
```bash
# bootstrap python environment
./ops/bootstrap_python.sh

# verify installation
source .venv/bin/activate
pytest --version
ruff --version

# judge will automatically pick up fixes on next run
```

## Performance Issues

### Slow Task Processing

**Symptoms:**
- tasks take a long time to complete
- low processing rate (tasks/hour)
- queue backing up

**Diagnosis:**
```bash
# check processing rates
./agent_factory/monitor.sh --health

# check average execution duration
./agent_factory/provenance_summary.sh --json | jq '[.[] | .execution_duration_secs] | add / length'

# check for slow tasks
./agent_factory/provenance_summary.sh --detailed | grep -E "duration|execution"
```

**Solutions:**
```bash
# use faster models for workers
# edit Agent_profiles/worker.md to use --model gpt-4o-mini

# reduce task complexity
# break large tasks into smaller atomic tasks

# increase concurrency (if not rate-limited)
export ORCHESTRATOR_MAX_SPAWNS=2

# reduce sleep intervals
export ORCHESTRATOR_SLEEP_SECS=3
```

### High API Usage

**Symptoms:**
- hitting rate limits frequently
- high API costs
- fallback model used often

**Diagnosis:**
```bash
# check fallback usage
./agent_factory/provenance_summary.sh --json | jq '[.[] | select(.agent_model.used_fallback == true)] | length'

# check model distribution
./agent_factory/provenance_summary.sh --json | jq '[.[] | .agent_model.final] | group_by(.) | map({model: .[0], count: length})'

# check for rate limit errors
./agent_factory/log_search.sh "rate limit" | wc -l
```

**Solutions:**
```bash
# use lower-tier models
# edit Agent_profiles/worker.md to use --model gpt-4o-mini

# reduce concurrency
export ORCHESTRATOR_MAX_SPAWNS=1

# increase sleep intervals
export ORCHESTRATOR_SLEEP_SECS=10

# optimize task descriptions to be more concise
# shorter prompts = lower token usage
```

## Launchd Problems

### Jobs Not Starting

**Symptoms:**
- launchd jobs not running
- `launchctl list` shows no jobs
- monitor shows no activity

**Diagnosis:**
```bash
# check job status
./agent_factory/monitor.sh --launchd

# check if plists exist
ls -la ~/Library/LaunchAgents/com.YOUR_PROJECT.*

# check job errors
launchctl print gui/$(id -u)/com.YOUR_PROJECT.worker 2>&1 | grep -i error
```

**Solutions:**
```bash
# restart jobs
./ops/agent_factory/stop.sh
./ops/agent_factory/start.sh

# verify jobs loaded
launchctl list | grep com.YOUR_PROJECT

# check plist syntax
plutil -lint ~/Library/LaunchAgents/com.YOUR_PROJECT.worker.plist

# check file paths in plist
cat ~/Library/LaunchAgents/com.YOUR_PROJECT.worker.plist | grep -E "REPO_ROOT|agent_factory"
```

### Jobs Crashing

**Symptoms:**
- launchd jobs start then immediately exit
- `launchctl print` shows non-zero exit code
- jobs not staying running

**Diagnosis:**
```bash
# check exit codes
launchctl print gui/$(id -u)/com.YOUR_PROJECT.worker | grep "last exit code"

# check standard error
# launchd logs to system log, check Console.app or:
log show --predicate 'process == "orchestrator"' --last 5m

# check if goal file exists
test -f goal.md || echo "ERROR: goal.md missing"
```

**Solutions:**
```bash
# verify goal file exists
test -f goal.md && echo "goal.md exists" || cp agent_factory/goal_template.md goal.md

# verify agent profiles exist
test -f Agent_profiles/worker.md || echo "ERROR: worker profile missing"

# test orchestrator manually
./agent_factory/run_orchestrator \
  --profile Agent_profiles/worker.md \
  --goal-file goal.md \
  --queue-dir tasks/queue \
  --max 1 \
  --once

# check for syntax errors in scripts
bash -n agent_factory/orchestrator
bash -n agent_factory/judge_daemon.sh
```

### Jobs Not Processing Tasks

**Symptoms:**
- jobs are running but tasks not processing
- queue not decreasing
- no agent activity

**Diagnosis:**
```bash
# check if jobs are actually running
launchctl list | grep com.YOUR_PROJECT

# check queue status
./agent_factory/queue_status.sh

# check for errors in system log
log show --predicate 'process == "orchestrator"' --last 10m | grep -i error

# manually test orchestrator
./agent_factory/run_orchestrator \
  --profile Agent_profiles/worker.md \
  --goal-file goal.md \
  --queue-dir tasks/queue \
  --max 1 \
  --once
```

**Solutions:**
```bash
# verify goal file path in plist
cat ~/Library/LaunchAgents/com.YOUR_PROJECT.worker.plist | grep goal-file

# verify queue directory exists
test -d tasks/queue || mkdir -p tasks/queue

# verify agent profile path
test -f Agent_profiles/worker.md || echo "ERROR: profile missing"

# restart jobs
./ops/agent_factory/stop.sh
./ops/agent_factory/start.sh
```

## Configuration Issues

### Configuration Not Applied

**Symptoms:**
- changes to `config.sh` not taking effect
- environment variables not working
- defaults not being used

**Diagnosis:**
```bash
# check if config.sh is being sourced
grep -r "source.*config.sh" agent_factory/*.sh

# check current configuration values
source agent_factory/config.sh
echo "ORCHESTRATOR_SLEEP_SECS=$ORCHESTRATOR_SLEEP_SECS"

# check for environment variable overrides
env | grep -E "ORCHESTRATOR|JUDGE|MAX_"
```

**Solutions:**
```bash
# verify config.sh syntax
bash -n agent_factory/config.sh

# restart jobs to pick up config changes
./ops/agent_factory/stop.sh
./ops/agent_factory/start.sh

# use environment variables for temporary overrides
export ORCHESTRATOR_SLEEP_SECS=10
./agent_factory/run_orchestrator --profile Agent_profiles/worker.md --queue-dir tasks/queue
```

### Wrong Default Values

**Symptoms:**
- system behavior doesn't match expectations
- thresholds too high/low
- timeouts incorrect

**Diagnosis:**
```bash
# check current defaults
cat agent_factory/config.sh | grep -E "ORCHESTRATOR_SLEEP_SECS|MAX_WORKER_PENDING|AGENT_EXECUTION_TIMEOUT_SECS"

# check what values are actually being used
source agent_factory/config.sh
echo "ORCHESTRATOR_SLEEP_SECS=${ORCHESTRATOR_SLEEP_SECS}"
echo "MAX_WORKER_PENDING=${MAX_WORKER_PENDING}"
```

**Solutions:**
```bash
# edit config.sh with appropriate values
vim agent_factory/config.sh

# restart jobs to apply changes
./ops/agent_factory/stop.sh
./ops/agent_factory/start.sh

# verify changes applied
./agent_factory/monitor.sh
```

## Real-World Troubleshooting Scenarios

### Scenario 1: Tasks Processing Slowly

**Symptoms:**
- tasks taking 10+ minutes each
- queue backing up
- low processing rate

**Diagnosis:**
```bash
# check average execution time
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | .execution_duration_secs] | add / length'

# check for slow tasks
./agent_factory/provenance_summary.sh --detailed | \
  grep -E "duration.*[5-9][0-9]m|duration.*[1-9]h"
```

**Solutions:**
```bash
# use faster model for workers
# edit Agent_profiles/worker.md: add --model gpt-4o-mini

# break large tasks into smaller ones
# split 50 LOC task into 3-4 smaller tasks

# reduce sleep interval (if not rate-limited)
export ORCHESTRATOR_SLEEP_SECS=3
```

### Scenario 2: Frequent Rate Limit Errors

**Symptoms:**
- many tasks failing with rate limit errors
- fallback model used frequently
- tasks requeued multiple times

**Diagnosis:**
```bash
# count rate limit errors
./agent_factory/log_search.sh "rate limit" | wc -l

# check fallback usage
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | select(.agent_model.used_fallback == true)] | length'
```

**Solutions:**
```bash
# use lower-tier models
# edit Agent_profiles/worker.md: use gpt-4o-mini instead of gpt-4

# increase sleep intervals
export ORCHESTRATOR_SLEEP_SECS=10

# reduce concurrency
export ORCHESTRATOR_MAX_SPAWNS=1

# optimize task descriptions (shorter = fewer tokens)
```

### Scenario 3: Judge Not Committing

**Symptoms:**
- judge runs but no commits
- blocker ticket created but not resolved
- tests passing locally but judge fails

**Diagnosis:**
```bash
# check blocker ticket
cat .agent_factory_state/judge_blocker.md

# check if judge is running
launchctl list | grep judge

# check judge logs
./agent_factory/watch_logs.sh | grep -i judge
```

**Solutions:**
```bash
# fix environment issues first
./ops/bootstrap_python.sh

# run validation manually
source .venv/bin/activate
pytest
ruff format --check .
ruff check .

# fix code issues, then judge will commit on next run
```

### Scenario 4: Tasks Stuck in Queue

**Symptoms:**
- tasks not processing for hours
- health check shows "critical"
- no agent activity

**Diagnosis:**
```bash
# check for stuck tasks
./agent_factory/monitor.sh --health

# check if agents are running
ps aux | grep -E "(orchestrator|agent)"

# check launchd jobs
./agent_factory/monitor.sh --launchd
```

**Solutions:**
```bash
# restart agents
./ops/agent_factory/stop.sh
./ops/agent_factory/start.sh

# verify goal file exists
test -f goal.md || cp agent_factory/goal_template.md goal.md

# manually test one task
./agent_factory/run_orchestrator \
  --profile Agent_profiles/worker.md \
  --goal-file goal.md \
  --queue-dir tasks/queue \
  --max 1 \
  --once
```

### Scenario 5: Agent Makes Wrong Changes

**Symptoms:**
- agent modifies wrong files
- changes don't match task requirements
- tests fail after agent execution

**Diagnosis:**
```bash
# check what was changed
git diff --name-only

# check agent output
./agent_factory/watch_logs.sh --tail 200

# check task description
cat tasks/queue/problematic_task.md
```

**Solutions:**
```bash
# revert changes
git checkout -- .

# update task with explicit file paths
vim tasks/queue/problematic_task.md
# add clear "File Paths" section with exact files

# update agent profile to emphasize reading task carefully
vim Agent_profiles/worker.md
# add: "read task file completely, especially File Paths section"
```

### Scenario 6: High API Costs

**Symptoms:**
- unexpected API usage
- hitting quota limits
- expensive model usage

**Diagnosis:**
```bash
# check model distribution
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | .agent_model.final] | group_by(.) | map({model: .[0], count: length})'

# check for expensive models
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | select(.agent_model.final == "gpt-4")] | length'
```

**Solutions:**
```bash
# use cheaper models for workers
# edit Agent_profiles/worker.md: use gpt-4o-mini

# optimize task descriptions
# shorter prompts = lower token usage

# reduce unnecessary retries
# ensure fallback models are configured

# monitor usage regularly
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | .execution_duration_secs] | add'
```

## Migration Troubleshooting

### Updating agent_factory in Existing Projects

When updating agent_factory to a newer version, you may encounter issues. This section covers common migration problems and solutions.

**Symptoms:**
- scripts fail after update
- configuration not working
- launchd jobs not starting
- backward compatibility issues

**Diagnosis:**
```bash
# check script syntax
bash -n agent_factory/orchestrator
bash -n agent_factory/judge_daemon.sh

# check configuration syntax
bash -n agent_factory/config.sh

# check for breaking changes
diff agent_factory.backup/config.sh agent_factory/config.sh

# check launchd plist syntax
plutil -lint ~/Library/LaunchAgents/com.YOUR_PROJECT.worker.plist
```

**Common Migration Issues:**

**Issue 1: Configuration Variables Changed**
```bash
# symptoms: scripts use wrong defaults, environment variables not working
# diagnosis: check config.sh for variable name changes
grep -E "ORCHESTRATOR_SLEEP_SECS|SLEEP_SECS" agent_factory/config.sh

# solution: update config.sh with new variable names
# old: SLEEP_SECS="${SLEEP_SECS:-5}"
# new: ORCHESTRATOR_SLEEP_SECS="${ORCHESTRATOR_SLEEP_SECS:-5}"
vim agent_factory/config.sh
```

**Issue 2: Script Interface Changed**
```bash
# symptoms: scripts fail with "unknown option" errors
# diagnosis: check script help
./agent_factory/orchestrator --help

# solution: update command invocations
# check launchd plists for old argument format
cat ~/Library/LaunchAgents/com.YOUR_PROJECT.worker.plist | grep -E "ProgramArguments"
```

**Issue 3: New Required Configuration**
```bash
# symptoms: scripts fail with "variable not set" errors
# diagnosis: check config.sh for new required variables
grep -E ":-.*required|:-.*mandatory" agent_factory/config.sh

# solution: add new required configuration
vim agent_factory/config.sh
# add new variables with appropriate defaults
```

**Issue 4: Launchd Plist Format Changed**
```bash
# symptoms: launchd jobs not starting
# diagnosis: check plist syntax
plutil -lint ~/Library/LaunchAgents/com.YOUR_PROJECT.worker.plist

# solution: regenerate plists using launchd_start.sh
./ops/agent_factory/stop.sh
./agent_factory/launchd_start.sh
./ops/agent_factory/start.sh
```

**Issue 5: Provenance Format Changed**
```bash
# symptoms: provenance_summary.sh fails or shows errors
# diagnosis: check provenance file format
cat tasks/queue/processed/*.provenance.json | jq . | head -20

# solution: old provenance files are backward compatible
# new format adds fields but doesn't remove old ones
# no action needed unless you need new fields
```

**Migration Best Practices:**

1. **Always backup before updating:**
   ```bash
   git add -A
   git commit -m "backup before agent_factory update"
   cp -r agent_factory agent_factory.backup
   ```

2. **Test in non-production first:**
   ```bash
   # test with single task
   ./agent_factory/run_orchestrator \
     --profile Agent_profiles/worker.md \
     --goal-file goal.md \
     --queue-dir tasks/queue \
     --max 1 \
     --once
   ```

3. **Update gradually:**
   - update scripts first
   - test scripts work
   - update configuration
   - test configuration
   - restart jobs

4. **Preserve project-specific settings:**
   ```bash
   # compare old and new configs
   diff agent_factory.backup/config.sh agent_factory/config.sh
   
   # preserve your overrides
   # example: keep your timeout setting
   # old: AGENT_EXECUTION_TIMEOUT_SECS="${AGENT_EXECUTION_TIMEOUT_SECS:-3600}"
   # new default: AGENT_EXECUTION_TIMEOUT_SECS="${AGENT_EXECUTION_TIMEOUT_SECS:-1800}"
   # keep: AGENT_EXECUTION_TIMEOUT_SECS="${AGENT_EXECUTION_TIMEOUT_SECS:-3600}"
   ```

5. **Verify backward compatibility:**
   ```bash
   # old environment variable names should still work
   export SLEEP_SECS=10
   ./agent_factory/orchestrator --profile Agent_profiles/worker.md --queue-dir tasks/queue
   # should work even if new name is ORCHESTRATOR_SLEEP_SECS
   ```

**Rollback Procedure:**

If migration causes issues, rollback is straightforward:

```bash
# stop all jobs
./ops/agent_factory/stop.sh

# restore backup
rm -rf agent_factory
cp -r agent_factory.backup agent_factory

# restart jobs
./ops/agent_factory/start.sh

# verify working
./agent_factory/monitor.sh
```

**Getting Help with Migration:**

If you encounter issues during migration:

1. **Check migration guide in README.md:**
   - see [Migration Guide](README.md#migration-guide) for step-by-step instructions

2. **Review breaking changes:**
   - check git history for agent_factory changes
   - look for CHANGELOG or release notes

3. **Test incrementally:**
   - update one component at a time
   - test after each update
   - identify which change caused the issue

4. **Collect diagnostic information:**
   ```bash
   # compare old vs new
   diff -r agent_factory.backup agent_factory > migration_diff.txt
   
   # check script errors
   bash -n agent_factory/orchestrator 2>&1 | tee migration_errors.txt
   
   # check configuration
   source agent_factory/config.sh
   env | grep -E "ORCHESTRATOR|JUDGE|MAX_" > migration_config.txt
   ```

## Advanced Troubleshooting Scenarios

### Scenario 7: Intermittent Failures

**Symptoms:**
- tasks sometimes succeed, sometimes fail
- no consistent error pattern
- failures seem random

**Diagnosis:**
```bash
# check for rate limit patterns
./agent_factory/log_search.sh "rate limit" | wc -l

# check execution durations
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | select(.status == "failed") | .execution_duration_secs] | sort'

# check for timeout patterns
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | select(.error_code == "timeout")] | length'

# check model usage patterns
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | select(.status == "failed") | .agent_model.final] | group_by(.) | map({model: .[0], count: length})'
```

**Solutions:**
```bash
# increase timeout for long-running tasks
export AGENT_EXECUTION_TIMEOUT_SECS=3600

# configure more reliable fallback model
export FALLBACK_MODEL="gpt-4o-mini"

# reduce concurrency to avoid resource contention
export ORCHESTRATOR_MAX_SPAWNS=1

# increase retry backoff
export ORCHESTRATOR_BACKOFF_SECS=2
```

### Scenario 8: Judge Validation Inconsistencies

**Symptoms:**
- tests pass locally but fail in judge
- judge reports different errors on different runs
- environment differences between local and judge

**Diagnosis:**
```bash
# check judge environment
cat .agent_factory_state/judge_blocker.md

# compare local vs judge python version
python3 --version
# check what judge uses (from blocker ticket)

# check local vs judge dependencies
source .venv/bin/activate
pip list > local_deps.txt
# compare with judge environment (from blocker ticket)
```

**Solutions:**
```bash
# ensure judge uses same python environment
# verify .venv is activated in judge_daemon.sh plist

# ensure dependencies match
./ops/bootstrap_python.sh

# run validation with same commands judge uses
source .venv/bin/activate
pytest
ruff format --check .
ruff check .

# fix any differences, then judge will pass
```

### Scenario 9: Queue Deadlock

**Symptoms:**
- queues not progressing
- planner_queue empty, subplanner_queue full, worker queue empty
- all agents running but no work flowing

**Diagnosis:**
```bash
# check queue status
./agent_factory/queue_status.sh

# check throttling status
./agent_factory/monitor.sh --health

# check if agents are actually processing
ps aux | grep -E "(orchestrator|agent)" | grep -v grep

# check for throttling conditions
source agent_factory/config.sh
echo "MAX_WORKER_PENDING=$MAX_WORKER_PENDING"
echo "MAX_SUBPLANNER_PENDING=$MAX_SUBPLANNER_PENDING"
echo "JUDGE_PAUSE_ON_PENDING=$JUDGE_PAUSE_ON_PENDING"
```

**Solutions:**
```bash
# check if judge is blocking workers
ls -la tasks/judge_queue/

# if judge queue has items, let judge process them
# or adjust JUDGE_PAUSE_ON_PENDING=0 to allow parallel processing

# check throttling thresholds
# if worker queue has many pending, subplanner may be throttled
# adjust MAX_WORKER_PENDING if needed

# manually trigger agents to break deadlock
./agent_factory/run_orchestrator \
  --profile Agent_profiles/sub_planner.md \
  --goal-file goal.md \
  --queue-dir tasks/subplanner_queue \
  --max 5 \
  --once
```

### Scenario 10: High Memory Usage

**Symptoms:**
- system slowing down
- high memory usage
- multiple agent processes consuming resources

**Diagnosis:**
```bash
# check memory usage
ps aux | grep -E "(orchestrator|agent)" | awk '{sum+=$6} END {print "Total RSS: " sum/1024 " MB"}'

# check number of running agents
ps aux | grep orchestrator | wc -l

# check log file sizes
du -sh logs/agent_runs/

# check for memory leaks (long-running processes)
ps -eo pid,etime,rss,cmd | grep orchestrator | sort -k3 -rn
```

**Solutions:**
```bash
# reduce concurrent agents
export ORCHESTRATOR_MAX_SPAWNS=1

# enable log rotation (already enabled by default)
# logs older than 7 days are compressed

# restart agents periodically to clear memory
# add to cron or manual restart weekly
./ops/agent_factory/stop.sh && ./ops/agent_factory/start.sh

# reduce log retention if needed
export LOG_RETENTION_COUNT=50
```

## Getting Help

If you've tried the solutions above and issues persist:

1. **collect diagnostic information:**
   ```bash
   # comprehensive status
   ./agent_factory/monitor.sh > diagnostic_output.txt
   
   # recent errors
   ./agent_factory/log_search.sh --errors --recent 10 >> diagnostic_output.txt
   
   # provenance summary
   ./agent_factory/provenance_summary.sh --detailed >> diagnostic_output.txt
   
   # queue health
   ./agent_factory/monitor.sh --health >> diagnostic_output.txt
   
   # system information
   echo "=== System Info ===" >> diagnostic_output.txt
   uname -a >> diagnostic_output.txt
   python3 --version >> diagnostic_output.txt
   agent --version >> diagnostic_output.txt
   ```

2. **check system requirements:**
   - macOS (for launchd)
   - bash 4.0+
   - python 3.9+
   - agent CLI installed and authenticated

3. **verify setup:**
   - goal.md exists and is valid
   - agent profiles exist and are valid
   - queue directories exist
   - python environment bootstrapped

4. **review logs:**
   - check `logs/agent_runs/` for agent execution logs
   - check system log for launchd errors
   - check blocker tickets for judge validation issues

5. **common quick fixes:**
   ```bash
   # restart everything
   ./ops/agent_factory/stop.sh
   ./ops/agent_factory/start.sh
   
   # verify environment
   ./ops/bootstrap_python.sh
   
   # check for stuck tasks
   ./agent_factory/monitor.sh --health
   
   # clear old processed tasks if needed
   # (be careful: only if you're sure they're not needed)
   ```

6. **document the issue:**
   - note when the issue started
   - document any recent changes (config, agent profiles, goal file)
   - capture error messages and log excerpts
   - note system state (queue counts, agent status)

## Quick Diagnostic Workflow

When something goes wrong, follow this systematic approach:

### Step 1: Check System Status (30 seconds)
```bash
./agent_factory/monitor.sh
```
Look for:
- Queue counts (are tasks processing?)
- Health status (any stuck tasks?)
- Launchd jobs (are agents running?)

### Step 2: Identify the Problem (1 minute)
```bash
# if tasks not processing
./agent_factory/monitor.sh --health

# if errors occurring
./agent_factory/log_search.sh --errors --recent 5

# if judge not committing
cat .agent_factory_state/judge_blocker.md
```

### Step 3: Apply Quick Fix (1 minute)
```bash
# most common fix: restart
./ops/agent_factory/stop.sh && ./ops/agent_factory/start.sh

# environment issues
./ops/bootstrap_python.sh

# configuration issues
source agent_factory/config.sh
echo "Current config: ORCHESTRATOR_SLEEP_SECS=$ORCHESTRATOR_SLEEP_SECS"
```

### Step 4: Verify Fix (30 seconds)
```bash
# watch for a few minutes
./agent_factory/monitor.sh --watch

# or check again after 2 minutes
sleep 120 && ./agent_factory/monitor.sh
```

## Practical Examples

### Example 1: Setting Up a New Project

**Scenario:** Starting a new project with agent_factory

**Step 1: Initial Setup**
```bash
# run setup script (validates prerequisites, creates directories)
./agent_factory/setup.sh

# bootstrap python environment (required for judge validation)
./ops/bootstrap_python.sh

# store API key securely
security add-generic-password -a "$USER" -s "cursor_cli_api_key" -w
# paste API key when prompted
```

**Step 2: Configure Project**
```bash
# create goal file
cp agent_factory/goal_template.md goal.md
# edit goal.md with your project objective

# test with single task
echo "# Task: Test setup
## Objective
Verify agent factory is working correctly.
## File Paths
- Create: \`test_setup.txt\` (content: 'Setup successful')
" > tasks/queue/001_test_setup.md

# run once manually
./agent_factory/run_orchestrator \
  --profile Agent_profiles/worker.md \
  --goal-file goal.md \
  --queue-dir tasks/queue \
  --max 1 \
  --once

# verify success
ls tasks/queue/processed/ | grep test_setup
```

**Step 3: Start Background Jobs**
```bash
# start all agents
./ops/agent_factory/start.sh

# monitor status
./agent_factory/monitor.sh --watch
```

### Example 2: Debugging Failed Tasks

**Scenario:** Task keeps failing and getting requeued

**Step 1: Identify the Problem**
```bash
# check failed tasks
./agent_factory/provenance_summary.sh --failed-only --detailed

# check latest log
./agent_factory/watch_logs.sh --tail 100

# search for specific error
./agent_factory/log_search.sh "empty output"
```

**Step 2: Common Causes and Fixes**

**Empty Output:**
```bash
# check environment
python3 --version
which pytest
which ruff

# verify goal file
cat goal.md | head -20

# fix: bootstrap environment
./ops/bootstrap_python.sh
```

**NEED-INFO Response:**
```bash
# check task file
cat tasks/queue/problematic_task.md

# fix: update task with missing information
vim tasks/queue/problematic_task.md
# add missing context, file paths, or constraints
```

**Rate Limit:**
```bash
# check fallback usage
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | select(.agent_model.used_fallback == true)] | length'

# fix: switch to cheaper model
vim Agent_profiles/worker.md
# change --model gpt-4 to --model gpt-4o-mini
```

**Timeout:**
```bash
# check execution duration
./agent_factory/provenance_summary.sh --detailed | \
  grep -A 5 "problematic_task"

# fix: increase timeout or break task
export AGENT_EXECUTION_TIMEOUT_SECS=3600
# or split large task into smaller ones
```

### Example 3: Optimizing Performance

**Scenario:** Tasks processing slowly, hitting rate limits

**Step 1: Analyze Current Performance**
```bash
# check average execution time
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | .execution_duration_secs] | add / length'

# check model usage
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | .agent_model.final] | group_by(.) | map({model: .[0], count: length})'

# check rate limit frequency
./agent_factory/log_search.sh "rate limit" | wc -l
```

**Step 2: Apply Optimizations**
```bash
# use cheaper, faster model for workers
vim Agent_profiles/worker.md
# change to: --model gpt-4o-mini

# increase sleep intervals to reduce API calls
vim agent_factory/config.sh
# change: ORCHESTRATOR_SLEEP_SECS="${ORCHESTRATOR_SLEEP_SECS:-10}"

# adjust throttling if needed
vim agent_factory/config.sh
# change: MAX_WORKER_PENDING="${MAX_WORKER_PENDING:-10}"
```

**Step 3: Monitor Results**
```bash
# watch processing rates
./agent_factory/monitor.sh --health

# check for improvements
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | select(.execution_duration_secs < 300)] | length'
```

### Example 4: Handling Judge Validation Failures

**Scenario:** Judge not committing, tests failing

**Step 1: Check Blocker Ticket**
```bash
# view blocker ticket
cat .agent_factory_state/judge_blocker.md
```

**Step 2: Fix Environment Issues First (🔧 section)**
```bash
# example: missing pytest
./ops/bootstrap_python.sh

# example: xgboost/openmp issue on macOS
brew install libomp
pip install --force-reinstall xgboost

# verify fix
python -c 'import xgboost; print(xgboost.__version__)'
```

**Step 3: Fix Code Issues (💻 section)**
```bash
# activate environment
source .venv/bin/activate

# fix formatting (easy first)
ruff format .

# fix linting errors
ruff check . --fix

# fix test failures
pytest -v
# fix failing tests based on output

# verify all pass
pytest && ruff format --check . && ruff check .
```

**Step 4: Judge Will Commit Automatically**
```bash
# judge runs automatically when:
# - git has uncommitted changes, and
# - all queues are empty

# monitor judge activity
./agent_factory/monitor.sh --watch
```

## Summary: Best Practices for Troubleshooting

### Systematic Approach

When troubleshooting agent_factory issues, follow this systematic approach:

1. **Check system status first** (30 seconds)
   - `./agent_factory/monitor.sh` - comprehensive status
   - `./agent_factory/monitor.sh --health` - health check
   - `./agent_factory/queue_status.sh` - quick overview

2. **Identify the problem** (1 minute)
   - tasks not processing? → check launchd jobs and queue status
   - errors occurring? → check logs and provenance
   - judge not committing? → check blocker ticket

3. **Apply quick fixes** (1 minute)
   - restart agents (fixes most issues)
   - fix environment issues
   - verify configuration

4. **Verify fix** (30 seconds)
   - monitor for a few minutes
   - check queue processing
   - verify no new errors

### Key Diagnostic Commands

**One-command diagnostics:**
```bash
# full system status
./agent_factory/monitor.sh

# health check
./agent_factory/monitor.sh --health

# recent errors
./agent_factory/log_search.sh --errors --recent 5

# failed tasks
./agent_factory/provenance_summary.sh --failed-only
```

**Common fixes:**
```bash
# restart everything (fixes most issues)
./ops/agent_factory/stop.sh && ./ops/agent_factory/start.sh

# fix environment
./ops/bootstrap_python.sh

# check judge blockers
cat .agent_factory_state/judge_blocker.md
```

### Prevention Strategies

**Before starting a new project:**
- run `./agent_factory/setup.sh` to validate prerequisites
- create and customize `goal.md` from template
- customize agent profiles for your project
- review and adjust `config.sh` for project needs
- bootstrap Python environment
- store API key in macOS Keychain
- test with single task before starting background jobs

**Daily operations:**
- check status: `./agent_factory/monitor.sh`
- review overnight activity: `./agent_factory/provenance_summary.sh --detailed | head -20`
- check for blockers: `cat .agent_factory_state/judge_blocker.md 2>/dev/null || echo "No blockers"`
- monitor queue health: `./agent_factory/monitor.sh --health`

**When creating tasks:**
- keep tasks atomic (≤15 LOC or one shell command)
- use explicit file paths in task descriptions
- include clear acceptance criteria
- number tasks sequentially (001_, 002_, etc.)
- prefix blockers with `00_BLOCKER_` for priority

**When troubleshooting:**
- check system status first: `./agent_factory/monitor.sh`
- review recent errors: `./agent_factory/log_search.sh --errors --recent 5`
- check failed tasks: `./agent_factory/provenance_summary.sh --failed-only --detailed`
- restart if needed: `./ops/agent_factory/stop.sh && ./ops/agent_factory/start.sh`

### Related Documentation

- **[README.md](README.md)** - Complete agent_factory documentation including:
  - Best practices (queue management, agent profiles, goal file structure)
  - Performance tuning (throttling, concurrency, cost optimization)
  - Security considerations (API keys, git credentials, file system security)
  - Operational best practices (daily operations, scaling, cost management)
  - Configuration guide (centralized config in `config.sh`)
  - Migration guide (updating agent_factory in existing projects)
  - Examples of successful configurations

- **[documentation.md](../../documentation.md)** - Project-specific documentation including:
  - Project overview and module map
  - How to run instructions
  - Configuration details
  - Monitoring and queue health
  - Error handling and recovery
  - Log management and rotation
  - Judge validation
  - Provenance tracking
  - Troubleshooting quick reference

## Common Patterns and Anti-Patterns

### ✅ Good Patterns

**Pattern 1: Atomic Tasks**
```markdown
# ✅ GOOD: Single responsibility
# Task: Add calculate_total function to utils.py
# Changes: 1 file, ~10 LOC
```

**Pattern 2: Explicit File Paths**
```markdown
# ✅ GOOD: Clear file paths
## File Paths
- Modify: `src/utils.py` (add function `calculate_total`)
- Create: `tests/test_utils.py` (test `calculate_total`)
```

**Pattern 3: Clear Acceptance Criteria**
```markdown
# ✅ GOOD: Measurable criteria
## Acceptance Criteria
- [ ] Function handles None input (returns 0)
- [ ] Function handles empty list (returns 0)
- [ ] Function calculates sum correctly (test with [1,2,3] → 6)
```

**Pattern 4: Dependency Management**
```markdown
# ✅ GOOD: Clear dependencies
# Task: 002_use_new_api_endpoint.md
# Depends on: 001_implement_api_endpoint.md (must complete first)
# Reference: See 001_implement_api_endpoint.md for API details
```

**Pattern 5: Error Context**
```markdown
# ✅ GOOD: Specific error information
# Task: Fix AttributeError in calculate_total
# File: src/utils.py:45
# Error: AttributeError: 'NoneType' object has no attribute 'value'
# Reproduce: calculate_total(None) raises error
# Expected: calculate_total(None) returns 0
```

**Pattern 6: Progressive Task Breakdown**
```markdown
# ✅ GOOD: Breaking complex work into steps
# Task 1: 001_add_data_model.md (create data structure)
# Task 2: 002_add_validation.md (add input validation)
# Task 3: 003_add_api_endpoint.md (expose via API)
# Task 4: 004_add_tests.md (comprehensive test coverage)
```

**Pattern 7: Context-Rich Task Descriptions**
```markdown
# ✅ GOOD: Includes all necessary context
# Task: Refactor calculate_total to handle edge cases
# Context: Current implementation at src/utils.py:45-60
# Issue: Fails when input is None or empty list
# Reference: See test failures in tests/test_utils.py:23-45
# Expected: Handle None (return 0), handle empty list (return 0)
```

### ❌ Anti-Patterns

**Anti-Pattern 1: Monolithic Tasks**
```markdown
# ❌ BAD: Too large
# Task: Implement entire authentication system
# Changes: 10+ files, 200+ LOC
```

**Anti-Pattern 2: Vague Descriptions**
```markdown
# ❌ BAD: Unclear
# Task: Fix the bug
# (which bug? where? what's the error?)
```

**Anti-Pattern 3: Missing Context**
```markdown
# ❌ BAD: No file paths
# Task: Add user login
# (which files? what should it do?)
```

**Anti-Pattern 4: Hidden Dependencies**
```markdown
# ❌ BAD: Unclear dependencies
# Task: Use new API endpoint
# (but endpoint doesn't exist yet, no mention of dependency)
```

**Anti-Pattern 5: Missing Error Context**
```markdown
# ❌ BAD: No error details
# Task: Fix the error
# (what error? where? how to reproduce?)
```

**Anti-Pattern 6: Ambiguous Acceptance Criteria**
```markdown
# ❌ BAD: Vague criteria
## Acceptance Criteria
- [ ] It should work
- [ ] Add tests
# (what does "work" mean? what tests?)

# ✅ GOOD: Specific criteria
## Acceptance Criteria
- [ ] Function returns 0 for None input
- [ ] Function returns 0 for empty list
- [ ] Function calculates sum correctly (test: [1,2,3] → 6)
- [ ] Test file created at tests/test_utils.py with 3 test cases
```

**Anti-Pattern 7: Missing Constraints**
```markdown
# ❌ BAD: No constraints mentioned
# Task: Add authentication
# (should it use JWT? OAuth? existing library?)

# ✅ GOOD: Clear constraints
## Constraints
- Use existing JWT library (already in requirements.txt)
- Follow existing error handling patterns
- No mocks - use real database connection
- Comments start with lowercase
```

## Troubleshooting Guide Summary

This troubleshooting guide provides comprehensive coverage of all common and advanced issues with agent_factory:

### Quick Reference by Problem Type

**Agent Execution Issues:**
- Empty output → Check environment, verify goal file, review logs
- NEED-INFO responses → Update task with missing information, improve agent profile
- Wrong changes → Revert changes, add explicit file paths to task
- No changes → Verify task clarity, check agent profile restrictions
- Hanging processes → Check timeout configuration, break task into smaller pieces

**Queue Issues:**
- Tasks not processing → Check launchd jobs, verify agents running, restart if needed
- Stuck tasks → Check health status, review errors, verify goal file exists
- Queue imbalances → Check processing rates, verify agents running, adjust throttling

**Judge Validation Failures:**
- Pytest failures → Fix test failures locally, verify tests pass
- Ruff format errors → Auto-format with `ruff format .`
- Ruff check errors → Fix lint errors with `ruff check . --fix`
- Environment issues → Bootstrap Python environment, fix missing dependencies

**Performance Issues:**
- Slow processing → Use faster models, break tasks into smaller pieces, reduce sleep intervals
- High API usage → Use cheaper models, optimize task descriptions, monitor usage

**Configuration Issues:**
- Config not applied → Verify config.sh syntax, restart jobs, check environment variables
- Wrong defaults → Edit config.sh, restart jobs, verify changes

**Launchd Problems:**
- Jobs not starting → Check plist syntax, verify file paths, restart jobs
- Jobs crashing → Verify goal file exists, check agent profiles, test manually
- Jobs not processing → Verify queue directories, check goal file path, restart jobs

### One-Command Solutions

```bash
# Most common fix: restart everything
./ops/agent_factory/stop.sh && ./ops/agent_factory/start.sh

# Fix environment issues
./ops/bootstrap_python.sh

# Check system status
./agent_factory/monitor.sh

# Check for errors
./agent_factory/log_search.sh --errors --recent 5

# Check failed tasks
./agent_factory/provenance_summary.sh --failed-only --detailed

# Check judge blockers
cat .agent_factory_state/judge_blocker.md
```

### Related Documentation

- **[README.md](README.md)** - Complete agent_factory documentation including:
  - Best practices (queue management, agent profiles, goal file structure)
  - Performance tuning (throttling, concurrency, cost optimization)
  - Security considerations (API keys, git credentials, file system security)
  - Operational best practices (daily operations, scaling, cost management)
  - Configuration guide (centralized config in `config.sh`)
  - Migration guide (updating agent_factory in existing projects)
  - Examples of successful configurations

- **[documentation.md](../../documentation.md)** - Project-specific documentation including:
  - Project overview and module map
  - How to run instructions
  - Configuration details
  - Monitoring and queue health
  - Error handling and recovery
  - Log management and rotation
  - Judge validation
  - Provenance tracking
  - Troubleshooting quick reference

### Getting Help

If you've tried the solutions in this guide and issues persist:

1. **Collect diagnostic information:**
   ```bash
   ./agent_factory/monitor.sh > diagnostic_output.txt
   ./agent_factory/log_search.sh --errors --recent 10 >> diagnostic_output.txt
   ./agent_factory/provenance_summary.sh --detailed >> diagnostic_output.txt
   ```

2. **Check system requirements:**
   - macOS (for launchd)
   - bash 4.0+
   - python 3.9+
   - agent CLI installed and authenticated

3. **Verify setup:**
   - goal.md exists and is valid
   - agent profiles exist and are valid
   - queue directories exist
   - python environment bootstrapped

4. **Review logs:**
   - Check `logs/agent_runs/` for agent execution logs
   - Check system log for launchd errors
   - Check blocker tickets for judge validation issues
