#!/usr/bin/env bash
set -euo pipefail

# setup.sh - Bootstrap agent factory in a new project
#
# Usage: ./agent_factory/setup.sh [project_name]
#
# Creates:
# - Agent_profiles/ directory with template profiles
# - tasks/ directory structure
# - logs/ directory
# - ops commands for start/monitor/stop (launchd-based)

PROJECT_NAME="${1:-$(basename "$(pwd)")}"
REPO_ROOT="$(pwd)"

echo "Setting up agent factory for project: $PROJECT_NAME"
echo "Repo root: $REPO_ROOT"
echo

# Create directories
mkdir -p Agent_profiles tasks/{queue,subplanner_queue,planner_queue,judge_queue} logs/agent_runs ops/agent_factory

# Enforce LF line endings to avoid bash parsing errors on macOS.
if [[ ! -f .gitattributes ]]; then
  cat > .gitattributes <<'EOF'
*.sh text eol=lf
*.md text eol=lf
*.yaml text eol=lf
*.yml text eol=lf
EOF
  echo "Created .gitattributes (enforces LF endings for .sh/.md/.yml/.yaml)"
fi

# Copy template profiles (4-agent system)
if [[ ! -f Agent_profiles/primary_planner.md ]]; then
  cp agent_factory/Agent_profiles/template_primary_planner.md Agent_profiles/primary_planner.md
  echo "Created Agent_profiles/primary_planner.md (edit with your project context)"
fi

if [[ ! -f Agent_profiles/sub_planner.md ]]; then
  cp agent_factory/Agent_profiles/template_sub_planner.md Agent_profiles/sub_planner.md
  echo "Created Agent_profiles/sub_planner.md (edit with your project context)"
fi

if [[ ! -f Agent_profiles/worker.md ]]; then
  cp agent_factory/Agent_profiles/template_worker.md Agent_profiles/worker.md
  echo "Created Agent_profiles/worker.md (edit with your project rules)"
fi

if [[ ! -f Agent_profiles/judge.md ]]; then
  cp agent_factory/Agent_profiles/template_judge.md Agent_profiles/judge.md
  echo "Created Agent_profiles/judge.md (edit with your test/lint commands)"
fi

# Copy goal template
if [[ ! -f goal.md ]]; then
  cp agent_factory/goal_template.md goal.md
  echo "Created goal.md (edit with your project objective and success criteria)"
  echo "  This file is the source of truth - agents check it on every run"
fi

# Create an initial planner ticket so background runs can start immediately.
if [[ -z "$(find tasks/planner_queue -maxdepth 1 -type f -name '*.md' 2>/dev/null | head -n 1 || true)" ]]; then
  cat > tasks/planner_queue/10_initial_planning.md <<'EOF'
# Task: initial planning cycle

## Objective
Use `goal.md` as the source of truth. Read project context and produce:
- `planning_manifest.json` at repo root
- one domain directive ticket per domain under `tasks/subplanner_queue/`

## Acceptance Criteria
- [ ] `planning_manifest.json` created with `cycle_id` and `subplanner_tickets`
- [ ] all `ticket_path` entries exist and point under `tasks/subplanner_queue/`
- [ ] no source code modifications in this step

## Inputs
- `goal.md`
- `documentation.md`
- `project_milestones.md`
- `documents/`, `Meeting_transctipts/`, `Data/`
EOF
  echo "Created tasks/planner_queue/10_initial_planning.md"
fi

# Create repo-local ops commands (thin wrappers).
if [[ ! -f ops/agent_factory/start.sh ]]; then
  cat > ops/agent_factory/start.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

exec ./agent_factory/launchd_start.sh "$@"
EOF
  chmod +x ops/agent_factory/start.sh
  echo "Created ops/agent_factory/start.sh"
fi

if [[ ! -f ops/agent_factory/monitor.sh ]]; then
  cat > ops/agent_factory/monitor.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

exec ./agent_factory/monitor.sh --watch
EOF
  chmod +x ops/agent_factory/monitor.sh
  echo "Created ops/agent_factory/monitor.sh"
fi

if [[ ! -f ops/agent_factory/stop.sh ]]; then
  cat > ops/agent_factory/stop.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

exec ./agent_factory/launchd_stop.sh "$@"
EOF
  chmod +x ops/agent_factory/stop.sh
  echo "Created ops/agent_factory/stop.sh"
fi

if [[ ! -f ops/agent_factory/status.sh ]]; then
  cat > ops/agent_factory/status.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

exec ./agent_factory/launchd_status.sh "$@"
EOF
  chmod +x ops/agent_factory/status.sh
  echo "Created ops/agent_factory/status.sh"
fi

if [[ ! -f ops/agent_factory/stop_remove.sh ]]; then
  cat > ops/agent_factory/stop_remove.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

exec ./agent_factory/launchd_stop.sh --remove "$@"
EOF
  chmod +x ops/agent_factory/stop_remove.sh
  echo "Created ops/agent_factory/stop_remove.sh"
fi

if [[ ! -f ops/bootstrap_python.sh ]]; then
  cat > ops/bootstrap_python.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

python3 -m venv .venv

. .venv/bin/activate

python -m pip install -U pip
if [[ -f requirements.txt ]]; then
  python -m pip install -r requirements.txt
fi
if [[ -f requirements-dev.txt ]]; then
  python -m pip install -r requirements-dev.txt
fi
python -m pip install pytest ruff

python -c "import pytest; import ruff; print('ok: pytest and ruff importable')"
EOF
  chmod +x ops/bootstrap_python.sh
  echo "Created ops/bootstrap_python.sh"
fi

echo
echo "Setup complete!"
echo
echo "Next steps:"
echo "1. Edit goal.md with your project objective and success criteria (source of truth)"
echo "2. Edit Agent_profiles/*.md with your project-specific rules"
echo "2a. Install judge deps: ./ops/bootstrap_python.sh"
echo "3. Create your first task: echo '# Task: ...' > tasks/queue/001_task.md"
echo "4. Test run: ./agent_factory/run_orchestrator --profile Agent_profiles/worker.md --goal-file goal.md --queue-dir tasks/queue --max 1 --once"
echo "5. Start background agents (launchd): ./ops/agent_factory/start.sh"
echo "6. Monitor: ./ops/agent_factory/monitor.sh"
echo "7. Stop: ./ops/agent_factory/stop.sh"
