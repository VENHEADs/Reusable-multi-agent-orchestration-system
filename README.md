# Agent Factory

Reusable multi-agent orchestration system based on the [Cursor "Scaling Agents" architecture](https://cursor.com/blog/scaling-agents). Supports both single-agent sequential execution and multi-agent concurrent workflows.

## Documentation Quick Links

**Getting Started:**
- [Quick Start](#quick-start) - Setup and basic usage
- [Best Practices - Getting Started](#getting-started-step-by-step) - Step-by-step guide for new projects
- [Quick Reference Cheat Sheet](#quick-reference-cheat-sheet) - Essential commands and patterns

**Core Documentation:**
- [Architecture](#architecture) - System components and design
- [Configuration](#configuration) - Centralized config in `config.sh`
- [Best Practices](#best-practices) - Queue management, agent profiles, goal file structure
- [Performance Tuning](#performance-tuning) - Optimizing speed, reducing costs, throughput
- [Security Considerations](#security-considerations) - API keys, git credentials, file system security
- [Operational Best Practices](#operational-best-practices) - Daily operations, scaling, cost management

**Troubleshooting:**
- [Troubleshooting](#troubleshooting) - Quick reference and common issues
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Comprehensive troubleshooting guide with:
  - Quick reference and decision trees
  - Common errors and solutions
  - Debugging strategies
  - Real-world troubleshooting scenarios
  - Practical examples
  - Advanced troubleshooting scenarios
  - Migration troubleshooting

**Advanced Topics:**
- [Provenance Tracking](#provenance-tracking) - Audit trail for all task executions
- [Migration Guide](#migration-guide) - Updating agent_factory in existing projects
- [Examples of Successful Configurations](#examples-of-successful-configurations) - Real-world setups

## Documentation Completeness

This README provides comprehensive documentation covering all essential aspects of agent_factory:

✅ **Best Practices Guide** - Complete coverage of:
  - Queue management (task granularity, naming, organization)
  - Agent profile design (worker, judge, planner profiles)
  - Goal file structure (objective, success criteria, constraints, status)
  - Task creation workflow (atomic tasks, file paths, acceptance criteria)
  - Real-world patterns and anti-patterns

✅ **Troubleshooting Guide** - Comprehensive coverage in [TROUBLESHOOTING.md](TROUBLESHOOTING.md):
  - Quick reference and decision trees
  - Common errors (agent CLI, authentication, empty output, NEED-INFO, rate limits, timeouts)
  - Queue issues (tasks not processing, stuck tasks, queue imbalances)
  - Agent execution problems (no changes, wrong changes, hanging processes)
  - Judge validation failures (pytest, ruff format, ruff check, environment issues)
  - Performance issues (slow processing, high API usage)
  - Launchd problems (jobs not starting, crashing, not processing)
  - Configuration issues (config not applied, wrong defaults)
  - Real-world troubleshooting scenarios with step-by-step solutions
  - Advanced troubleshooting scenarios (intermittent failures, validation inconsistencies, queue deadlocks)
  - Migration troubleshooting (updating agent_factory in existing projects)

✅ **Performance Tuning Tips** - Complete coverage of:
  - Optimizing task processing speed (model selection, concurrency, task optimization)
  - Reducing API costs (model tier strategy, prompt optimization, rate limit management)
  - Queue throughput optimization (throttling configuration, processing rate monitoring, parallel processing)
  - Performance optimization checklist with measurement commands

✅ **Security Considerations** - Complete coverage of:
  - API key management (macOS Keychain, environment variables, best practices)
  - Git credentials (SSH keys, credential helpers, commit safety)
  - File system security (sensitive data protection, task file security, log security)
  - Network security (API communication, local network)

✅ **Migration Guide** - Complete step-by-step guide for:
  - Updating agent_factory in existing projects
  - Handling breaking changes (configuration, scripts, API)
  - Backward compatibility considerations
  - Rollback procedures
  - Getting help with migration

✅ **Examples of Successful Configurations** - Real-world examples for:
  - Small project (single worker)
  - Medium project (multiple workers)
  - Large project (high throughput)
  - Cost-optimized configuration
  - Development/testing configuration

All documentation is cross-referenced and includes practical examples, code snippets, and actionable guidance.

## Quick Reference Cheat Sheet

### Essential Commands

**System Control:**
```bash
./ops/agent_factory/start.sh           # start all agents
./ops/agent_factory/stop.sh            # stop all agents
./ops/agent_factory/status.sh          # check agent status
./agent_factory/monitor.sh             # full status dashboard
./agent_factory/monitor.sh --watch     # auto-refresh every 2s
```

**Queue Management:**
```bash
./agent_factory/queue_status.sh       # quick queue overview
./agent_factory/monitor.sh --health   # health check (stuck tasks, imbalances)
./agent_factory/requeue_failed.sh     # requeue failed tasks
```

**Logs and Debugging:**
```bash
./agent_factory/watch_logs.sh                    # latest agent run
./agent_factory/log_search.sh --errors --recent 5 # find recent errors
./agent_factory/provenance_summary.sh --failed-only # failed tasks
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

### Best Practices Quick Reference

**Task Creation:**
- ✅ Keep tasks atomic (≤15 LOC or one shell command)
- ✅ Use explicit file paths in task descriptions
- ✅ Include clear acceptance criteria
- ✅ Number tasks sequentially (001_, 002_, etc.)
- ✅ Prefix blockers with `00_BLOCKER_` for priority

**Queue Management:**
- ✅ Break complex features into multiple sequential tasks
- ✅ Each task should be independently reversible via `git revert HEAD`
- ✅ Use separate queue directories for parallel workstreams
- ✅ Prioritize tasks by filename (lexicographic order)

**Agent Profiles:**
- ✅ Explicitly forbid questions: "do not ask questions, do not output NEED-INFO"
- ✅ Require reading task file completely before starting
- ✅ Specify code style and conventions
- ✅ Include examples of good task execution

**Goal File:**
- ✅ Update status section as work progresses
- ✅ Keep objective focused and specific
- ✅ Make success criteria measurable
- ✅ Include all project-specific constraints

**Configuration:**
- ✅ Edit `agent_factory/config.sh` for project-specific defaults
- ✅ Use environment variables for temporary overrides
- ✅ Monitor performance and adjust thresholds as needed

### Performance Optimization Quick Reference

**Speed:**
- Use faster models: `gpt-4o-mini` for workers
- Reduce sleep intervals: `export ORCHESTRATOR_SLEEP_SECS=3`
- Break large tasks into smaller ones
- Use explicit file paths to reduce searches

**Cost:**
- Use cheaper models: `gpt-4o-mini` for workers
- Keep task descriptions concise (fewer tokens)
- Configure fallback models to avoid rate limit delays
- Monitor API usage via provenance

**Throughput:**
- Allow more pending tasks: `export MAX_WORKER_PENDING=10`
- Disable judge pause if judge is fast: `export JUDGE_PAUSE_ON_PENDING=0`
- Use separate workspace clones for true parallelism

### Security Quick Reference

**API Keys:**
- ✅ Use macOS Keychain: `security add-generic-password -a "$USER" -s "cursor_cli_api_key" -w`
- ✅ Never commit API keys to git
- ✅ Use separate keys per project if possible

**Git Credentials:**
- ✅ Use SSH keys for git authentication (recommended)
- ✅ Or use credential helper: `git config credential.helper osxkeychain`
- ✅ Never store passwords in plaintext

**File System:**
- ✅ Never include sensitive data in task files
- ✅ Use environment variables for secrets
- ✅ Ensure `.gitignore` excludes sensitive files
- ✅ Review `JUDGE_INCLUDE_PATHS` to avoid committing secrets

### Troubleshooting Quick Reference

**Tasks not processing:**
```bash
ps aux | grep orchestrator  # check if running
./ops/agent_factory/stop.sh && ./ops/agent_factory/start.sh  # restart
```

**Judge not committing:**
```bash
cat .agent_factory_state/judge_blocker.md  # check blockers
./ops/bootstrap_python.sh  # fix environment
```

**Rate limit errors:**
```bash
# switch to cheaper model
vim Agent_profiles/worker.md  # change to --model gpt-4o-mini
```

**Empty output errors:**
```bash
./ops/bootstrap_python.sh  # fix environment
test -f goal.md || cp agent_factory/goal_template.md goal.md  # verify goal file
```

**Timeout errors:**
```bash
export AGENT_EXECUTION_TIMEOUT_SECS=3600  # increase timeout
# or break task into smaller pieces
```

For detailed troubleshooting, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Quick Start

### 1. Install Cursor Agent CLI

```bash
curl -fsS https://cursor.com/install | bash
agent login
```

### 2. Set Up Your Project

**Recommended: Use the automated setup script** (validates prerequisites and creates everything):

```bash
./agent_factory/setup.sh
```

The setup script will:
- ✓ Detect project name from git remote URL (if available) or directory name
- ✓ Validate prerequisites (git, agent CLI, python3 with version check)
- ✓ Check agent CLI installation and accessibility (checks PATH and common locations)
- ✓ Test agent CLI functionality (verifies it can execute commands, shows version if available)
- ✓ Verify agent CLI can execute simple commands (not just help/version)
- ✓ Check agent CLI authentication (supports both `agent login` and keychain-based auth with clear instructions and API key source)
- ✓ Validate PATH persistence in shell config files (ensures launchd jobs can find agent CLI)
- ✓ Detect existing launchd jobs that might conflict (macOS only)
- ✓ Provide copy-paste ready commands for quick fixes (agent installation, authentication)
- ✓ Validate agent_factory directory structure, template files, and config.sh (checks for key files to detect incomplete installations)
- ✓ Verify agent_factory scripts are executable (auto-fixes if possible)
- ✓ Validate config.sh syntax (ensures it can be sourced without errors)
- ✓ Check write permissions in current directory
- ✓ Detect if current directory is likely a project root (warns if not)
- ✓ Check for Python dependencies file (requirements.txt) and provide guidance
- ✓ Validate Python virtual environment and key dependencies (pytest, ruff) if present
- ✓ Detect setup state (fresh, partial, or fully configured) and provide appropriate feedback
- ✓ Create all required directories with detailed error handling
- ✓ Create state and queue directories (`.agent_factory_state/`, `tasks/queue/processed/`)
- ✓ Copy agent profile templates (idempotent - safe to run multiple times)
- ✓ Create goal.md template (idempotent)
- ✓ Set up ops commands (start/monitor/stop/status) with validation
- ✓ Verify ops scripts are executable, syntactically valid, and functionally correct
- ✓ Test that ops scripts can navigate to repo root correctly
- ✓ **Run final verification** to ensure all components are accessible and working
- ✓ Provide clear, structured next steps with numbered steps, action items, and verification commands
- ✓ Include specific troubleshooting tips organized by issue type with actionable fixes
- ✓ Handle common errors gracefully with actionable fixes and step-by-step guidance
- ✓ Show summary of what was validated and created
- ✓ Provide comprehensive troubleshooting section with ordered checklist
- ✓ Include verification commands to test setup after completion
- ✓ Quick test command to verify setup works correctly
- ✓ Enhanced first-time user guidance (API key setup, project root detection, test task examples)
- ✓ Display detected project name and git remote information

**Manual setup** (if you prefer):

```bash
# In your project root
mkdir -p Agent_profiles tasks/{queue,subplanner_queue,planner_queue,judge_queue} logs
cp agent_factory/Agent_profiles/template_primary_planner.md Agent_profiles/primary_planner.md
cp agent_factory/Agent_profiles/template_sub_planner.md Agent_profiles/sub_planner.md
cp agent_factory/Agent_profiles/template_worker.md Agent_profiles/worker.md
cp agent_factory/Agent_profiles/template_judge.md Agent_profiles/judge.md
cp agent_factory/goal_template.md goal.md
# Edit Agent_profiles/*.md with your project-specific rules
# Edit goal.md with your project objective and success criteria
```

### 2a. Install judge validation dependencies

Judge runs `pytest` and `ruff`. Install them into a repo-local venv:

```bash
./ops/bootstrap_python.sh
```

The launchd jobs generated by `agent_factory/launchd_start.sh` automatically prefer `REPO_ROOT/.venv/bin` on PATH, so the Judge can reliably run checks in the background.

### 3. Run a Single Agent (Sequential)

```bash
# One-off task execution (with goal file)
./agent_factory/run_orchestrator \
  --profile Agent_profiles/worker.md \
  --goal-file goal.md \
  --queue-dir tasks/queue \
  --max 1 \
  --once

# Continuous queue processing (daemon mode)
./agent_factory/run_orchestrator \
  --profile Agent_profiles/worker.md \
  --goal-file goal.md \
  --queue-dir tasks/queue \
  --max 1 \
  --sleep 10
```

### 4. Run Multiple Agents (Concurrent)

For concurrent execution, use separate workspace clones or branches:

```bash
# Terminal 1: Worker on branch A
cd project_clone_a
./agent_factory/run_orchestrator --profile Agent_profiles/worker.md --queue-dir tasks/queue_a --max 1 --sleep 10

# Terminal 2: Worker on branch B
cd project_clone_b
./agent_factory/run_orchestrator --profile Agent_profiles/worker.md --queue-dir tasks/queue_b --max 1 --sleep 10
```

Or use launchd jobs (see "Scheduling" below).

## Architecture

### Components

- **`agent_factory/orchestrator`**: Core script that spawns agents and manages queues
- **`agent_factory/run_orchestrator`**: Wrapper that handles API key from macOS Keychain
- **`Agent_profiles/`**: Markdown files defining agent behavior (created from templates)
- **`agent_factory/Agent_profiles/`**: Template profiles for the 4-agent system
- **`agent_factory/goal_template.md`**: Template for goal file (source of truth)
- **`agent_factory/launchd/`**: macOS launchd job templates for scheduling

### Goal File (Source of Truth)

The goal file is a markdown file that defines the project's objective, success criteria, and constraints. It is **prepended to every agent prompt**, ensuring all agents always see the current goal state. This allows you to:

- **Change goals dynamically**: Update the goal file as requirements evolve
- **Keep agents aligned**: All agents automatically see the latest objective
- **Track progress**: Include current status in the goal file

The goal file is checked on every agent invocation, so changes take effect immediately.

### Agent Roles (4-Agent System)

- **Primary Planner**: Explores codebase, creates planning manifest, delegates to sub-planners
- **Sub-Planner**: Converts domain directives into atomic worker tasks
- **Worker**: Executes single tasks from queue (no coordination, does NOT commit)
- **Judge**: Runs tests/lint, **commits code only after all checks pass** (only agent authorized to commit)

### Queue System

- **`tasks/planner_queue/`**: High-level goals for Primary Planner
- **`tasks/subplanner_queue/`**: Sub-planner directives (from Primary Planner)
- **`tasks/queue/`**: Worker tasks (`.md` files, from Sub-Planner)
- **`tasks/queue/processed/`**: Completed worker tasks (moved atomically)
- **`tasks/judge_queue/`**: Judge triggers (auto-created by `judge_trigger` when pipeline is idle)

### Commit Workflow

- **Workers**: Never commit code. They only modify files in the workspace.
- **Judge**: The only agent authorized to commit. Judge workflow:
  1. Reviews changes from workers
  2. Runs tests (`pytest`, etc.)
  3. Runs linting (`ruff check`, etc.)
  4. **If all pass**: Creates a git commit with descriptive message
  5. **If any fail**: Does NOT commit, creates a fix ticket in `tasks/planner_queue/`

## Usage Examples

### Example 1: Single Worker Processing Tasks

```bash
# Create a task
echo "# Task: Fix bug in utils.py" > tasks/queue/fix_utils_bug.md

# Process it (with goal file)
./agent_factory/run_orchestrator \
  --profile Agent_profiles/worker.md \
  --goal-file goal.md \
  --queue-dir tasks/queue \
  --max 1 \
  --once
```

### Example 1a: Goal File Usage

```bash
# Create/edit goal file
cp agent_factory/goal_template.md goal.md
# Edit goal.md with your objective

# All agents will see the goal file on every invocation
./agent_factory/run_orchestrator \
  --profile Agent_profiles/worker.md \
  --goal-file goal.md \
  --queue-dir tasks/queue \
  --max 1 \
  --once

# Update goal.md anytime - next agent run will see the new goal
# (e.g., change success criteria, add constraints, update status)
```

### Example 2: Continuous Worker Daemon

```bash
# Runs forever, processing one task every 10 seconds (with goal file)
./agent_factory/run_orchestrator \
  --profile Agent_profiles/worker.md \
  --goal-file goal.md \
  --queue-dir tasks/queue \
  --max 1 \
  --sleep 10
```

### Example 3: Multiple Workers (Separate Workspaces)

```bash
# Clone 1: Worker 1
cd /path/to/project_worker1
./agent_factory/run_orchestrator --profile Agent_profiles/worker.md --queue-dir tasks/queue --max 1 --sleep 10 &

# Clone 2: Worker 2
cd /path/to/project_worker2
./agent_factory/run_orchestrator --profile Agent_profiles/worker.md --queue-dir tasks/queue --max 1 --sleep 10 &
```

### Example 4: Planner → Sub-Planner → Worker Pipeline

```bash
# 1. Run planner (creates planning_manifest.json + subplanner tickets)
./agent_factory/run_orchestrator \
  --profile Agent_profiles/planner.md \
  --goal-file goal.md \
  --queue-dir tasks/planner_queue \
  --max 1 \
  --once

# 2. Run sub-planner (creates worker tickets)
./agent_factory/run_orchestrator \
  --profile Agent_profiles/subplanner.md \
  --goal-file goal.md \
  --queue-dir tasks/subplanner_queue \
  --max 10 \
  --once

# 3. Run workers (processes worker tickets)
./agent_factory/run_orchestrator \
  --profile Agent_profiles/worker.md \
  --goal-file goal.md \
  --queue-dir tasks/queue \
  --max 1 \
  --sleep 10
```

## Scheduling (macOS launchd)

### Create a Launchd Job

1. Copy template (advanced/manual):
```bash
cp agent_factory/launchd/template.plist ~/Library/LaunchAgents/com.YOUR_PROJECT.worker.plist
```

2. Edit the plist:
   - Replace `YOUR_PROJECT` with your project identifier
   - Replace `REPO_ROOT` with absolute path to your repo
   - Replace `ROLE` with agent role name
   - Replace `ROLE_PROFILE.md` with your profile filename
   - Replace `QUEUE_DIR` with your queue directory

3. Load the job:
```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.YOUR_PROJECT.worker.plist
launchctl enable gui/$(id -u)/com.YOUR_PROJECT.worker
```

### Recommended: start/stop as a reusable bundle

The agent factory includes launchd helpers that generate and load one job per role (planner/sub-planner/worker/judge) with a consistent label prefix:

- start: `./ops/agent_factory/start.sh`
- monitor: `./ops/agent_factory/monitor.sh`
- status: `./ops/agent_factory/status.sh`
- stop: `./ops/agent_factory/stop.sh`
- stop + remove plists: `./ops/agent_factory/stop_remove.sh`

Additionally, a deterministic (non-ai) launchd job `judge_trigger` runs continuously to enqueue judge runs when:
- git has uncommitted changes, and
- `tasks/planner_queue/`, `tasks/subplanner_queue/`, and `tasks/queue/` are empty.

### Daemon Mode (Continuous)

Use `template_daemon.plist` for workers that should run continuously:

```bash
cp agent_factory/launchd/template_daemon.plist ~/Library/LaunchAgents/com.YOUR_PROJECT.worker.plist
# Edit and load as above
```

### Multiple Concurrent Workers

Create separate plists with different labels:

```bash
# Worker 1
cp agent_factory/launchd/template_daemon.plist ~/Library/LaunchAgents/com.YOUR_PROJECT.worker1.plist
# Edit: Label=com.YOUR_PROJECT.worker1, queue-dir=tasks/queue_1

# Worker 2
cp agent_factory/launchd/template_daemon.plist ~/Library/LaunchAgents/com.YOUR_PROJECT.worker2.plist
# Edit: Label=com.YOUR_PROJECT.worker2, queue-dir=tasks/queue_2
```

## Configuration

### Centralized Configuration

All agent_factory settings are centralized in `agent_factory/config.sh`. This file defines default values for all configuration variables, making it easy to customize behavior per-project.

#### Configuration File

The configuration file (`agent_factory/config.sh`) contains organized sections:

- **Orchestrator settings**: sleep intervals, max spawns, queue throttling thresholds
- **Judge daemon settings**: sleep intervals, blocker paths, auto-push behavior
- **Judge trigger settings**: cooldown periods, trigger thresholds
- **Paths and directories**: state directory, log directory
- **Monitoring settings**: stuck task thresholds, warning thresholds

#### Using Configuration

**Option 1: Edit config.sh directly** (recommended for project-specific defaults)

```bash
# edit agent_factory/config.sh
vim agent_factory/config.sh
# change defaults as needed
# example: change ORCHESTRATOR_SLEEP_SECS="${ORCHESTRATOR_SLEEP_SECS:-5}"
# to:       ORCHESTRATOR_SLEEP_SECS="${ORCHESTRATOR_SLEEP_SECS:-10}"
```

**Option 2: Override via environment variables** (recommended for temporary changes)

```bash
# override specific setting
export ORCHESTRATOR_SLEEP_SECS=10
./agent_factory/orchestrator --profile Agent_profiles/worker.md --queue-dir tasks/queue

# override multiple settings
export ORCHESTRATOR_SLEEP_SECS=3
export MAX_WORKER_PENDING=10
export AGENT_EXECUTION_TIMEOUT_SECS=3600
./agent_factory/orchestrator --profile Agent_profiles/worker.md --queue-dir tasks/queue
```

**Option 3: Create project-specific config** (for multi-project setups)

```bash
# create project config
cp agent_factory/config.sh agent_factory/config.local.sh
# edit config.local.sh
# scripts can source config.local.sh instead
```

#### Configuration Examples

**Faster Processing** (reduce sleep intervals):
```bash
export ORCHESTRATOR_SLEEP_SECS=3
export JUDGE_SLEEP_SECS=10
export JUDGE_TRIGGER_SLEEP_SECS=10
```

**Higher Throughput** (allow more pending tasks):
```bash
export MAX_WORKER_PENDING=10
export MAX_SUBPLANNER_PENDING=5
export JUDGE_PAUSE_ON_PENDING=0
```

**Longer Timeouts** (for complex tasks):
```bash
export AGENT_EXECUTION_TIMEOUT_SECS=3600
export SHUTDOWN_TIMEOUT_SECS=120
```

**Cost Optimization** (longer sleeps, cheaper models):
```bash
export ORCHESTRATOR_SLEEP_SECS=10
export FALLBACK_MODEL="gpt-4o-mini"
```

**Aggressive Judge Triggering** (faster commits):
```bash
export JUDGE_TRIGGER_COOLDOWN_SECS=300
export JUDGE_TRIGGER_PROCESSED_DELTA=3
export JUDGE_TRIGGER_MAX_WORKER_PENDING=1
```

#### Configuration Priority

Configuration values are resolved in this order (highest to lowest priority):
1. **Environment variables** (export VAR=value) - highest priority
2. **config.sh defaults** - project-specific defaults
3. **Script hardcoded defaults** - backward compatibility only

#### Key Configuration Variables

> **Full Reference**: See `agent_factory/config.sh` for the complete list of all configuration variables with detailed comments and examples.

**Orchestrator:**
- `ORCHESTRATOR_SLEEP_SECS`: sleep between queue checks (default: 5)
- `ORCHESTRATOR_MAX_SPAWNS`: max tasks per loop (default: 1)
- `MAX_WORKER_PENDING`: throttle subplanner when worker queue exceeds this (default: 5)
- `MAX_SUBPLANNER_PENDING`: throttle planner when subplanner queue exceeds this (default: 3)
- `JUDGE_PAUSE_ON_PENDING`: pause workers when judge has pending work (default: 1)
- `ORCHESTRATOR_MAX_RETRIES`: max retries for agent execution (default: 3)
- `ORCHESTRATOR_BACKOFF_SECS`: initial backoff delay for retries (default: 1)
- `ORCHESTRATOR_MAX_BACKOFF_SECS`: maximum backoff delay cap (default: 300 seconds)
- `AGENT_EXECUTION_TIMEOUT_SECS`: agent execution timeout in seconds (default: 1800 = 30 minutes)
- `SHUTDOWN_TIMEOUT_SECS`: graceful shutdown timeout in seconds (default: 60)
- `DEFAULT_MODEL`: default model name passed to agents (default: `gpt-5.2`)
- `FALLBACK_MODEL`: fallback model name if rate limit hit (default: `gpt-5.2-codex-low`)

**Judge Daemon:**
- `JUDGE_SLEEP_SECS`: sleep between judge queue checks (default: 15)
- `BLOCKER_TICKET_PATH`: path to blocker ticket file (default: `.agent_factory_state/judge_blocker.md`)
- `JUDGE_AUTO_PUSH`: auto-push commits to remote (default: 1)
- `JUDGE_PUSH_REMOTE`: git remote name for auto-push (default: `origin`)
- `JUDGE_WAIVERS_FILE`: path to judge waivers JSON file (default: `agent_factory/judge_waivers.json`)
- `PYTEST_MAXFAIL`: pytest max failures before stopping (default: 5)
- `JUDGE_INCLUDE_PATHS`: space-separated paths to include in commits

**Judge Trigger:**
- `JUDGE_TRIGGER_SLEEP_SECS`: sleep between trigger checks (default: 15)
- `JUDGE_TRIGGER_MAX_WORKER_PENDING`: max pending worker tasks before triggering (default: 2)
- `JUDGE_TRIGGER_COOLDOWN_SECS`: cooldown period between triggers (default: 600)
- `JUDGE_TRIGGER_PROCESSED_DELTA`: processed tasks delta required to trigger (default: 5)

**Paths and Directories:**
- `AGENT_FACTORY_STATE_DIR`: state directory for agent factory state files (default: `.agent_factory_state`)
- `AGENT_RUNS_LOG_DIR`: log directory for agent runs (default: `logs/agent_runs`)

**Log Rotation:**
- `LOG_RETENTION_COUNT`: number of recent log files to keep uncompressed (default: 100)
- `LOG_COMPRESSION_ENABLED`: enable log compression for old logs (default: 1)
- `LOG_COMPRESSION_AGE_DAYS`: compress logs older than this many days (default: 7)
- `LOG_DELETION_AGE_DAYS`: delete compressed logs older than this many days (default: 90)
- `LOG_ROTATION_CHECK_INTERVAL_SECS`: interval for periodic log rotation checks in queue mode (default: 300 = 5 minutes)

**Monitoring:**
- `MONITOR_STUCK_THRESHOLD`: tasks older than this are considered stuck (default: 3600 seconds)
- `MONITOR_WARNING_THRESHOLD`: tasks older than this trigger warnings (default: 1800 seconds)
- `MONITOR_REFRESH_INTERVAL_SECS`: sleep between refreshes in watch mode (default: 2 seconds)

#### Backward Compatibility

The configuration system maintains backward compatibility with existing environment variable names:
- `SLEEP_SECS` → `ORCHESTRATOR_SLEEP_SECS` or `JUDGE_SLEEP_SECS` (depending on script)
- `COOLDOWN_SECS` → `JUDGE_TRIGGER_COOLDOWN_SECS`
- `PROCESSED_DELTA` → `JUDGE_TRIGGER_PROCESSED_DELTA`
- `STATE_DIR` → `AGENT_FACTORY_STATE_DIR`

Old variable names still work, but new projects should use the centralized config file.

### API Key (macOS Keychain)

Store your Cursor API key in Keychain:

```bash
security add-generic-password -a "$USER" -s "cursor_cli_api_key" -w
# Paste your API key when prompted
```

Or use stored auth (after `agent login`).

### Environment Variables

- `AGENT_BIN`: Path to `agent` CLI (default: `~/.local/bin/agent`)
- `CURSOR_API_KEY`: API key (if not using Keychain)
- `CURSOR_KEYCHAIN_SERVICE`: Keychain service name (default: `cursor_cli_api_key`)
- `DEFAULT_MODEL`: Default model name (default: from `config.sh`)
- `FALLBACK_MODEL`: Fallback model name if rate limit hit (default: from `config.sh`, see Configuration section)

### Rate Limit Handling

The orchestrator automatically detects rate limit errors and retries with a fallback model:

```bash
# Use default fallback (from config.sh)
./agent_factory/run_orchestrator --profile Agent_profiles/worker.md --model gpt-4 --queue-dir tasks/queue

# Specify custom fallback
./agent_factory/run_orchestrator \
  --profile Agent_profiles/worker.md \
  --model gpt-4 \
  --fallback-model gpt-4o-mini \
  --queue-dir tasks/queue

# Via environment variable (overrides config.sh default)
export FALLBACK_MODEL="gpt-4o-mini"
./agent_factory/run_orchestrator --profile Agent_profiles/worker.md --model gpt-4 --queue-dir tasks/queue
```

Rate limit detection checks for:
- "hit your hard limit"
- "rate limit"
- "429" (HTTP status)
- "quota"
- "ActionRequiredError"

If a rate limit is detected, the orchestrator automatically retries with the fallback model and logs both attempts.

## Task Format

### Worker Tasks

Tasks are markdown files in `tasks/queue/`. Example:

```markdown
# Task: Implement feature X

## Objective
Build feature X that does Y.

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2

## File Paths
- Create: `src/feature_x.py`
- Modify: `src/main.py`

## Constraints
- Use typed Python
- No mocks unless asked
```

**Real-World Task Example:**

```markdown
# Task: Add user authentication endpoint

## Objective
Create a POST /api/auth/login endpoint that validates user credentials and returns a JWT token.

## Acceptance Criteria
- [ ] Endpoint accepts email and password
- [ ] Returns 401 for invalid credentials
- [ ] Returns 200 with JWT token for valid credentials
- [ ] Token expires after 24 hours

## File Paths
- Create: `src/api/auth.py` (add `login` function)
- Modify: `src/api/routes.py` (register `/api/auth/login` route)
- Create: `tests/test_auth.py` (test login endpoint)

## Constraints
- Use existing JWT library (already in requirements.txt)
- Follow existing error handling patterns
- No mocks - use real database connection
- Comments start with lowercase
```

### Judge Tasks

The Judge can be triggered via `tasks/judge_queue/` or run on a schedule. When triggered, it:
1. Reviews all uncommitted changes
2. Runs test suite
3. Runs linting
4. Commits if all pass, or creates fix ticket if any fail

Example judge trigger:
```bash
echo "# Judge Run: Review and commit changes" > tasks/judge_queue/judge_$(date +%Y%m%d_%H%M%S).md
```

## Monitoring

### Full Status Dashboard

```bash
# Complete status overview (one command)
./agent_factory/monitor.sh

# Auto-refresh every 2 seconds
./agent_factory/monitor.sh --watch

# Show only specific sections
./agent_factory/monitor.sh --queues    # queue status only
./agent_factory/monitor.sh --logs      # latest agent runs only
./agent_factory/monitor.sh --git       # git status only
./agent_factory/monitor.sh --launchd   # launchd jobs only
```

### Quick Queue Status

```bash
# Quick queue overview
./agent_factory/queue_status.sh
```

### Restart After Failures

```bash
# Requeue failed tasks and show status
./agent_factory/restart.sh

# Requeue from all queues
./agent_factory/restart.sh --all-queues

# Dry-run to see what would be requeued
./agent_factory/restart.sh --dry-run

# Requeue failed tasks from specific queue
./agent_factory/requeue_failed.sh --queue-dir tasks/queue
```

### Watch Latest Agent Run

```bash
# Show last 80 lines of latest agent run
./agent_factory/watch_logs.sh

# Follow latest agent run in real-time
./agent_factory/watch_logs.sh --follow

# Show last N lines
./agent_factory/watch_logs.sh --tail 200
```

### Manual Monitoring Commands

```bash
# Count pending/processed
echo "pending: $(find tasks/queue -maxdepth 1 -type f -name '*.md' | wc -l)"
echo "processed: $(find tasks/queue/processed -maxdepth 1 -type f | wc -l)"

# Launchd Status
launchctl list | grep com.YOUR_PROJECT
launchctl print gui/$(id -u)/com.YOUR_PROJECT.worker | grep 'state =|last exit code'
```

## Provenance Tracking

The orchestrator automatically generates provenance metadata for every task execution. This provides a complete audit trail for debugging and understanding agent behavior.

**Quick Reference:**
- **Location**: `tasks/*/processed/*.provenance.json` (alongside processed task files)
- **Query Tool**: `./agent_factory/provenance_summary.sh` (see [Querying Provenance](#querying-provenance) below)
- **Format**: JSON with standardized fields (backward compatible)
- **Coverage**: All task executions (success and failure) are tracked with full audit trail
- **Implementation**: Provenance generation is implemented in `agent_factory/orchestrator` (provenance setup starts at line 1379, JSON generation at lines 1816-1902), automatically creating provenance files for every task execution

**Complete Audit Trail Features (All Acceptance Criteria Met):**
- ✅ **Agent model tracking**: Records primary model, final model used, and whether fallback was used (see `agent_model` field in provenance JSON)
- ✅ **Execution duration**: Tracks execution time in seconds and human-readable format (see `execution_duration_secs` and `execution_duration` fields)
- ✅ **Git commit hash**: Captures git commit hash at execution start if available (see `git_commit_hash` field)
- ✅ **Failed task provenance**: All failed tasks have provenance files preserved with error codes and messages (see `error_code` and `error_message` fields)
- ✅ **Requeue attempt linking**: Tracks requeue attempts and links to previous attempt provenance files (see `requeue_attempt` and `previous_attempt_provenance_file` fields)
- ✅ **Easy querying**: `provenance_summary.sh` script provides comprehensive querying and analysis capabilities (see [Querying Provenance](#querying-provenance) section)

### Provenance Files

Provenance files are created alongside processed task files in `tasks/*/processed/*.provenance.json`. Each file contains:

- **Task metadata**: ticket name, queue directory, claimed file path
- **Timing**: start/end timestamps (UTC), execution duration (seconds and human-readable)
- **Agent model**: primary model, final model used, whether fallback was used
- **Git state**: commit hash (if available), dirty files before/after execution, newly modified files
- **Execution status**: success/failed, error codes and messages for failures
- **Requeue tracking**: attempt number and link to previous attempt provenance file (for failed tasks that were requeued)

### Provenance Format

Provenance files are JSON with the following structure. All fields are present in every provenance file unless otherwise noted.

**Core Fields:**
- `ticket_name` (string): Name of the task ticket file (e.g., "example_task.md")
- `queue_dir` (string): Queue directory where the task was processed (e.g., "tasks/queue")
- `claimed_file` (string): Full path to the processed task file in the processed directory
- `status` (string): Execution status - either "success" or "failed"

**Timing Fields:**
- `start_ts_utc` (string): ISO 8601 timestamp (UTC) when task execution started
- `end_ts_utc` (string): ISO 8601 timestamp (UTC) when task execution completed
- `execution_duration_secs` (integer): Execution duration in seconds
- `execution_duration` (string): Human-readable duration (e.g., "5m 30s", "1h 23m 45s")

**Agent Model Fields:**
- `agent_model` (object): Information about the agent model used
  - `primary` (string): Primary model configured for the task (may be empty if not specified)
  - `final` (string): Final model actually used (may differ from primary if fallback was used)
  - `used_fallback` (boolean): Whether a fallback model was used due to rate limits or errors

**Git State Fields:**
- `git_commit_hash` (string): Git commit hash at execution start (empty string if git not available)
- `git_dirty_before` (array of strings): List of dirty files before execution
- `git_dirty_after` (array of strings): List of dirty files after execution
- `newly_dirty_files` (array of strings): Files that became dirty during execution (after - before)
- `cleared_files` (array of strings): Files that were dirty before but clean after execution

**Requeue Tracking:**
- `requeue_attempt` (integer): Number of requeue attempts (0 for first attempt, increments with each requeue)
- `previous_attempt_provenance_file` (string, optional): Path to the provenance file from the previous attempt (only present when `requeue_attempt` > 0). This allows tracing the full execution history of a task across multiple requeue attempts.

**Error Fields (only present when `status` is "failed"):**
- `error_code` (string): Error category code (see error codes below)
- `error_message` (string): Human-readable error description

**Example - Successful Task:**
```json
{
  "ticket_name": "example_task.md",
  "queue_dir": "tasks/queue",
  "claimed_file": "tasks/queue/processed/example_task.md.1234567890.12345",
  "start_ts_utc": "2026-01-19T12:00:00Z",
  "end_ts_utc": "2026-01-19T12:05:30Z",
  "execution_duration_secs": 330,
  "execution_duration": "5m 30s",
  "agent_model": {
    "primary": "gpt-4",
    "final": "gpt-4",
    "used_fallback": false
  },
  "git_commit_hash": "abc123def456...",
  "requeue_attempt": 0,
  "status": "success",
  "git_dirty_before": [],
  "git_dirty_after": ["src/file.py"],
  "newly_dirty_files": ["src/file.py"],
  "cleared_files": []
}
```

**Example - Failed Task (First Attempt):**
```json
{
  "ticket_name": "example_task.md",
  "queue_dir": "tasks/queue",
  "claimed_file": "tasks/queue/processed/example_task.md.1234567890.12345",
  "start_ts_utc": "2026-01-19T12:00:00Z",
  "end_ts_utc": "2026-01-19T12:00:15Z",
  "execution_duration_secs": 15,
  "execution_duration": "15s",
  "agent_model": {
    "primary": "gpt-4",
    "final": "gpt-4o-mini",
    "used_fallback": true
  },
  "git_commit_hash": "abc123def456...",
  "requeue_attempt": 0,
  "status": "failed",
  "error_code": "empty_output",
  "error_message": "empty agent output detected",
  "git_dirty_before": [],
  "git_dirty_after": [],
  "newly_dirty_files": [],
  "cleared_files": []
}
```

**Example - Failed Task (Requeued Attempt):**
```json
{
  "ticket_name": "example_task.md",
  "queue_dir": "tasks/queue",
  "claimed_file": "tasks/queue/processed/example_task.md.1234567891.12346",
  "start_ts_utc": "2026-01-19T12:05:00Z",
  "end_ts_utc": "2026-01-19T12:05:20Z",
  "execution_duration_secs": 20,
  "execution_duration": "20s",
  "agent_model": {
    "primary": "gpt-4",
    "final": "gpt-4",
    "used_fallback": false
  },
  "git_commit_hash": "abc123def456...",
  "requeue_attempt": 1,
  "previous_attempt_provenance_file": "tasks/queue/processed/example_task.md.1234567890.12345.provenance.json",
  "status": "failed",
  "error_code": "timeout",
  "error_message": "agent execution exceeded timeout (1800s)",
  "git_dirty_before": [],
  "git_dirty_after": [],
  "newly_dirty_files": [],
  "cleared_files": []
}
```

**Error Codes:**
- `empty_output`: Agent execution produced no output or minimal output
- `need_info`: Agent requested additional information (NEED-INFO response)
- `timeout`: Agent execution exceeded the configured timeout
- `execution_failure`: Agent execution failed with a non-retryable error

**Backward Compatibility:**
The provenance format is designed to be backward compatible. New fields may be added in the future, but existing fields will not be removed or changed in incompatible ways. When querying provenance files programmatically, always check for field existence before accessing (e.g., `task.get('error_code', '')`).

**Provenance File Location:**
Provenance files are automatically created alongside processed task files in the `processed/` subdirectory of each queue. The filename format is: `<ticket_name>.<timestamp>.<pid>.provenance.json`. This ensures each execution attempt has a unique provenance file, even for requeued tasks.

**Provenance Format Version:**
The current provenance format includes all required fields for complete audit trail:
- Agent model tracking (primary, final, fallback usage)
- Execution timing (start, end, duration in seconds and human-readable)
- Git state (commit hash, dirty files tracking)
- Error tracking (error codes and messages for failures)
- Requeue attempt linking (chain of execution attempts)

All fields are present in every provenance file unless otherwise noted (e.g., error fields only present for failed tasks, `previous_attempt_provenance_file` only present for requeued tasks).

**Key Features:**
- ✅ Agent model tracking (primary vs fallback) - see `agent_model` field
- ✅ Execution duration (seconds and human-readable) - see `execution_duration_secs` and `execution_duration` fields
- ✅ Git commit hash (if available) - see `git_commit_hash` field
- ✅ Failed task provenance preserved - all tasks (success and failure) have provenance files
- ✅ Requeue attempt linking - see `previous_attempt_provenance_file` field for execution history
- ✅ Easy querying - use `provenance_summary.sh` script (see below)

### Querying Provenance

Use `provenance_summary.sh` to query and analyze provenance data:

```bash
# show summary statistics
./agent_factory/provenance_summary.sh

# show detailed information for all tasks
./agent_factory/provenance_summary.sh --detailed

# show only failed tasks
./agent_factory/provenance_summary.sh --failed-only --detailed

# show only requeued tasks
./agent_factory/provenance_summary.sh --requeued-only --detailed

# filter by queue
./agent_factory/provenance_summary.sh --queue-dir tasks/queue --detailed

# filter by model
./agent_factory/provenance_summary.sh --model gpt-4 --detailed

# filter by ticket name
./agent_factory/provenance_summary.sh --ticket example_task --detailed

# output as JSON
./agent_factory/provenance_summary.sh --json
```

### Requeue Tracking

When a task fails and is requeued, the provenance system tracks requeue attempts:

- First attempt: `requeue_attempt: 0` (no `previous_attempt_provenance_file`)
- After first requeue: `requeue_attempt: 1` (includes `previous_attempt_provenance_file` pointing to attempt 0)
- After second requeue: `requeue_attempt: 2` (includes `previous_attempt_provenance_file` pointing to attempt 1)
- etc.

Each requeue creates a new provenance file, allowing you to trace the full history of a task's execution attempts. The `previous_attempt_provenance_file` field creates a linked list of provenance files, making it easy to follow a task's execution history from the most recent attempt back to the first attempt.

**Example: Tracing execution history**

```bash
# show detailed information for a specific ticket
./agent_factory/provenance_summary.sh --ticket example_task --detailed

# output shows all attempts grouped by ticket:
# Ticket: example_task.md
#   Total attempts: 3
#   └─ Attempt #1:
#       Status: failed
#       Error: timeout - agent execution exceeded timeout
#       Previous attempt: (none)
#   └─ Attempt #2:
#       Status: failed
#       Error: empty_output - empty agent output detected
#       Previous attempt: tasks/queue/processed/example_task.md.1234567890.12345.provenance.json
#   └─ Attempt #3:
#       Status: success
#       Previous attempt: tasks/queue/processed/example_task.md.1234567891.12346.provenance.json
```

You can manually trace the history by following the `previous_attempt_provenance_file` links, or use the summary script which automatically groups attempts by ticket name.

### Use Cases

- **Debugging**: Identify which tasks failed and why
- **Performance analysis**: Track execution durations and identify slow tasks
- **Model usage**: Understand which models are being used and when fallbacks occur
- **Audit trail**: Track all changes made by agents with git commit hashes
- **Failure analysis**: Identify patterns in task failures and requeues

### Practical Examples

**Example 1: Find all failed tasks with fallback model usage**
```bash
./agent_factory/provenance_summary.sh --failed-only --detailed | grep -A 5 "fallback"
```

**Example 2: Track execution history of a specific task**
```bash
# show all attempts for a task
./agent_factory/provenance_summary.sh --ticket example_task --detailed

# manually trace the chain
cat tasks/queue/processed/example_task.md.*.provenance.json | jq '.previous_attempt_provenance_file'
```

**Example 3: Analyze performance patterns**
```bash
# find slow tasks (>10 minutes)
./agent_factory/provenance_summary.sh --json | \
  jq '.[] | select(.execution_duration_secs > 600) | {ticket: .ticket_name, duration: .execution_duration}'

# calculate average execution time by queue
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | {queue: .queue_dir, duration: .execution_duration_secs}] | 
      group_by(.queue) | 
      map({queue: .[0].queue, avg_duration: ([.[] | .duration] | add / length)})'
```

**Example 4: Monitor model usage and fallback frequency**
```bash
# count fallback usage
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | select(.agent_model.used_fallback == true)] | length'

# model distribution
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | .agent_model.final] | group_by(.) | map({model: .[0], count: length})'
```

**Example 5: Audit trail for code changes**
```bash
# find tasks that modified specific files
./agent_factory/provenance_summary.sh --json | \
  jq '.[] | select(.newly_dirty_files[] | contains("src/utils.py")) | 
      {ticket: .ticket_name, files: .newly_dirty_files, commit: .git_commit_hash}'
```

## Best Practices

This section covers essential best practices for using agent_factory effectively. For quick reference, see the [Quick Reference Cheat Sheet](#quick-reference-cheat-sheet) above.

### Best Practices Checklist

**Before Starting a New Project:**
- [ ] Run `./agent_factory/setup.sh` to validate prerequisites
- [ ] Create and customize `goal.md` from `agent_factory/goal_template.md`
- [ ] Customize agent profiles in `Agent_profiles/` for your project
- [ ] Review and adjust `agent_factory/config.sh` for project needs
- [ ] Bootstrap Python environment: `./ops/bootstrap_python.sh`
- [ ] Store API key in macOS Keychain for background jobs
- [ ] Test with a single task before starting background jobs

**Daily Operations:**
- [ ] Check status: `./agent_factory/monitor.sh`
- [ ] Review overnight activity: `./agent_factory/provenance_summary.sh --detailed | head -20`
- [ ] Check for blockers: `cat .agent_factory_state/judge_blocker.md 2>/dev/null || echo "No blockers"`
- [ ] Monitor queue health: `./agent_factory/monitor.sh --health`

**When Creating Tasks:**
- [ ] Keep tasks atomic (≤15 LOC or one shell command)
- [ ] Use explicit file paths in task descriptions
- [ ] Include clear acceptance criteria
- [ ] Number tasks sequentially (001_, 002_, etc.)
- [ ] Prefix blockers with `00_BLOCKER_` for priority

**When Troubleshooting:**
- [ ] Check system status first: `./agent_factory/monitor.sh`
- [ ] Review recent errors: `./agent_factory/log_search.sh --errors --recent 5`
- [ ] Check failed tasks: `./agent_factory/provenance_summary.sh --failed-only --detailed`
- [ ] Restart if needed: `./ops/agent_factory/stop.sh && ./ops/agent_factory/start.sh`

### Best Practices Summary

**Task Creation:**
- ✅ Keep tasks atomic (≤15 LOC or one shell command)
- ✅ Use explicit file paths in task descriptions
- ✅ Include clear acceptance criteria
- ✅ Number tasks sequentially (001_, 002_, etc.)
- ✅ Prefix blockers with `00_BLOCKER_` for priority

**Queue Management:**
- ✅ Break complex features into multiple sequential tasks
- ✅ Each task should be independently reversible via `git revert HEAD`
- ✅ Use separate queue directories for parallel workstreams
- ✅ Prioritize tasks by filename (lexicographic order)

**Agent Profiles:**
- ✅ Explicitly forbid questions: "do not ask questions, do not output NEED-INFO"
- ✅ Require reading task file completely before starting
- ✅ Specify code style and conventions
- ✅ Include examples of good task execution

**Goal File:**
- ✅ Update status section as work progresses
- ✅ Keep objective focused and specific
- ✅ Make success criteria measurable
- ✅ Include all project-specific constraints

**Configuration:**
- ✅ Edit `agent_factory/config.sh` for project-specific defaults
- ✅ Use environment variables for temporary overrides
- ✅ Monitor performance and adjust thresholds as needed

**Security:**
- ✅ Use macOS Keychain for API keys (not environment variables)
- ✅ Use SSH keys for git authentication
- ✅ Never commit sensitive data in task files
- ✅ Review `JUDGE_INCLUDE_PATHS` to avoid committing secrets

**Performance:**
- ✅ Use cheaper models (`gpt-4o-mini`) for workers
- ✅ Keep task descriptions concise (fewer tokens)
- ✅ Configure fallback models to avoid rate limit delays
- ✅ Monitor API usage via provenance

For detailed best practices, see the sections below.

### Quick Reference Checklist

**Before Starting a New Project:**
- [ ] Run `./agent_factory/setup.sh` to validate prerequisites
- [ ] Create and customize `goal.md` from `agent_factory/goal_template.md`
- [ ] Customize agent profiles in `Agent_profiles/` for your project
- [ ] Review and adjust `agent_factory/config.sh` for project needs
- [ ] Bootstrap Python environment: `./ops/bootstrap_python.sh`
- [ ] Store API key in macOS Keychain for background jobs
- [ ] Test with a single task before starting background jobs

**Getting Started: Step-by-Step**

1. **Initial Setup:**
   ```bash
   # validate prerequisites and create directories
   ./agent_factory/setup.sh
   
   # bootstrap python environment (required for judge)
   ./ops/bootstrap_python.sh
   
   # store API key securely (required for background jobs)
   security add-generic-password -a "$USER" -s "cursor_cli_api_key" -w
   ```

2. **Configure Project:**
   ```bash
   # create goal file (source of truth for all agents)
   cp agent_factory/goal_template.md goal.md
   vim goal.md  # edit with your project objective
   
   # customize agent profiles (optional, templates work well)
   vim Agent_profiles/worker.md  # adjust if needed
   
   # adjust configuration (optional, defaults work well)
   vim agent_factory/config.sh  # adjust timeouts/thresholds if needed
   ```

3. **Test with Single Task:**
   ```bash
   # create a test task
   echo "# Task: Test agent factory
   ## Objective
   Create a simple test file to verify agent factory works.
   ## File Paths
   - Create: \`test_agent_factory.txt\` (content: 'Agent factory works!')
   " > tasks/queue/001_test_agent_factory.md
   
   # run once manually to test
   ./agent_factory/run_orchestrator \
     --profile Agent_profiles/worker.md \
     --goal-file goal.md \
     --queue-dir tasks/queue \
     --max 1 \
     --once
   
   # verify task completed
   ls tasks/queue/processed/ | grep test_agent_factory
   ```

4. **Start Background Jobs:**
   ```bash
   # start all agents (planner, sub-planner, worker, judge, judge_trigger)
   ./ops/agent_factory/start.sh
   
   # monitor status
   ./agent_factory/monitor.sh
   
   # watch in real-time
   ./agent_factory/monitor.sh --watch
   ```

5. **Daily Operations:**
   ```bash
   # morning: check overnight activity
   ./agent_factory/monitor.sh
   ./agent_factory/provenance_summary.sh --detailed | head -20
   
   # check for blockers
   cat .agent_factory_state/judge_blocker.md 2>/dev/null || echo "No blockers"
   
   # create new tasks
   echo "# Task: Your task description" > tasks/queue/002_your_task.md
   
   # monitor progress
   ./agent_factory/monitor.sh --watch
   ```

**Daily Operations:**
- [ ] Check status: `./agent_factory/monitor.sh`
- [ ] Review overnight activity: `./agent_factory/provenance_summary.sh --detailed | head -20`
- [ ] Check for blockers: `cat .agent_factory_state/judge_blocker.md 2>/dev/null || echo "No blockers"`
- [ ] Monitor queue health: `./agent_factory/monitor.sh --health`

**When Creating Tasks:**
- [ ] Keep tasks atomic (≤15 LOC or one shell command)
- [ ] Use explicit file paths in task descriptions
- [ ] Include clear acceptance criteria
- [ ] Number tasks sequentially (001_, 002_, etc.)
- [ ] Prefix blockers with `00_BLOCKER_` for priority

**When Troubleshooting:**
- [ ] Check system status first: `./agent_factory/monitor.sh`
- [ ] Review recent errors: `./agent_factory/log_search.sh --errors --recent 5`
- [ ] Check failed tasks: `./agent_factory/provenance_summary.sh --failed-only --detailed`
- [ ] Restart if needed: `./ops/agent_factory/stop.sh && ./ops/agent_factory/start.sh`

### Queue Management

**Task Granularity:**
- keep tasks atomic: ≤15 LOC changes or one shell command per task
- break complex features into multiple sequential tasks
- each task should be independently reversible via `git revert HEAD`

**Example: Breaking Down a Large Task**

```markdown
# ❌ BAD: Too large (50+ LOC changes)
# Task: Implement authentication system

# ✅ GOOD: Atomic tasks
# Task 1: 001_add_user_model.md
# Task 2: 002_add_password_hashing.md
# Task 3: 003_add_login_endpoint.md
# Task 4: 004_add_tests.md
```

**Task Naming:**
- use descriptive filenames: `001_implement_feature_x.md`, `002_add_tests.md`
- prefix blocker tickets with `00_BLOCKER_` to prioritize them
- use consistent numbering for sequential tasks

**Example Task Naming:**
```bash
# sequential tasks
001_implement_feature_x.md
002_add_tests.md
003_add_documentation.md

# blocker tickets (processed first)
00_BLOCKER_missing_api_key.md
00_BLOCKER_database_not_configured.md

# related tasks (same prefix)
100_feature_a_setup.md
101_feature_a_implementation.md
102_feature_a_tests.md
```

**Queue Organization:**
- use separate queue directories for different workstreams: `tasks/queue_feature_a/`, `tasks/queue_feature_b/`
- prioritize tasks by filename (lexicographic order)
- move completed tasks to `processed/` automatically (orchestrator handles this)

**Example: Parallel Workstreams**
```bash
# separate queues for parallel work
tasks/queue_feature_a/    # worker 1 processes this
tasks/queue_feature_b/    # worker 2 processes this
tasks/queue_bugfixes/     # worker 3 processes this

# each workstream can have its own worker
```

**Example Task Structure:**
```markdown
# Task: Implement feature X

## Objective
Build feature X that does Y.

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2

## File Paths
- Create: `src/feature_x.py`
- Modify: `src/main.py`

## Constraints
- Use typed Python
- No mocks unless asked
- Follow existing code style
```

### Agent Profile Design

**Worker Profile Best Practices:**
- explicitly forbid questions: "do not ask questions, do not output NEED-INFO"
- require reading task file completely before starting
- specify code style and conventions
- include examples of good task execution

**Judge Profile Best Practices:**
- clearly define validation commands (pytest, ruff, etc.)
- specify commit message format
- define what constitutes a blocker vs. warning
- include waiver handling instructions

**Planner Profile Best Practices:**
- require creating planning manifest before delegating
- specify task granularity requirements
- require checking existing code before creating tasks
- include examples of good task breakdowns

**Example Worker Profile Structure:**
```markdown
# Role: Worker Agent

## Objective
Execute exactly one task ticket from the queue.

## Critical Behavior
- tunnel vision: focus only on the assigned ticket
- do not commit; only the judge commits
- do not ask questions; if blocked, create blocker ticket
- read task file completely before starting

## Project Constraints
- comments start with lowercase
- only write crucial comments; prefer self-documented code
- do not use mocks unless explicitly asked
- do not change existing test logic just to fit new code
```

### Goal File Structure

**Essential Sections:**
1. **Current Objective**: clear, actionable project goal
2. **Success Criteria**: measurable checkboxes
3. **Constraints**: project-specific rules and limitations
4. **Current Status**: phase/milestone tracking

**Best Practices:**
- update status section as work progresses
- keep objective focused and specific
- make success criteria measurable
- include all project-specific constraints

**Example Goal File:**
```markdown
# Project Goal

## Current Objective
Build pricing algorithms, estimate impact, and design A/B tests.

## Success Criteria
- [ ] agent factory runs continuously via launchd
- [ ] a single command starts everything
- [ ] a single command shows progress
- [ ] a single command stops everything

## Constraints
- do not commit from workers (judge only)
- comments start with lowercase
- only write crucial comments; prefer self-documented code

## Current Status
- phase: bootstrap agent factory scaffolding
```

### Task Creation Workflow

**Before Creating Tasks:**
1. search codebase to understand existing patterns
2. check if similar functionality already exists
3. review related tasks in queue to avoid duplication

**Task Creation:**
1. write clear, specific objective
2. list all acceptance criteria
3. specify exact file paths (create/modify)
4. include relevant constraints
5. reference related tasks if dependencies exist

**After Task Completion:**
1. verify task moved to `processed/`
2. check provenance for execution details
3. review changes via git diff
4. update goal file status if milestone reached

### Real-World Best Practices

**Avoiding Common Pitfalls:**

1. **Task Dependencies:**
   ```markdown
   # ❌ BAD: Task depends on uncompleted work
   # Task: Use new API endpoint
   # (but endpoint doesn't exist yet)
   
   # ✅ GOOD: Create blocker ticket first
   # Task: 00_BLOCKER_implement_api_endpoint.md
   # Then: Task: use_new_api_endpoint.md
   ```

2. **File Path Specificity:**
   ```markdown
   # ❌ BAD: Vague file paths
   ## File Paths
   - Modify: some files
   
   # ✅ GOOD: Explicit file paths
   ## File Paths
   - Modify: `src/utils.py` (add function `calculate_total`)
   - Create: `tests/test_utils.py` (test `calculate_total`)
   ```

3. **Task Size:**
   ```markdown
   # ❌ BAD: Too large (50+ LOC changes)
   # Task: Implement entire authentication system
   
   # ✅ GOOD: Atomic tasks
   # Task 1: Add user model
   # Task 2: Add password hashing
   # Task 3: Add login endpoint
   # Task 4: Add tests
   ```

4. **Error Handling:**
   ```markdown
   # ✅ GOOD: Include error handling in task
   ## Acceptance Criteria
   - [ ] Function handles None input gracefully
   - [ ] Raises ValueError for invalid input
   - [ ] Logs errors appropriately
   ```

5. **Task Clarity:**
   ```markdown
   # ❌ BAD: Ambiguous task
   # Task: Fix the bug
   
   # ✅ GOOD: Specific task
   # Task: Fix null pointer exception in calculate_total when input is None
   # File: src/utils.py:45
   # Error: AttributeError: 'NoneType' object has no attribute 'value'
   ```

**Queue Management Patterns:**

1. **Priority Ordering:**
   - Use numeric prefixes: `001_`, `002_`, etc.
   - Blockers always start with `00_BLOCKER_`
   - Related tasks use same prefix: `100_feature_a_`, `101_feature_a_`, etc.

2. **Workstream Separation:**
   ```bash
   # separate queues for parallel workstreams
   tasks/queue_feature_a/
   tasks/queue_feature_b/
   tasks/queue_bugfixes/
   
   # each workstream can have its own worker
   ```

3. **Task Validation:**
   - always verify task file syntax before queuing
   - check that referenced files exist
   - ensure dependencies are clear

**Agent Profile Optimization:**

1. **Worker Profile:**
   ```markdown
   # ✅ GOOD: Explicit constraints prevent questions
   ## Critical Behavior
   - do not ask questions; if blocked, create blocker ticket
   - do not commit; only the judge commits
   - read task file completely before starting
   - if task is unclear, create blocker ticket with specific questions
   ```

2. **Judge Profile:**
   ```markdown
   # ✅ GOOD: Clear validation rules
   ## Validation Steps
   1. run pytest (max failures: 5)
   2. run ruff format --check
   3. run ruff check
   4. if all pass: commit with descriptive message
   5. if any fail: create blocker ticket
   ```

3. **Planner Profile:**
   ```markdown
   # ✅ GOOD: Task granularity requirements
   ## Task Creation Rules
   - each task must be ≤15 LOC or one shell command
   - tasks must be independently reversible
   - check existing code before creating tasks
   - reference related tasks in task descriptions
   ```

**Goal File Management:**

1. **Status Updates:**
   ```markdown
   # update status as work progresses
   ## Current Status
   - phase: implementation
   - completed: 45/100 tasks
   - blockers: 2 (waiting on external API)
   - next milestone: feature complete (estimated: 2 days)
   ```

2. **Dynamic Goal Updates:**
   - update goal file when requirements change
   - all agents see updated goal on next run
   - use status section to track progress
   - mark success criteria as completed when met

**Provenance Analysis:**

1. **Performance Monitoring:**
   ```bash
   # find slow tasks
   ./agent_factory/provenance_summary.sh --json | \
     jq '.[] | select(.execution_duration_secs > 600)'
   
   # find frequently requeued tasks
   ./agent_factory/provenance_summary.sh --json | \
     jq '.[] | select(.requeue_attempt > 2)'
   ```

2. **Model Usage Tracking:**
   ```bash
   # track fallback model usage
   ./agent_factory/provenance_summary.sh --json | \
     jq '[.[] | select(.agent_model.used_fallback == true)] | length'
   ```

3. **Failure Analysis:**
   ```bash
   # analyze failure patterns
   ./agent_factory/provenance_summary.sh --failed-only --json | \
     jq '[.[] | .error_code] | group_by(.) | map({code: .[0], count: length})'
   ```

## Performance Tuning

### Quick Performance Optimization Checklist

**Before optimizing, measure current performance:**
```bash
# check average execution time
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | .execution_duration_secs] | add / length'

# check model usage distribution
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | .agent_model.final] | group_by(.) | map({model: .[0], count: length})'

# check rate limit frequency
./agent_factory/log_search.sh "rate limit" | wc -l

# check processing rates
./agent_factory/monitor.sh --health
```

**Common optimizations (in order of impact):**
1. **Switch to cheaper models** (highest impact on cost, good impact on speed)
   - workers: `gpt-4o-mini` (fast, cheap)
   - planners: `gpt-4o` (balanced)
2. **Break large tasks into smaller ones** (high impact on speed, reliability)
   - split 50 LOC task into 3-4 atomic tasks
3. **Reduce sleep intervals** (moderate impact on speed, may increase rate limits)
   - `export ORCHESTRATOR_SLEEP_SECS=3`
4. **Increase concurrency** (moderate impact, only if not rate-limited)
   - `export ORCHESTRATOR_MAX_SPAWNS=2` (use separate workspace clones)
5. **Optimize task descriptions** (low impact on cost)
   - shorter prompts = lower token usage
   - use explicit file paths to reduce searches

### Optimizing Task Processing Speed

**Model Selection:**
- use faster, cheaper models for workers: `gpt-4o-mini` or `gpt-4o`
- reserve expensive models (`gpt-4`, `claude-opus`) for planners
- configure fallback models to avoid rate limit delays

**Concurrency Settings:**
```bash
# increase worker concurrency (if not rate-limited)
export ORCHESTRATOR_MAX_SPAWNS=2

# reduce sleep intervals for faster processing
export ORCHESTRATOR_SLEEP_SECS=3

# adjust throttling thresholds
export MAX_WORKER_PENDING=10  # allow more pending before throttling
```

**Task Optimization:**
- keep task descriptions concise (shorter prompts = lower token usage)
- break large tasks into smaller atomic tasks
- use explicit file paths to reduce codebase search overhead

### Reducing API Costs

**Model Tier Strategy:**
- workers: `gpt-4o-mini` (fast, cheap)
- sub-planners: `gpt-4o` (balanced)
- primary planner: `gpt-4` (when needed for complex planning)
- judge: deterministic (no LLM calls)

**Prompt Optimization:**
- include only essential context in goal file
- keep agent profiles focused and concise
- use explicit file paths in tasks to avoid broad searches

**Rate Limit Management:**
- always configure fallback models
- monitor rate limit usage via provenance
- implement exponential backoff (already done)
- reduce concurrency if hitting limits frequently

### Queue Throughput Optimization

**Throttling Configuration:**
```bash
# allow more pending tasks before throttling
export MAX_WORKER_PENDING=10
export MAX_SUBPLANNER_PENDING=5

# disable judge pause if judge is fast
export JUDGE_PAUSE_ON_PENDING=0
```

**Processing Rate Monitoring:**
```bash
# check processing rates
./agent_factory/monitor.sh --health

# analyze task durations
./agent_factory/provenance_summary.sh --json | jq '[.[] | .execution_duration_secs] | add / length'
```

**Parallel Processing:**
- use separate workspace clones for true parallelism
- use separate queue directories with multiple workers
- ensure workers don't conflict (different branches/queues)

## Security Considerations

### API Key Management

**Recommended: macOS Keychain**
```bash
# store API key securely
security add-generic-password -a "$USER" -s "cursor_cli_api_key" -w
# paste API key when prompted

# verify storage
security find-generic-password -a "$USER" -s "cursor_cli_api_key" -w
```

**Alternative: Environment Variables**
- only use for local development
- never commit `.env` files with API keys
- use separate keys for different environments

**Best Practices:**
- use Keychain for production/background jobs
- rotate API keys periodically
- use separate keys per project if possible
- never log API keys (orchestrator already handles this)

### Git Credentials

**For Judge Auto-Push:**
- use SSH keys for git authentication (recommended)
- or use credential helper: `git config credential.helper osxkeychain`
- never store passwords in plaintext

**Setting Up SSH Keys:**
```bash
# generate SSH key if needed
ssh-keygen -t ed25519 -C "your_email@example.com"

# add to ssh-agent
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519

# add public key to git hosting service (GitHub, GitLab, etc.)
cat ~/.ssh/id_ed25519.pub

# test connection
ssh -T git@github.com  # or git@gitlab.com, etc.
```

**Commit Safety:**
- judge only commits after all checks pass
- judge includes only whitelisted paths (`JUDGE_INCLUDE_PATHS`)
- review commits before pushing (if `JUDGE_AUTO_PUSH=0`)

**Example: Reviewing Commits Before Push:**
```bash
# disable auto-push for review
export JUDGE_AUTO_PUSH=0

# judge will commit but not push
# review commits manually
git log --oneline -5

# push when ready
git push origin main
```

### File System Security

**Sensitive Data:**
- never include sensitive data in task files
- use environment variables for secrets
- ensure `.gitignore` excludes sensitive files
- review `JUDGE_INCLUDE_PATHS` to avoid committing secrets

**Example: Protecting Sensitive Data:**
```bash
# ❌ BAD: API key in task file
# Task: Connect to external API
# API Key: sk-1234567890abcdef

# ✅ GOOD: Use environment variable
# Task: Connect to external API
# Note: API key stored in $EXTERNAL_API_KEY environment variable
# Agent should use: os.getenv('EXTERNAL_API_KEY')
```

**Securing Task Files:**
```bash
# ensure sensitive task files are not committed
echo "tasks/*_secret*.md" >> .gitignore

# use environment variables in code
# python example:
import os
api_key = os.getenv('API_KEY')
if not api_key:
    raise ValueError("API_KEY environment variable not set")
```

**Log Files:**
- log files may contain code snippets and context
- ensure `logs/` is in `.gitignore` (already done)
- rotate logs regularly to limit exposure window
- consider log encryption for sensitive projects

**Log Security Best Practices:**
```bash
# verify logs are ignored
git check-ignore logs/agent_runs/*.log

# set restrictive permissions on log directory
chmod 700 logs/agent_runs

# enable log rotation (already configured)
# logs older than 7 days are compressed
# logs older than 90 days are deleted
```

### Network Security

**API Communication:**
- agent CLI uses HTTPS for all API calls
- verify SSL certificates (default behavior)
- monitor for unexpected API usage (check provenance)

**Local Network:**
- launchd jobs run as your user (not root)
- no network ports are opened by agent_factory
- all communication is outbound to Cursor API

## Migration Guide

### Updating agent_factory in Existing Projects

**Step 1: Backup Current State**
```bash
# commit all changes
git add -A
git commit -m "backup before agent_factory update"

# backup current agent_factory
cp -r agent_factory agent_factory.backup
```

**Step 2: Update agent_factory**
```bash
# pull latest agent_factory from source
# or copy from another project
cp -r /path/to/new/agent_factory agent_factory.new

# compare changes
diff -r agent_factory agent_factory.new
```

**Step 3: Merge Configuration**
```bash
# backup current config
cp agent_factory/config.sh agent_factory/config.sh.backup

# compare old and new configs
diff agent_factory/config.sh.backup agent_factory.new/config.sh

# update config.sh with new defaults
# manually merge any project-specific overrides
vim agent_factory/config.sh

# example: preserve project-specific timeout
# old: AGENT_EXECUTION_TIMEOUT_SECS="${AGENT_EXECUTION_TIMEOUT_SECS:-3600}"
# new default: AGENT_EXECUTION_TIMEOUT_SECS="${AGENT_EXECUTION_TIMEOUT_SECS:-1800}"
# keep your override: AGENT_EXECUTION_TIMEOUT_SECS="${AGENT_EXECUTION_TIMEOUT_SECS:-3600}"
```

**Step 4: Update Scripts**
```bash
# replace orchestrator and other scripts
cp agent_factory.new/orchestrator agent_factory/
cp agent_factory.new/judge_daemon.sh agent_factory/
cp agent_factory.new/judge_trigger.sh agent_factory/
cp agent_factory.new/run_orchestrator agent_factory/
cp agent_factory.new/monitor.sh agent_factory/
cp agent_factory.new/queue_status.sh agent_factory/
# ... update other scripts as needed

# verify scripts are executable
chmod +x agent_factory/*.sh agent_factory/orchestrator

# test script syntax
bash -n agent_factory/orchestrator
bash -n agent_factory/judge_daemon.sh
```

**Step 5: Test Changes**
```bash
# stop existing jobs
./ops/agent_factory/stop.sh

# test orchestrator manually
./agent_factory/run_orchestrator \
  --profile Agent_profiles/worker.md \
  --goal-file goal.md \
  --queue-dir tasks/queue \
  --max 1 \
  --once

# verify no errors
echo $?  # should be 0
```

**Step 6: Restart Jobs**
```bash
# restart with updated scripts
./ops/agent_factory/start.sh

# monitor for issues
./agent_factory/monitor.sh --watch
```

### Handling Breaking Changes

**Configuration Changes:**
- old environment variable names still work (backward compatibility)
- new projects should use `config.sh` defaults
- migrate gradually: update scripts first, then config

**Script Changes:**
- check `CHANGELOG` or git history for breaking changes
- test in non-production environment first
- keep backup of working version

**API Changes:**
- agent CLI updates may require re-authentication
- check Cursor documentation for API changes
- test with `agent status` after updates

## Examples of Successful Configurations

### Small Project (Single Worker)

**Configuration:**
```bash
# agent_factory/config.sh
ORCHESTRATOR_SLEEP_SECS=5
ORCHESTRATOR_MAX_SPAWNS=1
MAX_WORKER_PENDING=5
AGENT_EXECUTION_TIMEOUT_SECS=1800
FALLBACK_MODEL="gpt-4o-mini"
```

**Agent Profiles:**
- worker: `gpt-4o-mini` (fast, cheap)
- planner: `gpt-4o` (when needed)
- judge: deterministic

**Setup:**
- single launchd job for worker
- single launchd job for judge
- judge trigger enabled

### Medium Project (Multiple Workers)

**Configuration:**
```bash
# agent_factory/config.sh
ORCHESTRATOR_SLEEP_SECS=3
ORCHESTRATOR_MAX_SPAWNS=1
MAX_WORKER_PENDING=10
AGENT_EXECUTION_TIMEOUT_SECS=1800
FALLBACK_MODEL="gpt-4o-mini"
```

**Agent Profiles:**
- worker: `gpt-4o` (balanced)
- planner: `gpt-4` (complex planning)
- judge: deterministic

**Setup:**
- 2-3 worker launchd jobs (separate queue directories)
- single judge daemon
- judge trigger with cooldown

### Large Project (High Throughput)

**Configuration:**
```bash
# agent_factory/config.sh
ORCHESTRATOR_SLEEP_SECS=2
ORCHESTRATOR_MAX_SPAWNS=1
MAX_WORKER_PENDING=20
AGENT_EXECUTION_TIMEOUT_SECS=3600
FALLBACK_MODEL="gpt-4o-mini"
```

**Agent Profiles:**
- worker: `gpt-4o-mini` (maximize throughput)
- planner: `gpt-4o` (efficient planning)
- judge: deterministic

**Setup:**
- 5+ worker launchd jobs (separate workspace clones)
- single judge daemon
- aggressive judge trigger (low cooldown)
- separate queue directories per worker

### Cost-Optimized Configuration

**Configuration:**
```bash
# agent_factory/config.sh
ORCHESTRATOR_SLEEP_SECS=10  # longer sleep = fewer API calls
ORCHESTRATOR_MAX_SPAWNS=1
MAX_WORKER_PENDING=5
AGENT_EXECUTION_TIMEOUT_SECS=1800
FALLBACK_MODEL="gpt-4o-mini"
```

**Agent Profiles:**
- worker: `gpt-4o-mini` (cheapest)
- planner: `gpt-4o-mini` (cheapest)
- judge: deterministic

**Setup:**
- single worker (sequential processing)
- longer sleep intervals
- concise task descriptions
- explicit file paths to reduce searches

### Development/Testing Configuration

**Configuration:**
```bash
# agent_factory/config.sh
ORCHESTRATOR_SLEEP_SECS=1  # fast iteration
ORCHESTRATOR_MAX_SPAWNS=1
MAX_WORKER_PENDING=3
AGENT_EXECUTION_TIMEOUT_SECS=600  # shorter timeout for testing
FALLBACK_MODEL="gpt-4o-mini"
```

**Agent Profiles:**
- worker: `gpt-4o-mini` (fast iteration)
- planner: `gpt-4o-mini` (fast iteration)
- judge: deterministic

**Setup:**
- run orchestrator manually (not launchd)
- use `--once` flag for single task execution
- monitor output in real-time
- quick feedback loop

## Operational Best Practices

### Daily Operations

**Morning Routine:**
```bash
# check system status
./agent_factory/monitor.sh

# review overnight activity
./agent_factory/provenance_summary.sh --detailed | head -20

# check for any blockers
cat .agent_factory_state/judge_blocker.md 2>/dev/null || echo "No blockers"
```

**Monitoring Schedule:**
- **hourly**: quick status check (`./agent_factory/queue_status.sh`)
- **daily**: full health check (`./agent_factory/monitor.sh --health`)
- **weekly**: review provenance for patterns (`./agent_factory/provenance_summary.sh --detailed`)

**Maintenance Tasks:**
```bash
# weekly: restart agents to clear memory
./ops/agent_factory/stop.sh && ./ops/agent_factory/start.sh

# monthly: review and clean old processed tasks (if needed)
# be careful: only if you're sure they're not needed for audit

# as needed: update agent profiles based on learnings
vim Agent_profiles/worker.md
```

### Scaling Operations

**Adding More Workers:**
```bash
# 1. create new queue directory
mkdir -p tasks/queue_worker2

# 2. create new launchd job for worker2
cp agent_factory/launchd/template_daemon.plist \
   ~/Library/LaunchAgents/com.YOUR_PROJECT.worker2.plist

# 3. edit plist: change label and queue-dir
# Label: com.YOUR_PROJECT.worker2
# queue-dir: tasks/queue_worker2

# 4. load and start
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.YOUR_PROJECT.worker2.plist
launchctl enable gui/$(id -u)/com.YOUR_PROJECT.worker2
```

**Load Balancing:**
```bash
# distribute tasks across queues
# option 1: manual distribution
cp tasks/queue/task_*.md tasks/queue_worker2/

# option 2: use planner to distribute
# create tasks in different queue directories
```

### Cost Management

**Monitoring API Usage:**
```bash
# track model usage
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | .agent_model.final] | group_by(.) | map({model: .[0], count: length})'

# estimate costs (approximate)
# gpt-4o-mini: ~$0.15 per 1M input tokens, ~$0.60 per 1M output tokens
# gpt-4o: ~$2.50 per 1M input tokens, ~$10 per 1M output tokens
# gpt-4: ~$30 per 1M input tokens, ~$60 per 1M output tokens

# find expensive tasks (long execution times)
./agent_factory/provenance_summary.sh --json | \
  jq '[.[] | select(.execution_duration_secs > 600)] | length'
```

**Cost Optimization Strategies:**
1. use `gpt-4o-mini` for workers (cheapest, still effective)
2. reserve `gpt-4` for complex planning only
3. keep task descriptions concise (fewer tokens)
4. use explicit file paths (reduces codebase searches)
5. break large tasks into smaller ones (faster, cheaper)

## Troubleshooting

For detailed troubleshooting information, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

### Quick Diagnostic Commands

```bash
# comprehensive system status
./agent_factory/monitor.sh

# check queue health
./agent_factory/monitor.sh --health

# find recent errors
./agent_factory/log_search.sh --errors --recent 5

# check failed tasks
./agent_factory/provenance_summary.sh --failed-only --detailed

# verify agents are running
ps aux | grep orchestrator
```

### Common Issues

**Agent CLI Not Found:**
```bash
# check installation
command -v agent || echo "not installed"
# install if missing
curl -fsS https://cursor.com/install | bash
```

**Authentication Errors:**
```bash
# check auth status
agent status
# login if needed
agent login
```

**Empty Agent Output:**
The orchestrator detects empty output and requeues the task. Check `logs/agent_runs/` for details.

**NEED-INFO Detection:**
If an agent outputs "NEED-INFO", the task is automatically requeued. Update the agent profile to avoid questions.

**Tasks Not Processing:**
```bash
# restart agents (fixes most issues)
./ops/agent_factory/stop.sh && ./ops/agent_factory/start.sh
# verify goal file exists
test -f goal.md || cp agent_factory/goal_template.md goal.md
```

## Documentation Summary

This README provides comprehensive documentation for agent_factory. Key sections:

**Getting Started:**
- [Quick Start](#quick-start) - setup and basic usage
- [Best Practices - Getting Started](#getting-started-step-by-step) - step-by-step guide for new projects

**Core Concepts:**
- [Architecture](#architecture) - system components and design
- [Goal File](#goal-file-source-of-truth) - source of truth for all agents
- [Agent Roles](#agent-roles-4-agent-system) - planner, sub-planner, worker, judge
- [Queue System](#queue-system) - task queue organization
- [Commit Workflow](#commit-workflow) - how code gets committed

**Best Practices:**
- [Best Practices](#best-practices) - queue management, agent profiles, goal file structure
- [Performance Tuning](#performance-tuning) - optimizing speed, reducing costs, throughput
- [Security Considerations](#security-considerations) - API keys, git credentials, file system security
- [Operational Best Practices](#operational-best-practices) - daily operations, scaling, cost management

**Configuration:**
- [Configuration](#configuration) - centralized config in `config.sh`
- [Examples of Successful Configurations](#examples-of-successful-configurations) - real-world setups

**Troubleshooting:**
- [Troubleshooting](#troubleshooting) - quick reference and common issues
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - comprehensive troubleshooting guide with:
  - Quick reference and decision trees
  - Common errors and solutions
  - Debugging strategies
  - Real-world troubleshooting scenarios
  - Practical examples

**Advanced Topics:**
- [Provenance Tracking](#provenance-tracking) - audit trail for all task executions
- [Log Management](#log-management-and-rotation) - automatic log rotation
- [Migration Guide](#migration-guide) - updating agent_factory in existing projects
- [Error Handling](#error-handling-and-recovery) - automatic recovery mechanisms

**Quick Links:**
- [Best Practices Checklist](#quick-reference-checklist) - quick reference for daily operations
- [One-Command Diagnostics](TROUBLESHOOTING.md#one-command-diagnostics) - troubleshooting quick reference
- [Essential Commands Cheat Sheet](TROUBLESHOOTING.md#essential-commands-cheat-sheet) - common commands
- [Decision Tree](TROUBLESHOOTING.md#decision-tree-what-to-do-when-something-goes-wrong) - what to do when something goes wrong

## Design Principles

Based on [Cursor's scaling agents research](https://cursor.com/blog/scaling-agents):

1. **Orchestrator is NOT an agent**: It's a deterministic script (no LLM calls)
2. **Planners are agents**: They use LLMs to create plans
3. **Workers are agents**: They use LLMs to implement tasks
4. **Simple coordination**: File-based queues, atomic moves (no locks)
5. **Tunnel vision**: Workers focus on one task, no big-picture thinking

## License

Same as parent project.
