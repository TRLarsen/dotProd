#!/bin/bash
set -euo pipefail

# The dispatcher passes the TOML value as $1 (default to empty string if unset)
PPA_STRING="${1:-}"

if ! command -v ghostty &> /dev/null; then
{{ if eq .chezmoi.osRelease.id "ubuntu" "debian" }}
    if [[ -z "$PPA_STRING" ]]; then
        echo "Error: PPA_STRING is required for Debian/Ubuntu." >&2
        exit 1
    fi
    echo "Adding repository: $PPA_STRING..."
    sudo add-apt-repository -y "$PPA_STRING"
    sudo apt-get update -y
    sudo apt-get install -y ghostty
{{ else if eq .chezmoi.osRelease.id "fedora" }}
    echo "Enabling COPR and installing Ghostty on Fedora..."
    sudo dnf copr enable -y scottames/ghostty
    sudo dnf install -y ghostty
{{ else }}
    echo "Error: Unsupported OS '{{ .chezmoi.osRelease.id }}'" >&2
    exit 1
{{ end }}
else
    echo "✔ Ghostty is already installed."
fi
