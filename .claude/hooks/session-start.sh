#!/bin/bash
# Cloud sessions: make the repo's lint tools available.
# CLAUDE.md requires every shell script to pass `shellcheck -S warning` and `bash -n`.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}"

# Install the shellcheck tool from apt if reachable, else the PyPI wheel (shellcheck-py)
if ! command -v shellcheck >/dev/null; then
  if ! { apt-get update -qq && apt-get install -y -qq shellcheck; } >/dev/null 2>&1; then
    python3 -m pip install -q shellcheck-py
  fi
fi
