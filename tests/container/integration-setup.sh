#!/bin/bash
# Runs as root INSIDE the integration container (see tests/integration.sh).
# Builds the "machine" the apply runs on: a baseline package set, a
# non-root user 'tester', and this checkout at ~tester/.local/share/chezmoi.
#
# The baseline is deliberately small: only what a shared lab box or a fresh
# server would plausibly already have. Anything else the repo needs must be
# installed by the repo itself -- that's what's under test.
set -euo pipefail
profile="${1:?usage: integration-setup.sh <profile>}"
# shellcheck source=/dev/null # the container's own os-release
. /etc/os-release

case "$ID" in
fedora)
    # util-linux-script: `script`, which the harness itself uses to give
    # zsh a pty (Debian/Ubuntu ship it in the essential bsdutils package).
    pkgs=(zsh git curl ca-certificates tar gzip xz unzip findutils procps-ng shadow-utils util-linux-script)
    # dnf5's config-manager (used by .scripts/daemons/tailscale.sh) is a
    # plugin that Fedora installs ship by default but the container doesn't.
    [[ "$profile" == minimal ]] || pkgs+=(sudo dnf5-plugins)
    dnf install -y --setopt=install_weak_deps=False "${pkgs[@]}" >/dev/null
    ;;
ubuntu | debian)
    pkgs=(zsh git curl ca-certificates tar gzip xz-utils unzip procps)
    [[ "$profile" == minimal ]] || pkgs+=(sudo)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${pkgs[@]}" >/dev/null
    ;;
*)
    echo "unsupported distro $ID" >&2
    exit 1
    ;;
esac

useradd --create-home --shell /bin/bash tester

if [[ "$profile" != minimal ]]; then
    # An owned machine: the user may sudo without a password (CI can't type one).
    cat >/etc/sudoers.d/tester <<'EOF'
tester ALL=(ALL) NOPASSWD: ALL
Defaults:tester env_keep += "DEBIAN_FRONTEND"
Defaults:tester secure_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
    chmod 0440 /etc/sudoers.d/tester
    echo 'DEBIAN_FRONTEND=noninteractive' >>/etc/environment
    # The container doesn't boot systemd, so `systemctl enable --now` (used by
    # .scripts/daemons/tailscale.sh) can't work here. Stand in a logging
    # no-op; the secure_path above puts /usr/local/bin first for sudo too.
    cat >/usr/local/bin/systemctl <<'EOF'
#!/bin/sh
echo "[ci systemctl shim: no systemd in this container] systemctl $*" >&2
exit 0
EOF
    chmod 0755 /usr/local/bin/systemctl
fi

# The checkout goes where `chezmoi init` would have cloned it: the default
# source dir (the GUI/personal dispatchers re-invoke `chezmoi
# execute-template`, which relies on that default). Copy rather than mount,
# without .git (chezmoi init makes a fresh repo) or the tests/ scratch dirs.
src=/home/tester/.local/share/chezmoi
mkdir -p "$src"
tar -C /src --exclude=./.git --exclude=./tests/.cache --exclude=./tests/.out -cf - . | tar -C "$src" -xf -
chown -R tester:tester /home/tester/.local
echo "setup done: $PRETTY_NAME, profile=$profile, sudo=$([[ "$profile" == minimal ]] && echo no || echo passwordless)"
