#!/bin/bash
# Single entry point for the test suite -- CI (.github/workflows/ci.yml)
# calls exactly these subcommands, so a local run checks the same things.
# Container-based checks use podman if present, else docker (override with
# CONTAINER_ENGINE=docker). Nothing here touches ~/.config/chezmoi or $HOME:
# host-side chezmoi calls use throwaway config/state, and every apply happens
# inside a disposable container.
#
#   tests/run.sh lint                           shellcheck, shfmt, zsh -n, TOML parse
#   tests/run.sh invariants                     .chezmoidata.toml invariants + `chezmoi managed`
#   tests/run.sh render [distro...]             render every template per distro x profile x laptop
#   tests/run.sh integration <distro> <profile> real `chezmoi init --apply` in a container
#   tests/run.sh all [--full]                   everything CI requires (lint, invariants, render on
#                                               every distro, minimal integration on every distro);
#                                               --full adds the headless/standard integrations
#
# distro: fedora | ubuntu | debian (or "all");  profile: minimal | headless | standard (or "all")
# Set GITHUB_TOKEN (e.g. GITHUB_TOKEN=$(gh auth token)) for the integration
# runs so mise isn't rate-limited by GitHub's API.
set -euo pipefail
# shellcheck source=tests/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
    sed -n '/^#   tests/,/^set -euo/{/^set/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}" >&2
    exit 2
}

expand() { # expand "all" into the full list ($1 = name of the list array)
    local -n list="$1"
    shift
    if [[ $# -eq 0 || "$*" == all ]]; then printf '%s\n' "${list[@]}"; else printf '%s\n' "$@"; fi
}

cmd="${1:-}"
[[ $# -gt 0 ]] && shift
case "$cmd" in
lint) bash "$TESTS_DIR/lint.sh" ;;
invariants)
    python3 "$TESTS_DIR/check_invariants.py" "$REPO_ROOT"
    bash "$TESTS_DIR/check_managed.sh"
    ;;
render)
    mapfile -t ds < <(expand DISTROS "$@")
    for d in "${ds[@]}"; do bash "$TESTS_DIR/render.sh" "$d"; done
    ;;
integration)
    [[ $# -eq 2 ]] || usage
    mapfile -t ds < <(expand DISTROS "$1")
    mapfile -t ps < <(expand PROFILES "$2")
    for d in "${ds[@]}"; do
        for p in "${ps[@]}"; do bash "$TESTS_DIR/integration.sh" "$d" "$p"; done
    done
    ;;
all)
    bash "${BASH_SOURCE[0]}" lint
    bash "${BASH_SOURCE[0]}" invariants
    bash "${BASH_SOURCE[0]}" render all
    bash "${BASH_SOURCE[0]}" integration all minimal
    if [[ "${1:-}" == --full ]]; then
        bash "${BASH_SOURCE[0]}" integration all headless
        bash "${BASH_SOURCE[0]}" integration all standard
    fi
    log "all checks passed"
    ;;
*) usage ;;
esac
