#!/bin/bash
# Asserts `chezmoi managed` (what `chezmoi apply` would write into $HOME)
# never includes repo-only files -- docs, license, CI config, this tests/
# directory -- and still includes the core dotfiles. Uses a throwaway
# config/state/destination, so the real ~/.config/chezmoi is never touched.
set -euo pipefail
# shellcheck source=tests/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
ensure_tools

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

for profile in "${PROFILES[@]}"; do
    printf '[data]\n    laptop = false\n    profile = "%s"\n' "$profile" >"$work/chezmoi.toml"
    managed="$(chezmoi managed --source "$REPO_ROOT" --config "$work/chezmoi.toml" \
        --persistent-state "$work/state.boltdb" --cache "$work/cache" --destination "$work/home" --no-tty)"
    log "chezmoi managed (profile=$profile): $(wc -l <<<"$managed") entries"

    # Anything that's only meaningful in the repo itself.
    if bad="$(grep -E '^(README\.md|CLAUDE\.md|LICENSE|tests|\.github|\.gitignore|\.shellcheckrc)(/|$)' <<<"$managed")"; then
        echo "  FAIL: repo-only paths would be deployed to \$HOME:" >&2
        printf '    %s\n' "${bad//$'\n'/$'\n'    }" >&2
        failed=1
    fi
    for want in .zshrc .config/mise/config.toml .config/sheldon/plugins.toml .local/bin/md-preview .local/bin/dotprod-update; do
        if ! grep -qxF "$want" <<<"$managed"; then
            echo "  FAIL: expected $want to be managed" >&2
            failed=1
        fi
    done
done

[[ $failed -eq 0 ]] || die "chezmoi managed check failed"
log "chezmoi managed OK"
