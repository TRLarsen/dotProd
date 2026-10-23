#!/bin/bash
# Collision-check tests for one distro: runs tests/container/collisions.sh
# (as root, in a disposable container) against the dotprod-check / GUI-tier
# collision logic, with stubbed snap/flatpak/sudo and a real `chezmoi apply`
# that must abort on a fake `rg`. Wired into `tests/run.sh render`, so CI's
# render job covers it.
#
# Usage: tests/collisions.sh <fedora|ubuntu|debian>
set -euo pipefail
# shellcheck source=tests/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

distro="${1:?usage: tests/collisions.sh <distro> (one of: ${DISTROS[*]})}"
image="$(image_for "$distro")"
ensure_tools

log "Collision-check tests in $image"
engine run --rm --security-opt label=disable \
    -v "$REPO_ROOT:/src:ro" -v "$TOOLS_DIR:/opt/ci-bin:ro" \
    "$image" bash /src/tests/container/collisions.sh ||
    die "collision-check tests failed on $distro"
log "collision checks OK on $distro"
