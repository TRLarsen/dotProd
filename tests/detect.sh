#!/bin/bash
# Install-profile discovery for one distro: checks the default
# .chezmoi.toml.tmpl suggests for sudo/no-sudo x display/session/none, as a
# non-root user and as root (tests/container/detect.sh has the cases). The
# real-world counterpart, a real `chezmoi init --promptDefaults` on a real
# no-sudo/sudo user, is in tests/container/integration-apply.sh.
#
# Usage: tests/detect.sh <fedora|ubuntu|debian>
set -euo pipefail
# shellcheck source=tests/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

distro="${1:?usage: tests/detect.sh <distro> (one of: ${DISTROS[*]})}"
image="$(image_for "$distro")"
ensure_tools

# A desktop session file to mount for the user-desktop cases (world-readable:
# the container user is not the file's owner).
fixture="$OUT_DIR/detect/wayland-sessions"
rm -rf "$fixture"
mkdir -p "$fixture"
touch "$fixture/ci-desktop.desktop"
chmod -R a+rX "$OUT_DIR/detect"

detect() { # $1 = mode, rest = extra engine-run args
    local mode="$1"
    shift
    engine run --rm --security-opt label=disable "$@" \
        -v "$REPO_ROOT:/src:ro" -v "$TOOLS_DIR:/opt/ci-bin:ro" \
        "$image" bash /src/tests/container/detect.sh "$mode"
}

log "Profile detection in $image"
detect user --user 65534:65534
detect user-desktop --user 65534:65534 -v "$fixture:/usr/share/wayland-sessions:ro"
detect root
log "detect OK on $distro"
