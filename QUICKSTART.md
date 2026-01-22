# Quick Start Guide

## For a New Project

### 1. Copy agent_factory to your project

```bash
# From your project root
cp -r /path/to/agent_factory .
```

### 2. Run setup script

```bash
./agent_factory/setup.sh my_project_name
```

This creates:
- `Agent_profiles/` generated from `agent_factory/Agent_profiles/` templates (Primary Planner, Sub-Planner, Worker, Judge)
- `tasks/` directory structure (planner_queue, subplanner_queue, queue, judge_queue)
- `logs/` directory
- launchd-based background commands (via `ops/agent_factory/`)
- `ops/bootstrap_python.sh` for judge dependencies (pytest + ruff)

### 2a. Install judge dependencies

Judge runs `pytest` and `ruff`. Install them into a repo-local venv:

```bash
./ops/bootstrap_python.sh
```

### 3. Create goal file (source of truth)

```bash
cp agent_factory/goal_template.md goal.md
# Edit goal.md with your project objective, success criteria, and constraints
```

The goal file is prepended to every agent prompt, so agents always see the current objective. You can update it anytime as requirements change.

note: background launchd jobs always pass `--goal-file goal.md`, so `goal.md` must exist before starting.

### 4. Customize agent profiles

Edit the 4 agent profiles with your project-specific rules:

**Worker** (`Agent_profiles/worker.md`):
```markdown
## Repo rules
- Use Python 3.11+
- Follow PEP 8
- Write tests for all functions
```

**Judge** (`Agent_profiles/judge.md`):
```markdown
## Workflow
3. **Test:** Run the test suite (e.g., `pytest`, `ruff check`).
4. **Lint:** Run linting tools (e.g., `ruff format --check`).
```
Customize the test/lint commands for your project.

### 5. Create your first task

```bash
cat > tasks/queue/001_my_task.md <<'EOF'
# Task: Implement feature X

## Objective
Build feature X that does Y.

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2

## File Paths
- Create: `src/feature_x.py`
EOF
```

### 6. Run the agent

```bash
# One-off execution (with goal file)
./agent_factory/run_orchestrator \
  --profile Agent_profiles/worker.md \
  --goal-file goal.md \
  --queue-dir tasks/queue \
  --max 1 \
  --once
```

### 7. Run in background (launchd, macos)

```bash
./ops/agent_factory/start.sh
./ops/agent_factory/monitor.sh
./ops/agent_factory/stop.sh
```

note: `start.sh` will fail non-zero if launchd jobs are not loaded correctly.

**Updating the goal**: Edit `goal.md` anytime. The next agent run will automatically see the updated goal.

## For Concurrent Workers

### Option A: Separate Workspace Clones

```bash
# Clone 1
cd /path/to/project_worker1
./agent_factory/run_orchestrator --profile Agent_profiles/worker.md --goal-file goal.md --queue-dir tasks/queue --max 1 --sleep 10 &

# Clone 2
cd /path/to/project_worker2
./agent_factory/run_orchestrator --profile Agent_profiles/worker.md --goal-file goal.md --queue-dir tasks/queue --max 1 --sleep 10 &
```

### Option B: Separate Queue Directories

```bash
# Worker 1 processes tasks/queue_1/
./agent_factory/run_orchestrator --profile Agent_profiles/worker.md --goal-file goal.md --queue-dir tasks/queue_1 --max 1 --sleep 10 &

# Worker 2 processes tasks/queue_2/
./agent_factory/run_orchestrator --profile Agent_profiles/worker.md --goal-file goal.md --queue-dir tasks/queue_2 --max 1 --sleep 10 &
```

### Option C: Launchd Jobs (macOS)

```bash
# Create worker 1 plist
cp agent_factory/launchd/template_daemon.plist ~/Library/LaunchAgents/com.myproject.worker1.plist
# Edit: Label=com.myproject.worker1, queue-dir=tasks/queue_1

# Create worker 2 plist
cp agent_factory/launchd/template_daemon.plist ~/Library/LaunchAgents/com.myproject.worker2.plist
# Edit: Label=com.myproject.worker2, queue-dir=tasks/queue_2

# Load both
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.myproject.worker1.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.myproject.worker2.plist
```

## Monitoring

```bash
# Watch latest agent run
tail -f logs/agent_runs/$(ls -1t logs/agent_runs | head -n 1)

# Check queue status
echo "pending: $(find tasks/queue -maxdepth 1 -type f -name '*.md' | wc -l)"
echo "processed: $(find tasks/queue/processed -maxdepth 1 -type f | wc -l)"
```

## Troubleshooting

**Agent not found:**
```bash
curl -fsS https://cursor.com/install | bash
agent login
```

**Authentication errors:**
```bash
agent status
# If not logged in:
agent login
# Or store API key in Keychain:
security add-generic-password -a "$USER" -s "cursor_cli_api_key" -w
security add-generic-password -a "$USER" -s "antigravity_cli_api_key" -w
```

**Empty output / NEED-INFO:**
- Check `logs/agent_runs/` for agent output
- Update agent profile to avoid questions
- Task is automatically requeued if NEED-INFO detected

**Rate limit errors:**
- Orchestrator automatically retries with fallback model
- Set `FALLBACK_MODEL` environment variable or use `--fallback-model`
- Default fallback: `claude-3-5-sonnet-20241022`
- Both attempts are logged in the same log file
