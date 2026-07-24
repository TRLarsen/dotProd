#!/bin/bash
set -euo pipefail

# The dispatcher passes the TOML value as $1
PPA_STRING="$1" 

if ! command -v ghostty &> /dev/null; then
    {{ if eq .chezmoi.osRelease.id "ubuntu" "debian" }}
        echo "Adding repository: $PPA_STRING..."
        sudo add-apt-repository -y "$PPA_STRING"
        sudo apt-get update -y
        sudo apt-get install -y ghostty
    {{ else if eq .chezmoi.osRelease.id "fedora" }}
        dnf copr enable scottames/ghostty
        dnf install ghostty
else
    echo "✔ Ghostty is already installed."
fi
