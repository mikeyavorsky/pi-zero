#!/usr/bin/env bash
#
# OTA-updatable run logic. Invoked by the bootstrap as:  run.sh <VENV_DIR>
# Everything here is pulled fresh from git on each run, so editing this file
# (or the SCRIPT it points at, or requirements.txt) and pushing is enough to
# change what the Pi does — no re-provisioning needed.
set -euo pipefail

VENV_DIR="${1:?usage: run.sh <venv-dir>}"
export PATH="$HOME/.local/bin:$PATH"

# Which script in this repo to display. Change + push to update over the air.
SCRIPT="weather-phat.py"

# Repo root = parent of this deploy/ directory.
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

# Keep the venv's dependencies in sync with the repo, if it declares any.
if [[ -f requirements.txt ]]; then
  uv pip install --python "${VENV_DIR}/bin/python" -r requirements.txt
fi

exec "${VENV_DIR}/bin/python" "${REPO_DIR}/${SCRIPT}"
