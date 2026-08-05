#!/bin/bash
set -euo pipefail

if command -v tailscale &>/dev/null; then
  echo "Tailscale already present ($(tailscale --version 2>/dev/null || echo unknown)); skipping"
  exit 0
fi

curl -fsSL https://tailscale.com/install.sh | sh
