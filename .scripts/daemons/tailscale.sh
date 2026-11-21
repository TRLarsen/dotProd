#!/bin/bash
# Installs Tailscale from its own package repo (not the distro's repackaged
# build, which `tailscale update`/auto-update can't manage), enables tailscaled
# at boot, and turns on auto-update. Runs every time the system_tools tier
# runs (not just when the binary is missing), so every step must be idempotent.
set -euo pipefail

# shellcheck source=/dev/null # the target machine's os-release, not a repo file
. /etc/os-release

if [[ $ID == fedora ]]; then
    if [[ ! -f /etc/yum.repos.d/tailscale.repo ]]; then
        sudo dnf config-manager addrepo --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo
    fi
    # Fedora ships its own tailscale build in fedora/updates. A higher
    # priority (lower number; default is 99) makes dnf ignore every other
    # repo's tailscale package entirely, so plain `dnf upgrade` always pulls
    # from tailscale-stable.
    sudo dnf config-manager setopt tailscale-stable.priority=10
    sudo dnf install -y tailscale
    # Migrates a machine that already had Fedora's build: distro-sync (not
    # upgrade) swaps it for the tailscale-stable one even at an equal/older
    # version. A no-op once every machine has been migrated.
    sudo dnf distro-sync -y tailscale
elif ! command -v tailscale &>/dev/null; then
    # install.sh handles per-distro repo + keyring setup, so the package
    # comes from Tailscale's repo from the start.
    curl -fsSL https://tailscale.com/install.sh | sh
fi

# tailscaled is Type=notify, so this returns once the daemon is ready.
sudo systemctl enable --now tailscaled

sudo tailscale set --auto-update ||
    echo "⚠️  Could not enable Tailscale auto-update (unsupported on this platform/install?)"

# Login state (WantRunning) persists in tailscaled's state, so this is a
# one-time step; a deliberate `tailscale down` is left alone.
if ! tailscale status &>/dev/null; then
    echo "⚠️  Tailscale isn't connected. Run 'sudo tailscale up' once;"
    echo "    it will reconnect automatically on every boot after that."
fi
