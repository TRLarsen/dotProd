#!/bin/bash
set -euo pipefail

CHANNEL_OR_VERSION="${1:-stable}"

if command -v claude &>/dev/null; then
  echo "claude-code already present ($(claude --version 2>/dev/null || echo unknown)); skipping"
  exit 0
fi

curl -fsSL https://claude.ai/install.sh | bash -s "${CHANNEL_OR_VERSION}"
