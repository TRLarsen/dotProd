#!/bin/bash
set -euo pipefail

# Safely exit if Helix is not installed
if ! command -v hx &> /dev/null; then
    exit 0
fi

# Safely exit if lldb-dap is already configured in the user path
if command -v lldb-dap &> /dev/null; then
    exit 0
fi

# Search the system for the LLVM debugging binaries installed by the OS
LLDB_TARGET=$(find /usr/bin -maxdepth 1 -name "lldb-dap*" -o -name "lldb-vscode*" 2>/dev/null | head -n 1)

if [ -n "$LLDB_TARGET" ]; then
    echo "🔗 Symlinking $LLDB_TARGET to lldb-dap for Helix integration..."
    mkdir -p "$HOME/.local/bin"
    ln -sf "$LLDB_TARGET" "$HOME/.local/bin/lldb-dap"
else
    echo "⚠️  Helix is installed, but system LLDB debugging binaries were not found."
fi
