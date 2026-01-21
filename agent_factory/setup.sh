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
#
# Validates:
# - git is installed and repo is initialized
# - agent CLI is installed and authenticated
# - python3 is available (minimum 3.8)
# - agent_factory directory structure exists
# - template files are present
# - write permissions in current directory
# - config.sh exists and is readable

# detect project name from git remote, directory name, or argument
detect_project_name() {
  local name="${1:-}"
  if [[ -n "$name" ]]; then
    echo "$name"
    return 0
  fi
  
  # try git remote first (most accurate)
  if [[ -d .git ]]; then
    local remote_url
    remote_url="$(git config --get remote.origin.url 2>/dev/null || true)"
    if [[ -n "$remote_url" ]]; then
      # extract project name from git URL (handles both SSH and HTTPS)
      if [[ "$remote_url" =~ :([^/]+)\.git$ ]] || [[ "$remote_url" =~ /([^/]+)\.git$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
      fi
    fi
  fi
  
  # fallback to directory name
  basename "$(pwd)"
}

PROJECT_NAME="$(detect_project_name "${1:-}")"
REPO_ROOT="$(pwd)"
AGENT_FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# track what was created/validated for summary
SETUP_SUMMARY=()
VALIDATION_SUMMARY=()

# validate script is being run from correct location
# check that agent_factory/setup.sh exists relative to current directory
if [[ ! -f "agent_factory/setup.sh" ]] && [[ "$AGENT_FACTORY_DIR/setup.sh" != "$(pwd)/agent_factory/setup.sh" ]]; then
  # check if we're inside agent_factory directory (wrong location)
  if [[ "$(basename "$(pwd)")" == "agent_factory" ]] || [[ -f "setup.sh" ]] && [[ -f "orchestrator" ]]; then
    echo "ERROR: setup.sh should be run from the project root, not from inside agent_factory/" >&2
    echo "  Current directory: $(pwd)" >&2
    echo "  Expected: <project_root>/agent_factory/setup.sh" >&2
    echo "  Fix: cd .. && ./agent_factory/setup.sh" >&2
    exit 1
  fi
fi

# detect if this is likely a project root (has common project files)
IS_LIKELY_PROJECT_ROOT=0
if [[ -f "README.md" ]] || [[ -f "pyproject.toml" ]] || [[ -f "package.json" ]] || [[ -f "requirements.txt" ]] || [[ -d ".git" ]]; then
  IS_LIKELY_PROJECT_ROOT=1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Agent Factory Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Project: $PROJECT_NAME"
echo "Repo root: $REPO_ROOT"
if [[ $IS_LIKELY_PROJECT_ROOT -eq 0 ]]; then
  echo "⚠️  Note: Current directory doesn't appear to be a project root"
  echo "   (no README.md, pyproject.toml, package.json, requirements.txt, or .git found)"
  echo "   Make sure you're running this from your project root directory"
  echo
fi
echo

# validation functions
check_prerequisites() {
  local errors=0
  local warnings=0

  echo "Validating prerequisites..."
  echo

  # check we're in the right place (agent_factory should exist)
  if [[ ! -d "$AGENT_FACTORY_DIR" ]]; then
    echo "ERROR: agent_factory directory not found at: $AGENT_FACTORY_DIR" >&2
    echo "  Make sure you're running this script from the project root" >&2
    echo "  Expected location: <project_root>/agent_factory/setup.sh" >&2
    echo "  Current directory: $(pwd)" >&2
    echo "  Fix: cd to your project root directory, then run: ./agent_factory/setup.sh" >&2
    errors=$((errors + 1))
  fi
  
  # additional validation: check that agent_factory is a subdirectory of current directory
  if [[ -d "$AGENT_FACTORY_DIR" ]]; then
    local agent_factory_relative
    agent_factory_relative="$(realpath --relative-to="$REPO_ROOT" "$AGENT_FACTORY_DIR" 2>/dev/null || echo "$AGENT_FACTORY_DIR")"
    if [[ "$agent_factory_relative" != "agent_factory" ]] && [[ ! "$agent_factory_relative" =~ ^\.\./ ]]; then
      echo "WARNING: agent_factory directory structure may be unexpected" >&2
      echo "  Expected: agent_factory/ relative to project root" >&2
      echo "  Found: $agent_factory_relative" >&2
      echo "  This may indicate the script is being run from the wrong location" >&2
      warnings=$((warnings + 1))
    fi
  fi
  
  # check if agent_factory directory is complete (has key files)
  if [[ -d "$AGENT_FACTORY_DIR" ]]; then
    local missing_key_files=0
    local key_files=(
      "orchestrator"
      "run_orchestrator"
      "config.sh"
      "Agent_profiles/template_worker.md"
    )
    for key_file in "${key_files[@]}"; do
      if [[ ! -e "$AGENT_FACTORY_DIR/$key_file" ]]; then
        missing_key_files=$((missing_key_files + 1))
        if [[ $missing_key_files -eq 1 ]]; then
          echo "WARNING: agent_factory directory appears incomplete (missing key files)" >&2
        fi
        echo "  Missing: $AGENT_FACTORY_DIR/$key_file" >&2
      fi
    done
    if [[ $missing_key_files -gt 0 ]]; then
      echo "  The agent_factory directory may be corrupted or incomplete" >&2
      echo "  Fix: Re-copy agent_factory from source or restore from backup" >&2
      warnings=$((warnings + 1))
    fi
  fi

  # check write permissions
  if [[ ! -w . ]]; then
    echo "ERROR: no write permission in current directory: $(pwd)" >&2
    echo "  Fix: chmod u+w ." >&2
    echo "  Or check if you're in the correct directory with write access" >&2
    echo "  Verify: ls -ld ." >&2
    errors=$((errors + 1))
  else
    # test write capability by creating a temporary file
    local test_file=".setup_test_write_$$"
    if ! touch "$test_file" 2>/dev/null || ! rm -f "$test_file" 2>/dev/null; then
      echo "WARNING: write permission check passed but cannot create/delete files" >&2
      echo "  This may indicate filesystem issues or disk space problems" >&2
      echo "  Verify: df -h ." >&2
      warnings=$((warnings + 1))
    fi
  fi

  # check disk space (warn if less than 100MB available)
  if command -v df >/dev/null 2>&1; then
    local available_space
    available_space="$(df -m . 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")"
    if [[ -n "$available_space" ]] && [[ "$available_space" =~ ^[0-9]+$ ]]; then
      if [[ $available_space -lt 100 ]]; then
        echo "WARNING: low disk space detected (${available_space}MB available)" >&2
        echo "  Agent factory may need more space for logs and temporary files" >&2
        echo "  Recommended: at least 100MB free space" >&2
        echo "  Check: df -h ." >&2
        warnings=$((warnings + 1))
      else
        echo "✓ sufficient disk space available (${available_space}MB)"
      fi
    fi
  fi

  # check git
  if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is not installed" >&2
    echo "  Install: https://git-scm.com/downloads" >&2
    echo "  macOS: brew install git" >&2
    echo "  Linux: sudo apt-get install git  # or use your package manager" >&2
    echo "  Verify after install: git --version" >&2
    errors=$((errors + 1))
  elif [[ ! -d .git ]]; then
    echo "WARNING: not a git repository (no .git directory found)" >&2
    echo "  Initialize with: git init" >&2
    echo "  Optional: git remote add origin <your-repo-url>" >&2
    echo "  Note: git is recommended but not strictly required for agent_factory" >&2
    warnings=$((warnings + 1))
  else
    echo "✓ git found and repository initialized"
    # verify git is functional
    if git rev-parse --git-dir >/dev/null 2>&1; then
      VALIDATION_SUMMARY+=("git repository")
    else
      echo "WARNING: .git directory exists but git commands may not work correctly" >&2
      echo "  Verify: git status" >&2
      warnings=$((warnings + 1))
    fi
  fi

  # check python3 with version validation
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is not installed" >&2
    echo "  Install: https://www.python.org/downloads/" >&2
    echo "  macOS: brew install python3" >&2
    errors=$((errors + 1))
  else
    local python_version python_major python_minor
    python_version="$(python3 --version 2>&1 || echo "unknown")"
    
    # extract version numbers (e.g., "Python 3.11.5" -> 3.11)
    if [[ "$python_version" =~ Python[[:space:]]+([0-9]+)\.([0-9]+) ]]; then
      python_major="${BASH_REMATCH[1]}"
      python_minor="${BASH_REMATCH[2]}"
      
      if [[ $python_major -lt 3 ]] || [[ $python_major -eq 3 && $python_minor -lt 8 ]]; then
        echo "WARNING: python3 version is $python_version (minimum 3.8 required)" >&2
        echo "  Some features may not work correctly" >&2
        warnings=$((warnings + 1))
      else
        echo "✓ python3 found: $python_version"
        VALIDATION_SUMMARY+=("python3 (${python_version})")
      fi
    else
      echo "✓ python3 found: $python_version (version check skipped)"
      VALIDATION_SUMMARY+=("python3")
    fi
  fi

  # check agent CLI
  local agent_bin="${AGENT_BIN:-}"
  if [[ -z "$agent_bin" ]]; then
    # check common installation locations
    local common_paths=(
      "$HOME/.local/bin/agent"
      "/usr/local/bin/agent"
      "/opt/homebrew/bin/agent"
    )
    
    # try command -v first (checks PATH)
    agent_bin="$(command -v agent 2>/dev/null || true)"
    
    # if not in PATH, check common locations
    if [[ -z "$agent_bin" ]]; then
      for path in "${common_paths[@]}"; do
        if [[ -x "$path" ]]; then
          agent_bin="$path"
          echo "ℹ️  agent CLI found at: $agent_bin (not in PATH)" >&2
          echo "   Consider adding to PATH: export PATH=\"$(dirname "$agent_bin"):\$PATH\"" >&2
          echo "   Or add to ~/.zshrc or ~/.bashrc: export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2
          echo "   After adding to PATH, verify: command -v agent" >&2
          warnings=$((warnings + 1))
          break
        fi
      done
    fi

    # validate agent CLI is in PATH if found via command -v
    if [[ -n "$agent_bin" ]] && [[ "$agent_bin" == "$(command -v agent 2>/dev/null || true)" ]]; then
      # verify it's actually accessible in PATH
      local path_check
      path_check="$(echo "$PATH" | tr ':' '\n' | grep -F "$(dirname "$agent_bin")" || true)"
      if [[ -z "$path_check" ]]; then
        echo "WARNING: agent CLI found but may not be accessible in all contexts" >&2
        echo "  Current PATH may not include: $(dirname "$agent_bin")" >&2
        echo "  Background jobs (launchd) may not find agent CLI" >&2
        echo "  Fix: add to shell config (~/.zshrc or ~/.bashrc):" >&2
        echo "    export PATH=\"$(dirname "$agent_bin"):\$PATH\"" >&2
        warnings=$((warnings + 1))
      else
        # check if PATH is persisted in shell config files (important for launchd)
        local agent_dir="$(dirname "$agent_bin")"
        local shell_config_updated=0
        local shell_configs=()
        
        # detect shell and check appropriate config file
        if [[ -n "${ZSH_VERSION:-}" ]] || [[ "$SHELL" == *"zsh"* ]]; then
          shell_configs=("$HOME/.zshrc" "$HOME/.zshenv")
        elif [[ -n "${BASH_VERSION:-}" ]] || [[ "$SHELL" == *"bash"* ]]; then
          shell_configs=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile")
        else
          # check common config files
          shell_configs=("$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile")
        fi
        
        for config_file in "${shell_configs[@]}"; do
          if [[ -f "$config_file" ]] && grep -q "PATH.*$agent_dir\|$agent_dir.*PATH" "$config_file" 2>/dev/null; then
            shell_config_updated=1
            break
          fi
        done
        
        if [[ $shell_config_updated -eq 0 ]]; then
          echo "ℹ️  agent CLI is in PATH, but PATH may not persist for background jobs" >&2
          echo "   To ensure launchd jobs can find agent CLI, add to shell config:" >&2
          if [[ -f "$HOME/.zshrc" ]]; then
            echo "     echo 'export PATH=\"$agent_dir:\$PATH\"' >> ~/.zshrc" >&2
          elif [[ -f "$HOME/.bashrc" ]]; then
            echo "     echo 'export PATH=\"$agent_dir:\$PATH\"' >> ~/.bashrc" >&2
          else
            echo "     echo 'export PATH=\"$agent_dir:\$PATH\"' >> ~/.profile" >&2
          fi
          echo "   Then restart your shell or run: source ~/.zshrc  # or ~/.bashrc" >&2
        fi
      fi
    fi
  fi

  if [[ -z "$agent_bin" ]] || [[ ! -x "$agent_bin" ]]; then
    echo "ERROR: agent CLI is not installed or not executable" >&2
    echo >&2
    echo "  Quick fix (copy and paste):" >&2
    echo "    curl -fsS https://cursor.com/install | bash" >&2
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2
    echo "    echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc  # or ~/.bashrc" >&2
    echo "    agent login" >&2
    echo "    agent status  # verify authentication" >&2
    echo >&2
    echo "  Manual installation:" >&2
    echo "    1. Download from: https://cursor.com" >&2
    echo "    2. Add to PATH: export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2
    echo "    3. Add to shell config (~/.zshrc or ~/.bashrc) for persistence" >&2
    echo "    4. Verify: command -v agent" >&2
    echo "    5. Authenticate: agent login" >&2
    echo "    6. Verify: agent status" >&2
    errors=$((errors + 1))
  else
    echo "✓ agent CLI found: $agent_bin"
    
    # verify agent CLI is actually working (not just a broken symlink)
    local agent_test_ok=0
    local agent_version_output
    if agent_version_output="$("$agent_bin" --version 2>&1)" && [[ -n "$agent_version_output" ]]; then
      agent_test_ok=1
      echo "✓ agent CLI is functional (version: ${agent_version_output%%$'\n'*})"
    elif "$agent_bin" version >/dev/null 2>&1; then
      agent_test_ok=1
      echo "✓ agent CLI is functional (version command works)"
    elif "$agent_bin" --help >/dev/null 2>&1; then
      agent_test_ok=1
      echo "✓ agent CLI is functional (help command works)"
    else
      echo "WARNING: agent CLI found but may not be working correctly" >&2
      echo "  Test manually: $agent_bin --help" >&2
      echo "  If it fails, reinstall: curl -fsS https://cursor.com/install | bash" >&2
      warnings=$((warnings + 1))
    fi
    
    # verify agent CLI can execute a simple command (not just help/version)
    if [[ $agent_test_ok -eq 1 ]]; then
      if ! "$agent_bin" status >/dev/null 2>&1 && ! "$agent_bin" --help >/dev/null 2>&1; then
        echo "WARNING: agent CLI may not be fully functional" >&2
        echo "  Test manually: $agent_bin status" >&2
        warnings=$((warnings + 1))
      fi
    fi
    
    # check agent authentication with robust error handling
    local auth_status auth_exit_code
    auth_status="$("$agent_bin" status 2>&1)" || auth_exit_code=$?
    
    # check if authentication is working
    local auth_ok=0
    if [[ ${auth_exit_code:-0} -eq 0 ]]; then
      # normalize output for checking (lowercase, remove extra whitespace)
      local normalized_status
      normalized_status="$(echo "$auth_status" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')"
      
      # check for common success indicators
      if [[ "$normalized_status" =~ "authenticated" ]] || \
         [[ "$normalized_status" =~ "logged in" ]] || \
         [[ "$normalized_status" =~ "ready" ]] || \
         [[ -n "$normalized_status" && ! "$normalized_status" =~ "not logged in" ]] && \
         [[ ! "$normalized_status" =~ "authentication required" ]] && \
         [[ ! "$normalized_status" =~ "error" ]] && \
         [[ ! "$normalized_status" =~ "failed" ]]; then
        auth_ok=1
      fi
    fi
    
    # also check for keychain-based auth as fallback
    if [[ $auth_ok -eq 0 ]]; then
      local service_name="${CURSOR_KEYCHAIN_SERVICE:-cursor_cli_api_key}"
      local account_name="${CURSOR_KEYCHAIN_ACCOUNT:-$USER}"
      if security find-generic-password -a "$account_name" -s "$service_name" -w >/dev/null 2>&1; then
        auth_ok=1
        echo "✓ agent CLI authentication (via keychain)"
      fi
    fi
    
    if [[ $auth_ok -eq 1 ]]; then
      echo "✓ agent CLI is authenticated"
      VALIDATION_SUMMARY+=("agent CLI authentication")
    else
      echo "ERROR: agent CLI is not authenticated" >&2
      echo >&2
      echo "  Quick fix (copy and paste):" >&2
      echo "    $agent_bin login" >&2
      echo "    # Follow the prompts to authenticate" >&2
      echo "    $agent_bin status  # verify authentication" >&2
      echo >&2
      echo "  Alternative: Use keychain (recommended for background jobs):" >&2
      echo "    security add-generic-password -a \"\$USER\" -s \"cursor_cli_api_key\" -w" >&2
      echo "    # Paste your API key when prompted" >&2
      echo "    # Get your API key from: https://cursor.com/settings/api" >&2
      echo "    $agent_bin status  # verify authentication" >&2
      echo >&2
      echo "  Expected output: should show 'authenticated' or 'logged in' or 'ready'" >&2
      if [[ -n "${auth_status:-}" ]]; then
        echo "  Last status output: ${auth_status:0:100}..." >&2
      fi
      echo "  💡 TIP: For background jobs (launchd), use keychain method" >&2
      errors=$((errors + 1))
    fi
  fi

  # check agent_factory template files exist
  local missing_templates=()
  local required_templates=(
    "Agent_profiles/template_primary_planner.md"
    "Agent_profiles/template_sub_planner.md"
    "Agent_profiles/template_worker.md"
    "Agent_profiles/template_judge.md"
    "goal_template.md"
  )

  for template in "${required_templates[@]}"; do
    if [[ ! -f "$AGENT_FACTORY_DIR/$template" ]]; then
      missing_templates+=("$template")
    fi
  done

  if [[ ${#missing_templates[@]} -gt 0 ]]; then
    echo "ERROR: missing required template files:" >&2
    for template in "${missing_templates[@]}"; do
      echo "  - $AGENT_FACTORY_DIR/$template" >&2
    done
    echo "  The agent_factory directory appears to be incomplete" >&2
    echo "  Fix: ensure agent_factory directory is complete or re-copy from source" >&2
    errors=$((errors + 1))
  else
    echo "✓ all template files found"
    VALIDATION_SUMMARY+=("template files")
  fi

  # check config.sh exists, is readable, and can be sourced
  if [[ ! -f "$AGENT_FACTORY_DIR/config.sh" ]]; then
    echo "ERROR: config.sh not found at: $AGENT_FACTORY_DIR/config.sh" >&2
    echo "  The agent_factory directory appears to be incomplete" >&2
    echo "  Fix: ensure agent_factory directory is complete or re-copy from source" >&2
    errors=$((errors + 1))
  elif [[ ! -r "$AGENT_FACTORY_DIR/config.sh" ]]; then
    echo "ERROR: config.sh is not readable: $AGENT_FACTORY_DIR/config.sh" >&2
    echo "  Fix: chmod u+r $AGENT_FACTORY_DIR/config.sh" >&2
    errors=$((errors + 1))
  else
    echo "✓ config.sh found and readable"
    # test that config.sh can be sourced without errors
    if ! bash -n "$AGENT_FACTORY_DIR/config.sh" 2>/dev/null; then
      echo "WARNING: config.sh has syntax errors" >&2
      echo "  Fix: check syntax with: bash -n $AGENT_FACTORY_DIR/config.sh" >&2
      warnings=$((warnings + 1))
    else
      echo "✓ config.sh syntax is valid"
    fi
    VALIDATION_SUMMARY+=("config.sh")
  fi

  # check required agent_factory scripts
  local required_scripts=(
    "orchestrator"
    "run_orchestrator"
    "launchd_start.sh"
    "launchd_stop.sh"
    "launchd_status.sh"
    "monitor.sh"
  )

  local missing_scripts=()
  local non_executable_scripts=()
  for script in "${required_scripts[@]}"; do
    if [[ ! -f "$AGENT_FACTORY_DIR/$script" ]]; then
      missing_scripts+=("$script")
    elif [[ ! -x "$AGENT_FACTORY_DIR/$script" ]]; then
      non_executable_scripts+=("$script")
    fi
  done

  if [[ ${#missing_scripts[@]} -gt 0 ]]; then
    echo "ERROR: missing required agent_factory scripts:" >&2
    for script in "${missing_scripts[@]}"; do
      echo "  - $AGENT_FACTORY_DIR/$script" >&2
    done
    echo "  The agent_factory directory appears to be incomplete" >&2
    errors=$((errors + 1))
  fi

  if [[ ${#non_executable_scripts[@]} -gt 0 ]]; then
    echo "WARNING: some agent_factory scripts are not executable:" >&2
    for script in "${non_executable_scripts[@]}"; do
      echo "  - $AGENT_FACTORY_DIR/$script" >&2
      echo "    Fix: chmod +x $AGENT_FACTORY_DIR/$script" >&2
    done
    echo "  Attempting to fix automatically..." >&2
    for script in "${non_executable_scripts[@]}"; do
      if chmod +x "$AGENT_FACTORY_DIR/$script" 2>/dev/null; then
        echo "  ✓ Fixed: $script" >&2
      else
        echo "  ✗ Could not fix: $script (check permissions)" >&2
        warnings=$((warnings + 1))
      fi
    done
  fi

  echo

  if [[ $errors -gt 0 ]]; then
    echo >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "❌ Setup cannot continue. Please fix the errors above and run setup again." >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo >&2
    echo "Quick fixes (in order of priority):" >&2
    echo "  1. Install missing tools (see error messages above)" >&2
    echo "  2. Authenticate agent CLI: agent login" >&2
    echo "  3. Initialize git: git init" >&2
    echo "  4. Check write permissions: ls -ld ." >&2
    echo "  5. Verify you're in the project root: pwd" >&2
    echo >&2
    echo "After fixing errors, re-run: ./agent_factory/setup.sh" >&2
    exit 1
  fi

  if [[ $warnings -gt 0 ]]; then
    echo >&2
    echo "⚠️  $warnings warning(s) detected. Setup will continue, but some features may not work correctly." >&2
    echo
  fi

  # check for python dependencies file (optional but recommended)
  if [[ -f requirements.txt ]]; then
    echo "✓ requirements.txt found (Python dependencies file)"
    VALIDATION_SUMMARY+=("requirements.txt")
    
    # check if virtual environment exists
    if [[ -d .venv ]] && [[ -f .venv/bin/activate ]]; then
      echo "✓ Python virtual environment found (.venv/)"
      VALIDATION_SUMMARY+=("Python virtual environment")
      
      # check if key dependencies are installed (pytest and ruff for judge)
      if [[ -f .venv/bin/python ]]; then
        local venv_python="$REPO_ROOT/.venv/bin/python"
        
        # verify venv python is actually working
        if ! "$venv_python" --version >/dev/null 2>&1; then
          echo "WARNING: virtual environment Python is not functional" >&2
          echo "  Fix: recreate venv: rm -rf .venv && ./ops/bootstrap_python.sh" >&2
          warnings=$((warnings + 1))
        else
          # check pytest
          if "$venv_python" -c "import pytest" 2>/dev/null; then
            local pytest_version
            pytest_version="$("$venv_python" -c "import pytest; print(pytest.__version__)" 2>/dev/null || echo "unknown")"
            echo "✓ pytest is installed in virtual environment (version: $pytest_version)"
          else
            echo "WARNING: pytest not found in virtual environment (required for judge)" >&2
            echo "  Install with: ./ops/bootstrap_python.sh" >&2
            echo "  Or manually: $venv_python -m pip install pytest" >&2
            warnings=$((warnings + 1))
          fi
          
          # check ruff
          if "$venv_python" -c "import ruff" 2>/dev/null; then
            local ruff_version
            ruff_version="$("$venv_python" -c "import ruff; print(ruff.__version__)" 2>/dev/null || echo "unknown")"
            echo "✓ ruff is installed in virtual environment (version: $ruff_version)"
          else
            echo "WARNING: ruff not found in virtual environment (required for judge)" >&2
            echo "  Install with: ./ops/bootstrap_python.sh" >&2
            echo "  Or manually: $venv_python -m pip install ruff" >&2
            warnings=$((warnings + 1))
          fi

          # verify pip is available in venv
          if ! "$venv_python" -m pip --version >/dev/null 2>&1; then
            echo "WARNING: pip not available in virtual environment" >&2
            echo "  Fix: recreate venv: rm -rf .venv && ./ops/bootstrap_python.sh" >&2
            warnings=$((warnings + 1))
          fi
        fi
      fi
  else
    echo "ℹ️  Python virtual environment not found (.venv/)" >&2
    echo "   Create with: ./ops/bootstrap_python.sh" >&2
    echo "   This is required for judge validation (pytest, ruff)" >&2
    echo "   After creating, verify: .venv/bin/python -c 'import pytest, ruff'" >&2
  fi
else
  echo "ℹ️  requirements.txt not found (optional - create if you need Python dependencies)" >&2
  echo "   Note: Judge requires pytest and ruff for validation" >&2
  echo "   Create minimal requirements.txt:" >&2
  echo "     echo -e 'pytest\nruff' > requirements.txt" >&2
  echo "   Then run: ./ops/bootstrap_python.sh" >&2
fi
  
  # check for existing launchd jobs that might conflict (macOS only)
  if [[ "$(uname)" == "Darwin" ]] && command -v launchctl >/dev/null 2>&1; then
    local project_id_lower
    project_id_lower="$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_' | head -c 20)"
    local existing_jobs
    existing_jobs="$(launchctl list 2>/dev/null | grep -i "com\..*\.\(worker\|planner\|judge\|judge_trigger\)" || true)"
    
    if [[ -n "$existing_jobs" ]]; then
      echo "ℹ️  Existing launchd jobs detected (this is normal if agents are already running)" >&2
      echo "   To check status: ./ops/agent_factory/status.sh" >&2
      echo "   To stop existing jobs: ./ops/agent_factory/stop.sh" >&2
      echo "   To view all jobs: launchctl list | grep com\." >&2
    fi
  fi

  # add validated items to summary
  VALIDATION_SUMMARY+=("prerequisites")
}

# run validation
check_prerequisites

# detect if this is a fresh setup or existing setup
IS_FRESH_SETUP=0
PARTIAL_SETUP=0
FULLY_SETUP=0

# check for complete setup
local setup_components=(
  "Agent_profiles/primary_planner.md"
  "Agent_profiles/sub_planner.md"
  "Agent_profiles/worker.md"
  "Agent_profiles/judge.md"
  "goal.md"
  "tasks/queue"
  "tasks/subplanner_queue"
  "tasks/planner_queue"
  "tasks/judge_queue"
  "ops/agent_factory/start.sh"
  "ops/agent_factory/stop.sh"
  "ops/agent_factory/status.sh"
)

local missing_components=0
for component in "${setup_components[@]}"; do
  if [[ ! -e "$component" ]]; then
    missing_components=$((missing_components + 1))
  fi
done

if [[ $missing_components -eq 0 ]]; then
  FULLY_SETUP=1
elif [[ ! -d "Agent_profiles" ]] || [[ ! -d "tasks/queue" ]] || [[ ! -f "goal.md" ]]; then
  IS_FRESH_SETUP=1
  # check if this is a partial setup (some directories exist but not others)
  if [[ -d "Agent_profiles" ]] || [[ -d "tasks" ]] || [[ -f "goal.md" ]]; then
    PARTIAL_SETUP=1
  fi
fi

# create directories (idempotent)
echo "Creating directory structure..."

dir_errors=0
create_dir() {
  local dir="$1"
  local description="${2:-$dir}"
  
  if [[ -d "$dir" ]]; then
    echo "  ✓ $description already exists"
    return 0
  fi
  
  if mkdir -p "$dir" 2>/dev/null; then
    echo "  ✓ Created $description"
    SETUP_SUMMARY+=("$description")
    return 0
  else
    echo "  ✗ ERROR: failed to create directory: $dir" >&2
    echo "     Check write permissions in: $(pwd)" >&2
    echo "     Fix: chmod u+w ." >&2
    dir_errors=$((dir_errors + 1))
    return 1
  fi
}

create_dir "Agent_profiles" "Agent_profiles/"
create_dir "tasks/queue" "tasks/queue/"
create_dir "tasks/queue/processed" "tasks/queue/processed/"
create_dir "tasks/subplanner_queue" "tasks/subplanner_queue/"
create_dir "tasks/planner_queue" "tasks/planner_queue/"
create_dir "tasks/judge_queue" "tasks/judge_queue/"
create_dir ".agent_factory_state" ".agent_factory_state/"
create_dir "logs/agent_runs" "logs/agent_runs/"
create_dir "ops/agent_factory" "ops/agent_factory/"

if [[ $dir_errors -gt 0 ]]; then
  echo >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "❌ ERROR: Failed to create $dir_errors directory(ies)" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "  Current directory: $(pwd)" >&2
  echo "  Check write permissions:" >&2
  echo "    ls -ld ." >&2
  echo "    chmod u+w .  # if needed" >&2
  echo "  Or run setup from a directory where you have write access" >&2
  exit 1
fi

echo

# enforce LF line endings to avoid bash parsing errors on macOS (idempotent)
if [[ ! -f .gitattributes ]]; then
  cat > .gitattributes <<'EOF'
*.sh text eol=lf
*.md text eol=lf
*.yaml text eol=lf
*.yml text eol=lf
EOF
  echo "✓ Created .gitattributes (enforces LF endings for .sh/.md/.yml/.yaml)"
else
  echo "✓ .gitattributes already exists"
fi

# copy template profiles (4-agent system, idempotent)
echo "Setting up agent profiles..."

copy_profile() {
  local template="$1"
  local target="$2"
  local name="$3"
  local error_occurred=0
  
  if [[ ! -f "$target" ]]; then
    if [[ ! -f "$AGENT_FACTORY_DIR/$template" ]]; then
      echo "  ✗ ERROR: template not found: $AGENT_FACTORY_DIR/$template" >&2
      echo "     Fix: ensure agent_factory directory is complete" >&2
      error_occurred=1
    elif cp "$AGENT_FACTORY_DIR/$template" "$target" 2>/dev/null; then
      echo "  ✓ Created $name"
      SETUP_SUMMARY+=("$name")
    else
      echo "  ✗ ERROR: failed to create $name" >&2
      echo "     Fix: check write permissions in Agent_profiles/" >&2
      error_occurred=1
    fi
  else
    echo "  ✓ $name already exists"
  fi
  
  return $error_occurred
}

profile_errors=0
copy_profile "Agent_profiles/template_primary_planner.md" \
  "Agent_profiles/primary_planner.md" \
  "Agent_profiles/primary_planner.md" || profile_errors=$((profile_errors + 1))

copy_profile "Agent_profiles/template_sub_planner.md" \
  "Agent_profiles/sub_planner.md" \
  "Agent_profiles/sub_planner.md" || profile_errors=$((profile_errors + 1))

copy_profile "Agent_profiles/template_worker.md" \
  "Agent_profiles/worker.md" \
  "Agent_profiles/worker.md" || profile_errors=$((profile_errors + 1))

copy_profile "Agent_profiles/template_judge.md" \
  "Agent_profiles/judge.md" \
  "Agent_profiles/judge.md" || profile_errors=$((profile_errors + 1))

if [[ $profile_errors -gt 0 ]]; then
  echo >&2
  echo "ERROR: failed to create $profile_errors profile file(s)" >&2
  exit 1
fi

echo

# copy goal template (idempotent)
if [[ ! -f goal.md ]]; then
  if [[ ! -f "$AGENT_FACTORY_DIR/goal_template.md" ]]; then
    echo "ERROR: goal template not found: $AGENT_FACTORY_DIR/goal_template.md" >&2
    echo "  Fix: ensure agent_factory directory is complete" >&2
    exit 1
  fi
  
  if cp "$AGENT_FACTORY_DIR/goal_template.md" goal.md 2>/dev/null; then
    echo "✓ Created goal.md (edit with your project objective and success criteria)"
    SETUP_SUMMARY+=("goal.md")
  else
    echo "ERROR: failed to create goal.md" >&2
    echo "  Fix: check write permissions in: $(pwd)" >&2
    exit 1
  fi
else
  echo "✓ goal.md already exists"
fi
echo

# create initial planner ticket so background runs can start immediately (idempotent)
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
  echo "✓ Created tasks/planner_queue/10_initial_planning.md"
else
  echo "✓ Planner queue already has tickets"
fi
echo

# create repo-local ops commands (thin wrappers, idempotent)
echo "Setting up ops commands..."

ops_errors=0
create_ops_script() {
  local script_path="$1"
  local script_content="$2"
  local script_name="$(basename "$script_path")"
  
  if [[ ! -f "$script_path" ]]; then
    if echo "$script_content" > "$script_path" 2>/dev/null && chmod +x "$script_path" 2>/dev/null; then
      echo "  ✓ Created $script_name"
      SETUP_SUMMARY+=("$script_name")
      return 0
    else
      echo "  ✗ ERROR: failed to create $script_path" >&2
      echo "     Check write permissions in: $(dirname "$script_path")" >&2
      echo "     Fix: chmod u+w $(dirname "$script_path")" >&2
      ops_errors=$((ops_errors + 1))
      return 1
    fi
  else
    echo "  ✓ $script_name already exists"
    return 0
  fi
}

create_ops_script "ops/agent_factory/start.sh" '#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

exec ./agent_factory/launchd_start.sh "$@"' || true

create_ops_script "ops/agent_factory/monitor.sh" '#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

exec ./agent_factory/monitor.sh --launchd "$@"' || true

create_ops_script "ops/agent_factory/stop.sh" '#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

exec ./agent_factory/launchd_stop.sh "$@"' || true

create_ops_script "ops/agent_factory/status.sh" '#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

exec ./agent_factory/launchd_status.sh "$@"' || true

create_ops_script "ops/agent_factory/stop_remove.sh" '#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

exec ./agent_factory/launchd_stop.sh --remove "$@"' || true

create_ops_script "ops/bootstrap_python.sh" '#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is not installed or not on PATH" >&2
  exit 1
fi

venv_dir="${repo_root}/.venv"

if [[ ! -d "$venv_dir" ]]; then
  echo "Creating virtual environment at .venv/" >&2
  python3 -m venv "$venv_dir"
fi

# shellcheck disable=SC1091
source "${venv_dir}/bin/activate"

python -m pip install --upgrade pip

if [[ -f "${repo_root}/requirements.txt" ]]; then
  echo "Installing project requirements from requirements.txt" >&2
  python -m pip install -r "${repo_root}/requirements.txt"
fi

echo "Ensuring judge dependencies are installed (pytest, ruff)" >&2
python -m pip install pytest ruff

echo "✅ Python environment ready: ${venv_dir}" >&2
python -m pytest --version >/dev/null 2>&1 || true
ruff --version >/dev/null 2>&1 || true' || true

# verify ops scripts are executable and functional
if [[ $ops_errors -eq 0 ]]; then
  local ops_scripts=(
    "ops/agent_factory/start.sh"
    "ops/agent_factory/monitor.sh"
    "ops/agent_factory/stop.sh"
    "ops/agent_factory/status.sh"
  )
  
  local missing_exec=0
  local syntax_errors=0
  local functional_errors=0
  
  for script in "${ops_scripts[@]}"; do
    if [[ -f "$script" ]]; then
      # ensure executable
      if [[ ! -x "$script" ]]; then
        echo "  ⚠️  WARNING: $script is not executable (fixing...)" >&2
        chmod +x "$script" 2>/dev/null || missing_exec=$((missing_exec + 1))
      fi
      
      # verify bash syntax
      if ! bash -n "$script" 2>/dev/null; then
        echo "  ⚠️  WARNING: $script has syntax errors" >&2
        syntax_errors=$((syntax_errors + 1))
      fi
      
      # verify script can find repo root (for scripts that navigate)
      if [[ "$script" == "ops/agent_factory/status.sh" ]] || [[ "$script" == "ops/agent_factory/stop.sh" ]]; then
        # these scripts navigate to repo root, verify they can do so
        local test_output
        if test_output="$(bash "$script" --help 2>&1)" || test_output="$(bash "$script" 2>&1)"; then
          # script executed without fatal errors (may have usage output, that's ok)
          :
        else
          echo "  ⚠️  WARNING: $script may have issues finding repo root" >&2
          functional_errors=$((functional_errors + 1))
        fi
      fi
    fi
  done
  
  if [[ $missing_exec -gt 0 ]]; then
    echo "  ⚠️  WARNING: Could not make $missing_exec script(s) executable" >&2
  fi
  
  if [[ $syntax_errors -gt 0 ]]; then
    echo "  ⚠️  WARNING: $syntax_errors script(s) have syntax errors" >&2
    echo "     Run: bash -n ops/agent_factory/*.sh" >&2
  elif [[ $functional_errors -gt 0 ]]; then
    echo "  ⚠️  WARNING: $functional_errors script(s) may have functional issues" >&2
    echo "     Test manually: bash ops/agent_factory/status.sh" >&2
  elif [[ $missing_exec -eq 0 ]]; then
    echo "  ✓ All ops scripts are executable and syntactically valid"
  fi
fi

if [[ $ops_errors -gt 0 ]]; then
  echo >&2
  echo "⚠️  WARNING: Failed to create $ops_errors ops script(s)" >&2
  echo "  You can still use agent_factory scripts directly:" >&2
  echo "    ./agent_factory/launchd_start.sh" >&2
  echo "    ./agent_factory/monitor.sh" >&2
  echo "    ./agent_factory/launchd_stop.sh" >&2
  echo "  Fix: chmod u+w ops/agent_factory/" >&2
  echo
fi

echo

# verification function - test that setup actually works
verify_setup() {
  local verification_errors=0
  local verification_warnings=0
  
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Verifying Setup..."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  
  # verify ops scripts are accessible
  local ops_scripts=(
    "ops/agent_factory/start.sh"
    "ops/agent_factory/stop.sh"
    "ops/agent_factory/status.sh"
    "ops/agent_factory/monitor.sh"
  )
  
  local missing_ops=0
  for script in "${ops_scripts[@]}"; do
    if [[ ! -f "$script" ]]; then
      if [[ $missing_ops -eq 0 ]]; then
        echo "⚠️  WARNING: Some ops scripts are missing:" >&2
        missing_ops=1
      fi
      echo "  Missing: $script" >&2
      verification_warnings=$((verification_warnings + 1))
    elif [[ ! -x "$script" ]]; then
      echo "⚠️  WARNING: $script is not executable (fixing...)" >&2
      chmod +x "$script" 2>/dev/null || verification_warnings=$((verification_warnings + 1))
    fi
  done
  
  # verify agent profiles exist
  local required_profiles=(
    "Agent_profiles/primary_planner.md"
    "Agent_profiles/sub_planner.md"
    "Agent_profiles/worker.md"
    "Agent_profiles/judge.md"
  )
  
  local missing_profiles=0
  for profile in "${required_profiles[@]}"; do
    if [[ ! -f "$profile" ]]; then
      if [[ $missing_profiles -eq 0 ]]; then
        echo "⚠️  WARNING: Some agent profiles are missing:" >&2
        missing_profiles=1
      fi
      echo "  Missing: $profile" >&2
      verification_warnings=$((verification_warnings + 1))
    fi
  done
  
  # verify goal.md exists
  if [[ ! -f goal.md ]]; then
    echo "⚠️  WARNING: goal.md not found (required for agents)" >&2
    echo "  Fix: cp agent_factory/goal_template.md goal.md" >&2
    verification_warnings=$((verification_warnings + 1))
  fi
  
  # verify queue directories exist
  local required_queues=(
    "tasks/queue"
    "tasks/subplanner_queue"
    "tasks/planner_queue"
    "tasks/judge_queue"
  )
  
  local missing_queues=0
  for queue in "${required_queues[@]}"; do
    if [[ ! -d "$queue" ]]; then
      if [[ $missing_queues -eq 0 ]]; then
        echo "⚠️  WARNING: Some queue directories are missing:" >&2
        missing_queues=1
      fi
      echo "  Missing: $queue" >&2
      verification_warnings=$((verification_warnings + 1))
    fi
  done
  
  # verify agent CLI is still accessible (quick test)
  if command -v agent >/dev/null 2>&1; then
    if ! agent --help >/dev/null 2>&1 && ! agent status >/dev/null 2>&1; then
      echo "⚠️  WARNING: agent CLI may not be working correctly" >&2
      echo "  Test manually: agent status" >&2
      verification_warnings=$((verification_warnings + 1))
    fi
  fi
  
  # verify config.sh can be sourced
  if [[ -f "$AGENT_FACTORY_DIR/config.sh" ]]; then
    if ! bash -c "source '$AGENT_FACTORY_DIR/config.sh' && echo 'ok'" >/dev/null 2>&1; then
      echo "⚠️  WARNING: config.sh cannot be sourced (may have errors)" >&2
      echo "  Check: bash -n $AGENT_FACTORY_DIR/config.sh" >&2
      verification_warnings=$((verification_warnings + 1))
    fi
  fi
  
  if [[ $verification_warnings -eq 0 ]]; then
    echo "✓ All setup components verified successfully"
  else
    echo "⚠️  $verification_warnings warning(s) detected during verification"
  fi
  
  echo
  return $verification_errors
}

# run verification
verify_setup || true

# setup summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ Setup complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

if [[ $FULLY_SETUP -eq 1 ]]; then
  echo "✓ Complete setup detected - all components verified and up to date"
  echo "   Your agent_factory is ready to use!"
elif [[ $IS_FRESH_SETUP -eq 1 ]]; then
  if [[ $PARTIAL_SETUP -eq 1 ]]; then
    echo "⚠️  Partial setup detected - some components exist, completing setup"
    echo "   This is normal if you're resuming setup or updating agent_factory"
  else
    echo "🎉 Fresh setup detected - all components initialized"
  fi
else
  echo "ℹ️  Existing setup detected - verified and updated as needed"
fi
echo

if [[ ${#VALIDATION_SUMMARY[@]} -gt 0 ]]; then
  echo "Validated:"
  for item in "${VALIDATION_SUMMARY[@]}"; do
    echo "  ✓ $item"
  done
  echo
fi

if [[ ${#SETUP_SUMMARY[@]} -gt 0 ]]; then
  echo "Created/Updated:"
  for item in "${SETUP_SUMMARY[@]}"; do
    echo "  ✓ $item"
  done
  echo
fi

# check if goal.md needs editing
goal_needs_editing=0
if [[ -f goal.md ]]; then
  if grep -q "YOUR_PROJECT_OBJECTIVE\|TODO\|Example:" goal.md 2>/dev/null; then
    goal_needs_editing=1
  fi
fi

# check if python venv exists
python_venv_exists=0
if [[ -d .venv ]] && [[ -f .venv/bin/activate ]]; then
  python_venv_exists=1
fi

# check if requirements.txt exists
requirements_exists=0
if [[ -f requirements.txt ]]; then
  requirements_exists=1
fi

# prepare next steps summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "NEXT STEPS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "Follow these steps in order to complete your agent_factory setup:"
echo
echo "💡 TIP: You can re-run this script anytime to verify your setup: ./agent_factory/setup.sh"
echo

if [[ $FULLY_SETUP -eq 1 ]]; then
  echo "✅ Your setup is complete! You can start using agent_factory immediately."
  echo
  echo "Quick start:"
  echo "  1. Start agents: ./ops/agent_factory/start.sh"
  echo "  2. Monitor progress: ./ops/agent_factory/monitor.sh"
  echo "  3. Check status: ./ops/agent_factory/status.sh"
  echo
  echo "If you need to customize your setup, see the sections below."
  echo
fi

next_step_num=1

if [[ $goal_needs_editing -eq 1 ]]; then
  echo "⚠️  STEP $next_step_num (REQUIRED): Configure your project goal"
  echo "   Action: Edit goal.md with your project objective and success criteria"
  echo "   Command: vim goal.md  # or: code goal.md, nano goal.md, etc."
  echo "   This file is the source of truth - agents check it on every run"
  echo "   Sections to fill:"
  echo "     - current objective: what you want to achieve"
  echo "     - success criteria: measurable checkboxes"
  echo "     - constraints: project-specific rules"
  echo "     - current status: current phase/milestone"
  echo "   Template: See agent_factory/goal_template.md for structure"
  echo "   Quick edit example:"
  echo "     vim goal.md  # edit the file"
  echo "     # Replace 'YOUR_PROJECT_OBJECTIVE' with your actual goal"
  echo "     # Replace 'TODO' items with specific success criteria"
  echo "   Verify setup: cat goal.md | head -20"
  echo "   Verify no placeholders remain: grep -i 'TODO\\|YOUR_PROJECT\\|EXAMPLE' goal.md"
  echo "   After editing, re-run this script to verify: ./agent_factory/setup.sh"
  echo "   💡 TIP: Keep goal.md focused and specific - agents read it on every task"
  echo
  next_step_num=$((next_step_num + 1))
else
  echo "✓ STEP $next_step_num: Project goal configured (goal.md exists)"
  echo "   [OPTIONAL] Review goal.md to ensure it matches your project"
  echo "   Command: cat goal.md | head -20"
  echo "   Edit if needed: vim goal.md"
  echo "   Verify: grep -i 'TODO\\|YOUR_PROJECT\\|EXAMPLE' goal.md  # should return nothing"
  echo
  next_step_num=$((next_step_num + 1))
fi

if [[ $requirements_exists -eq 1 ]]; then
  if [[ $python_venv_exists -eq 0 ]]; then
    echo "⚠️  STEP $next_step_num (REQUIRED): Install Python dependencies"
    echo "   Action: Create virtual environment and install dependencies"
    echo "   Command: ./ops/bootstrap_python.sh"
    echo "   What it does:"
    echo "     - Creates .venv/ virtual environment"
    echo "     - Installs packages from requirements.txt"
    echo "     - Verifies pytest and ruff are available (required for judge)"
    echo "   Verify after install:"
    echo "     .venv/bin/python -c 'import pytest, ruff; print(\"✓ Python environment ready\")'"
    echo "   Troubleshooting:"
    echo "     - Python version too old: python3 --version (need 3.8+)"
    echo "       Fix: brew install python3  # macOS, or use your package manager"
    echo "     - Venv creation fails: python3 -m venv .venv"
    echo "       Fix: Check python3 is installed: which python3"
    echo "     - Pip install fails: .venv/bin/pip install -r requirements.txt"
    echo "       Fix: Check requirements.txt format and network connectivity"
    echo "     - Missing dependencies: check requirements.txt exists and is readable"
    echo "       Fix: cat requirements.txt"
    echo "     - Permission errors: ensure you have write access to current directory"
    echo "       Fix: ls -ld . && chmod u+w ."
    echo "   After install, verify: ./ops/bootstrap_python.sh  # should show success"
    echo "   💡 TIP: Judge agent requires pytest and ruff - ensure they're in requirements.txt"
    echo
    next_step_num=$((next_step_num + 1))
  else
    # check if dependencies are actually installed
    local deps_ok=1
    local missing_deps=()
    if [[ -f .venv/bin/python ]]; then
      if ! .venv/bin/python -c "import pytest" 2>/dev/null; then
        deps_ok=0
        missing_deps+=("pytest")
      fi
      if ! .venv/bin/python -c "import ruff" 2>/dev/null; then
        deps_ok=0
        missing_deps+=("ruff")
      fi
    fi
    
    if [[ $deps_ok -eq 1 ]]; then
      echo "✓ STEP $next_step_num: Python dependencies installed (.venv exists with pytest & ruff)"
      echo "   [OPTIONAL] Update dependencies: ./ops/bootstrap_python.sh"
      echo "   Verify: .venv/bin/python -c 'import pytest, ruff; print(\"ok\")'"
    else
      echo "⚠️  STEP $next_step_num: Python virtual environment exists but missing dependencies"
      echo "   Missing: ${missing_deps[*]}"
      echo "   Run: ./ops/bootstrap_python.sh"
      echo "   Or manually: .venv/bin/pip install ${missing_deps[*]}"
      echo "   This will install pytest and ruff (required for judge validation)"
      echo "   Verify after install: .venv/bin/python -c 'import pytest, ruff; print(\"ok\")'"
    fi
    echo
    next_step_num=$((next_step_num + 1))
  fi
else
  echo "ℹ️  STEP $next_step_num: Python dependencies (skipped - no requirements.txt found)"
  echo "   If you need Python dependencies, create requirements.txt and run:"
  echo "     ./ops/bootstrap_python.sh"
  echo "   Note: Judge agent requires pytest and ruff for validation"
  echo "   Minimum requirements.txt should include:"
  echo "     pytest"
  echo "     ruff"
  echo "   Create requirements.txt:"
  echo "     echo -e 'pytest\nruff' > requirements.txt"
  echo
  next_step_num=$((next_step_num + 1))
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "OPTIONAL: Customize agent profiles"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   Agent profiles control agent behavior. Default profiles are ready to use."
echo "   Customize if needed:"
echo "     - Agent_profiles/primary_planner.md  (high-level planning)"
echo "     - Agent_profiles/sub_planner.md      (task breakdown)"
echo "     - Agent_profiles/worker.md           (task execution)"
echo "     - Agent_profiles/judge.md            (validation & commits)"
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "QUICK START COMMANDS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "⚠️  IMPORTANT: Before starting background jobs, test with a single task first!"
echo
echo "0. Quick verification (test that setup works - RECOMMENDED FIRST STEP):"
echo "   # Verify all components are accessible"
echo "   ./ops/agent_factory/status.sh  # should show status (may show 'not running' if not started)"
echo "   ls -la ops/agent_factory/*.sh  # should show all scripts with execute permissions"
echo "   test -f goal.md && echo '✓ goal.md exists' || echo '⚠️  goal.md missing'"
echo "   test -d tasks/queue && echo '✓ queue directories exist' || echo '⚠️  queue directories missing'"
echo "   command -v agent >/dev/null && agent status && echo '✓ agent CLI working' || echo '⚠️  agent CLI issue'"
echo
echo "1. Test the setup (run a single task manually - RECOMMENDED SECOND STEP):"
echo "   # Create a simple test task"
echo "   cat > tasks/queue/001_test_setup.md << 'EOF'"
echo "# Task: Test agent factory setup"
echo ""
echo "## Objective"
echo "Verify agent factory is working correctly by creating a test file."
echo ""
echo "## File Paths"
echo "- Create: \`test_agent_factory.txt\` (content: 'Agent factory setup successful!')"
echo "EOF"
echo "   # Run it once"
echo "   ./agent_factory/run_orchestrator \\"
echo "     --profile Agent_profiles/worker.md \\"
echo "     --goal-file goal.md \\"
echo "     --queue-dir tasks/queue \\"
echo "     --max 1 \\"
echo "     --once"
echo "   # Verify task completed"
echo "   ls tasks/queue/processed/ | grep 001_test"
echo "   # Check if test file was created"
echo "   cat test_agent_factory.txt"
echo "   # If successful, you can delete the test file: rm test_agent_factory.txt"
echo
echo "2. Start the agent factory (background, survives reboot):"
  echo "   ./ops/agent_factory/start.sh"
  echo "   # Verify agents are running"
  echo "   ./ops/agent_factory/status.sh"
  echo "   # If status shows 'not running', check logs:"
  echo "   ./agent_factory/watch_logs.sh"
  echo "   # Common issues:"
  echo "   #   - Agent CLI not in PATH: add to ~/.zshrc or ~/.bashrc"
  echo "   #   - Authentication failed: agent login or use keychain"
  echo "   #   - Python venv missing: ./ops/bootstrap_python.sh"
echo
echo "3. Monitor progress:"
echo "   ./ops/agent_factory/monitor.sh    # watch progress (auto-refresh every 2s)"
echo "   ./ops/agent_factory/status.sh     # check status (one-time)"
echo "   ./ops/agent_factory/stop.sh       # stop all agents"
echo
echo "4. Verify setup is working:"
echo "   # Check ops scripts are executable"
echo "   ls -la ops/agent_factory/*.sh"
echo "   # All scripts should show 'x' (executable) permission"
  echo "   # Check agent CLI is accessible and authenticated"
  echo "   command -v agent && agent status"
  echo "   # Should show agent path and authentication status"
  echo "   # Verify agent CLI is in PATH (important for background jobs)"
  echo "   echo \$PATH | grep -q .local/bin && echo '✓ agent CLI path found' || echo '⚠️  add to PATH'"
  echo "   # Check Python environment (if requirements.txt exists)"
if [[ $requirements_exists -eq 1 ]]; then
  if [[ $python_venv_exists -eq 1 ]]; then
    echo "   .venv/bin/python -c 'import pytest, ruff; print(\"✓ Python environment ready\")'"
    echo "   # Should print success message"
  else
    echo "   # Python venv not found - run: ./ops/bootstrap_python.sh"
    echo "   # This is required for judge validation (pytest, ruff)"
  fi
else
  echo "   # No requirements.txt found - Python dependencies not required"
  echo "   # Note: Judge still requires pytest and ruff for validation"
  echo "   # Create requirements.txt with pytest and ruff if you plan to use judge"
fi
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "DOCUMENTATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📚 Full guide:      agent_factory/README.md"
echo "  🔧 Troubleshooting: agent_factory/TROUBLESHOOTING.md"
echo "  🚀 Quick start:     FIRST_START.md"
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "IMPORTANT NOTES"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "• Setup is idempotent - safe to run multiple times"
echo "• Re-run this script anytime to verify or update your setup: ./agent_factory/setup.sh"
echo "• Project name detected: $PROJECT_NAME"
if [[ -d .git ]]; then
  local git_remote
  git_remote="$(git config --get remote.origin.url 2>/dev/null || true)"
  if [[ -n "$git_remote" ]]; then
    echo "• Git remote: $git_remote"
  fi
fi
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TROUBLESHOOTING TIPS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "If you encounter issues, check these in order (most common first):"
echo
echo "  1. Agent CLI authentication: agent status"
echo "     → Should show 'authenticated' or 'logged in'"
echo "     → Fix: agent login"
echo "     → Or use keychain (recommended for background jobs):"
echo "       security add-generic-password -a \"\$USER\" -s \"cursor_cli_api_key\" -w"
echo "     → Get API key from: https://cursor.com/settings/api"
echo "     → Verify: agent status"
echo
echo "  2. Agent CLI installation: command -v agent"
echo "     → Should show path to agent binary"
echo "     → Fix: curl -fsS https://cursor.com/install | bash"
echo "     → Then add to PATH: export PATH=\"\$HOME/.local/bin:\$PATH\""
echo "     → Add to ~/.zshrc or ~/.bashrc for persistence:"
echo "       echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
echo "     → Verify: command -v agent"
echo
echo "  3. Python version: python3 --version"
echo "     → Should be 3.8 or higher"
echo "     → Fix: brew install python3 (macOS) or update Python"
echo "     → Verify: python3 --version"
echo "     → If multiple Python versions: which python3"
echo
echo "  4. Git repository: git status"
echo "     → Should show repository status"
echo "     → Fix: git init (if not a git repo)"
echo "     → Then: git add . && git commit -m 'Initial commit'"
echo "     → Optional: git remote add origin <your-repo-url>"
echo
echo "  5. Write permissions: ls -ld ."
echo "     → Should show write permissions (drwx...)"
echo "     → Fix: chmod u+w ."
echo "     → Or check if you're in the right directory: pwd"
echo "     → Verify: touch .test_write && rm .test_write"
echo
echo "  6. Config file syntax: bash -n agent_factory/config.sh"
echo "     → Should exit with code 0 (no output)"
echo "     → Fix: check config.sh for syntax errors"
echo "     → Common issues: unclosed quotes, missing semicolons"
echo "     → Test: bash -n agent_factory/config.sh"
echo
echo "  7. Script location: pwd"
echo "     → Should be your project root directory"
echo "     → Verify: ls agent_factory/setup.sh"
echo "     → Fix: cd to project root, then run: ./agent_factory/setup.sh"
if [[ $requirements_exists -eq 1 ]]; then
  echo
  echo "  8. Python virtual environment: [[ -d .venv ]] && echo 'exists' || echo 'missing'"
  echo "     → Should show 'exists'"
  echo "     → Fix: ./ops/bootstrap_python.sh"
  echo "     → Verify: .venv/bin/python --version"
  echo
  echo "  9. Python dependencies: .venv/bin/python -c 'import pytest, ruff' 2>&1"
  echo "     → Should exit with code 0"
  echo "     → Fix: .venv/bin/pip install -r requirements.txt"
  echo "     → Or: ./ops/bootstrap_python.sh"
  echo
  echo "  10. Disk space: df -h ."
  echo "      → Should show at least 100MB available"
  echo "      → Fix: free up disk space if needed"
fi
echo
echo "💡 TIP: Setup is idempotent - safe to run multiple times"
echo "   Re-run this script anytime to verify or update your setup:"
echo "     ./agent_factory/setup.sh"
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "VERIFICATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "To verify your setup is working correctly, run these commands:"
echo
echo "  1. Check ops scripts are accessible:"
echo "     ls -la ops/agent_factory/*.sh"
echo "     → Should show all scripts with execute permissions"
echo
echo "  2. Test status script (safest test, doesn't start anything):"
echo "     ./ops/agent_factory/status.sh"
echo "     → Should show agent status (may show 'not running' if not started yet)"
echo
echo "  3. Verify agent CLI is working:"
echo "     command -v agent && agent status"
echo "     → Should show agent path and authentication status"
echo
echo "  4. Quick test (optional - creates a test task and runs it once):"
echo "     # Create a simple test task"
echo "     cat > tasks/queue/001_test_setup.md << 'EOF'"
echo "# Task: Test agent factory setup"
echo ""
echo "## Objective"
echo "Verify agent factory is working correctly by creating a test file."
echo ""
echo "## File Paths"
echo "- Create: \`test_agent_factory.txt\` (content: 'Agent factory setup successful!')"
echo "EOF"
echo "     # Run it once manually"
echo "     ./agent_factory/run_orchestrator \\"
echo "       --profile Agent_profiles/worker.md \\"
echo "       --goal-file goal.md \\"
echo "       --queue-dir tasks/queue \\"
echo "       --max 1 \\"
echo "       --once"
echo "     # Verify task completed"
echo "     ls tasks/queue/processed/ | grep 001_test"
echo "     # Check if test file was created"
echo "     cat test_agent_factory.txt 2>/dev/null || echo 'Test file not created (check logs)'"
echo "     # Clean up test file (optional)"
echo "     rm -f test_agent_factory.txt"
echo
if [[ $requirements_exists -eq 1 ]]; then
  if [[ $python_venv_exists -eq 1 ]]; then
    echo "  4. Verify Python environment:"
    echo "     .venv/bin/python -c 'import pytest, ruff; print(\"✓ Python environment ready\")'"
    echo "     → Should print success message"
  else
    echo "  4. Setup Python environment (if needed):"
    echo "     ./ops/bootstrap_python.sh"
  fi
fi
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SETUP COMPLETE - QUICK REFERENCE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "✅ Setup is complete! Your agent_factory is ready to use."
echo
echo "📋 Essential Commands:"
echo "   Start agents:     ./ops/agent_factory/start.sh"
echo "   Monitor progress: ./ops/agent_factory/monitor.sh"
echo "   Check status:    ./ops/agent_factory/status.sh"
echo "   Stop agents:     ./ops/agent_factory/stop.sh"
echo
echo "📚 Documentation:"
echo "   - agent_factory/README.md (complete documentation)"
echo "   - agent_factory/TROUBLESHOOTING.md (troubleshooting guide)"
echo "   - FIRST_START.md (quick start guide)"
echo
echo "💡 Next Steps:"
echo "   1. Review and customize goal.md (if not already done)"
echo "   2. Test with a single task (see verification section above)"
echo "   3. Start agents: ./ops/agent_factory/start.sh"
echo "   4. Monitor progress: ./ops/agent_factory/monitor.sh --watch"
echo
echo "🔄 Re-run this script anytime to verify setup:"
echo "   ./agent_factory/setup.sh"
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "QUICK VERIFICATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "Run this command to quickly verify your setup is working:"
echo
echo "  ./ops/agent_factory/status.sh && \\"
echo "  test -f goal.md && \\"
echo "  test -d tasks/queue && \\"
echo "  command -v agent >/dev/null && agent status >/dev/null && \\"
echo "  echo '✅ Setup verification passed!' || echo '⚠️  Some checks failed - see above'"
echo
echo "If all checks pass, you're ready to start using agent_factory!"
echo
