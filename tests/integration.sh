#!/bin/bash
# Full end-to-end `chezmoi init --apply` of this checkout in a fresh distro
# container, as a non-root user, followed by an interactive-zsh startup
# check. See tests/container/integration-*.sh for what runs inside.
#
#   minimal           user has NO sudo (the profile's whole point)
#   headless/standard user has passwordless sudo; no display, so the GUI
#                     tier self-skips
#
# Usage: tests/integration.sh <fedora|ubuntu|debian> <minimal|headless|standard>
# Set GITHUB_TOKEN to keep mise's GitHub API calls from being rate-limited.
set -euo pipefail
# shellcheck source=tests/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

distro="${1:?usage: tests/integration.sh <distro> <profile>}"
profile="${2:?usage: tests/integration.sh <distro> <profile>}"
image="$(image_for "$distro")"
[[ " ${PROFILES[*]} " == *" $profile "* ]] || die "unknown profile '$profile' (expected one of: ${PROFILES[*]})"

name="dotprod-it-$distro-$profile-$$"
cleanup() { engine rm -f "$name" &>/dev/null || true; }
trap cleanup EXIT

log "Starting $image for profile=$profile"
engine run -d --name "$name" --security-opt label=disable \
    -v "$REPO_ROOT:/src:ro" "$image" sleep infinity >/dev/null

log "Container setup (as root): baseline packages, test user, source checkout"
engine exec "$name" bash /src/tests/container/integration-setup.sh "$profile"

log "chezmoi init --apply (as non-root user 'tester')"
# Passed by name (not NAME=value) so the token never shows up in `ps`.
export CHEZMOI_VERSION
engine exec -u tester -w /home/tester \
    -e HOME=/home/tester -e USER=tester -e LOGNAME=tester \
    -e GITHUB_TOKEN -e CHEZMOI_VERSION \
    "$name" bash /src/tests/container/integration-apply.sh "$profile"

log "integration OK: $distro / $profile"
