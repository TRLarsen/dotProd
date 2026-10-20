#!/bin/bash
# Converges Tailscale to: installed from Tailscale's own package repo (not
# the distro's repackaged build, which `tailscale update`/auto-update can't
# manage), tailscaled enabled at boot, auto-update on, and the node up.
# Runs every time the system_tools tier runs (not just when the binary is
# missing), so every step below must be idempotent.
set -euo pipefail

. /etc/os-release

case "$ID" in
fedora)
    if [[ ! -f /etc/yum.repos.d/tailscale.repo ]]; then
        sudo dnf config-manager addrepo --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo
    fi
    # Fedora ships its own tailscale build in fedora/updates. A higher
    # priority (lower number; default is 99) makes dnf ignore every other
    # repo's tailscale package entirely, so plain `dnf upgrade` always pulls
    # from tailscale-stable.
    sudo dnf config-manager setopt tailscale-stable.priority=10
    if rpm -q tailscale &>/dev/null; then
        # distro-sync (not upgrade) so an existing Fedora-repo build gets
        # swapped for the tailscale-stable one even at an equal/older version.
        sudo dnf distro-sync -y tailscale
    else
        sudo dnf install -y tailscale
    fi
    ;;
ubuntu | debian)
    if [[ ! -f /etc/apt/sources.list.d/tailscale.list ]]; then
        # install.sh handles the per-codename repo + keyring setup.
        curl -fsSL https://tailscale.com/install.sh | sh
    fi
    # Same idea as Fedora's repo priority; >1000 allows switching away from a
    # distro build even if it's a newer version.
    printf 'Package: tailscale\nPin: origin pkgs.tailscale.com\nPin-Priority: 1001\n' |
        sudo tee /etc/apt/preferences.d/tailscale >/dev/null
    sudo apt-get install -y tailscale
    ;;
*)
    if ! command -v tailscale &>/dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh
    fi
    ;;
esac

sudo systemctl enable --now tailscaled

# Wait for tailscaled to finish starting before talking to it.
state=""
for _ in {1..15}; do
    state=$(tailscale status --json 2>/dev/null | sed -n 's/^\s*"BackendState": "\(.*\)",$/\1/p' || true)
    [[ -n "$state" && "$state" != "NoState" && "$state" != "Starting" ]] && break
    sleep 1
done

sudo tailscale set --auto-update ||
    echo "⚠️  Could not enable Tailscale auto-update (unsupported on this platform/install?)"

# WantRunning is persisted in tailscaled's state, so once the node is up it
# reconnects on its own after every reboot.
case "$state" in
Running)
    echo "✔ Tailscale is up."
    ;;
Stopped)
    echo "Tailscale is logged in but down; bringing it up..."
    sudo tailscale up ||
        echo "⚠️  'tailscale up' failed; run it manually with your usual flags."
    ;;
NeedsLogin | NeedsMachineAuth)
    echo "⚠️  Tailscale isn't authenticated yet. Run 'sudo tailscale up' once;"
    echo "    it will reconnect automatically on every boot after that."
    ;;
*)
    echo "⚠️  tailscaled state is '${state:-unknown}'; check 'systemctl status tailscaled'."
    ;;
esac
