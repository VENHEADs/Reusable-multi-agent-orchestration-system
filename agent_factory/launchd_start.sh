#!/usr/bin/env bash
set -euo pipefail

# creates and loads launchd jobs for the repo-local agent factory.
#
# usage:
#   ./agent_factory/launchd_start.sh [--project-id <id>] [--model <name>] [--fallback-model <name>]
#                                 [--use-keychain] [--keychain-service <name>] [--keychain-account <name>]
#
# notes:
# - plists are written to: ~/Library/LaunchAgents/
# - jobs are loaded into: gui/$(id -u)

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# load centralized configuration
AGENT_FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${AGENT_FACTORY_DIR}/config.sh" ]]; then
  source "${AGENT_FACTORY_DIR}/config.sh"
fi

project_id=""
model=""
fallback_model="${FALLBACK_MODEL:-}"
use_keychain="0"
keychain_service="cursor_cli_api_key__disabled"
keychain_account="${USER:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      project_id="$2"
      shift 2
      ;;
    --model)
      model="$2"
      shift 2
      ;;
    --fallback-model)
      fallback_model="$2"
      shift 2
      ;;
    --use-keychain)
      use_keychain="1"
      shift
      ;;
    --keychain-service)
      keychain_service="$2"
      shift 2
      ;;
    --keychain-account)
      keychain_account="$2"
      shift 2
      ;;
    -h|--help)
      echo "usage: $0 [--project-id <id>] [--model <name>] [--fallback-model <name>] [--use-keychain] [--keychain-service <name>] [--keychain-account <name>]" >&2
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$project_id" ]]; then
  project_id="$(basename "$repo_root" | tr -cs 'A-Za-z0-9' '_' | tr '[:upper:]' '[:lower:]' | sed -E 's/^_+|_+$//g')"
fi

launch_agents_dir="$HOME/Library/LaunchAgents"
mkdir -p "$launch_agents_dir"

user_id="$(id -u)"

write_plist() {
  local role="$1"
  local profile="$2"
  local queue_dir="$3"
  local label="com.${project_id}.agent_factory.${role}"
  local plist_path="${launch_agents_dir}/${label}.plist"

  local model_flag=""
  if [[ -n "$model" ]]; then
    model_flag="--model ${model}"
  fi

  local fallback_env=""
  if [[ -n "$fallback_model" ]]; then
    fallback_env="      <key>FALLBACK_MODEL</key>
      <string>${fallback_model}</string>"
  fi

  local keychain_env=""
  if [[ "$use_keychain" == "0" ]]; then
    # default: avoid keychain keys so background jobs always use `agent login` auth.
    # this prevents accidentally using an old api key from another account.
    keychain_env="      <key>CURSOR_KEYCHAIN_SERVICE</key>
      <string>${keychain_service}</string>
      <key>CURSOR_KEYCHAIN_ACCOUNT</key>
      <string>${keychain_account}</string>"
  elif [[ -n "$keychain_account" ]]; then
    # if user opted into keychain but wants a specific account, pin it.
    keychain_env="      <key>CURSOR_KEYCHAIN_ACCOUNT</key>
      <string>${keychain_account}</string>"
  fi

  # timestamp each line written to logs/<role>.out and logs/<role>.err.
  local cmd
  local sleep_secs="${ORCHESTRATOR_SLEEP_SECS}"
  if [[ "$role" == "judge" ]]; then
    # deterministic judge: consumes judge_queue and commits when checks pass
    cmd="cd \"${repo_root}\"; exec \"${repo_root}/agent_factory/judge_daemon.sh\" 1> >( python3 \"${repo_root}/agent_factory/log_prefix.py\" >> \"${repo_root}/logs/${role}.out\" ) 2> >( python3 \"${repo_root}/agent_factory/log_prefix.py\" >> \"${repo_root}/logs/${role}.err\" )"
  else
    cmd="cd \"${repo_root}\"; exec \"${repo_root}/agent_factory/run_orchestrator\" --profile \"${repo_root}/Agent_profiles/${profile}\" --goal-file \"${repo_root}/goal.md\" --queue-dir \"${repo_root}/tasks/${queue_dir}\" --max 1 --sleep ${sleep_secs} ${model_flag} 1> >( python3 \"${repo_root}/agent_factory/log_prefix.py\" >> \"${repo_root}/logs/${role}.out\" ) 2> >( python3 \"${repo_root}/agent_factory/log_prefix.py\" >> \"${repo_root}/logs/${role}.err\" )"
  fi

  cat >"$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>-lc</string>
      <string>${cmd}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${repo_root}</string>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${repo_root}/logs/${role}.launchd_stdout</string>
    <key>StandardErrorPath</key>
    <string>${repo_root}/logs/${role}.launchd_stderr</string>
    <key>EnvironmentVariables</key>
    <dict>
      <key>HOME</key>
      <string>${HOME}</string>
      <key>USER</key>
      <string>${USER}</string>
      <key>PATH</key>
      <string>${repo_root}/.venv/bin:${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
${fallback_env}
${keychain_env}
    </dict>
  </dict>
</plist>
EOF
}

write_plist "primary_planner" "primary_planner.md" "planner_queue"
write_plist "sub_planner" "sub_planner.md" "subplanner_queue"
write_plist "worker" "worker.md" "queue"
write_plist "judge" "judge.md" "judge_queue"

# judge trigger is deterministic (non-ai) and runs continuously
label="com.${project_id}.agent_factory.judge_trigger"
plist_path="${launch_agents_dir}/${label}.plist"
cat >"$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
      <string>${repo_root}/agent_factory/judge_trigger.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${repo_root}</string>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${repo_root}/logs/judge_trigger.launchd_stdout</string>
    <key>StandardErrorPath</key>
    <string>${repo_root}/logs/judge_trigger.launchd_stderr</string>
    <key>EnvironmentVariables</key>
    <dict>
      <key>HOME</key>
      <string>${HOME}</string>
      <key>USER</key>
      <string>${USER}</string>
      <key>PATH</key>
      <string>${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
  </dict>
</plist>
EOF

# watchdog job (periodic checks, StartInterval only)
label="com.${project_id}.agent_factory.watchdog"
plist_path="${launch_agents_dir}/${label}.plist"
cat >"$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>-lc</string>
      <string>cd "${repo_root}"; exec "${repo_root}/agent_factory/watchdog.sh"</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${repo_root}</string>
    <key>StartInterval</key>
    <integer>${WATCHDOG_CHECK_INTERVAL_SECS}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${repo_root}/logs/watchdog.launchd_stdout</string>
    <key>StandardErrorPath</key>
    <string>${repo_root}/logs/watchdog.launchd_stderr</string>
    <key>EnvironmentVariables</key>
    <dict>
      <key>HOME</key>
      <string>${HOME}</string>
      <key>USER</key>
      <string>${USER}</string>
      <key>PATH</key>
      <string>${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
  </dict>
</plist>
EOF

for role in primary_planner sub_planner worker judge judge_trigger watchdog; do
  label="com.${project_id}.agent_factory.${role}"
  plist_path="${launch_agents_dir}/${label}.plist"

  # if a label was previously disabled, bootstrap can fail with I/O error.
  launchctl enable "gui/${user_id}/${label}" >/dev/null 2>&1 || true
  launchctl bootout "gui/${user_id}" "$plist_path" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/${user_id}" "$plist_path"

  if ! launchctl print "gui/${user_id}/${label}" >/dev/null 2>&1; then
    echo "failed to load launchd job: ${label}" >&2
    echo "plist: ${plist_path}" >&2
    exit 1
  fi
done

echo "started launchd jobs for project: ${project_id}"
echo "monitor: ./agent_factory/monitor.sh --watch"
