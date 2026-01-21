#!/usr/bin/env bash
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

packages=(pytest ruff)
if [[ -f "${repo_root}/requirements.txt" ]]; then
  echo "Installing project requirements from requirements.txt" >&2
  python -m pip install -r "${repo_root}/requirements.txt"
fi

echo "Ensuring judge dependencies are installed (pytest, ruff)" >&2
python -m pip install "${packages[@]}"

echo "✅ Python environment ready: ${venv_dir}" >&2
python -m pytest --version >/dev/null 2>&1 || true
ruff --version >/dev/null 2>&1 || true
