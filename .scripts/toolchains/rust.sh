#!/bin/bash
set -euo pipefail

# Capture the version string passed from the TOML (default to 'stable' if blank)
TOOLCHAIN_VERSION="${1:-stable}"

if ! command -v cargo &> /dev/null; then
    echo "Installing Rust toolchain ($TOOLCHAIN_VERSION)..."
    # Use --no-modify-path so it doesn't pollute your standard bashrc/zshrc
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain "$TOOLCHAIN_VERSION"
fi

# Source the environment so rustup commands work in this specific script instance
source "$HOME/.cargo/env"

# Ensure the requested toolchain is default and add the language server
rustup default "$TOOLCHAIN_VERSION"
rustup component add rust-analyzer --toolchain "$TOOLCHAIN_VERSION"

# Generate static Zsh completions
echo "Generating Zsh completions for Cargo..."
mkdir -p "$HOME/.local/share/zsh/completions"
rustup completions zsh > "$HOME/.local/share/zsh/completions/_cargo"
