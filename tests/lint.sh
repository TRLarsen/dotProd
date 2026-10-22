#!/bin/bash
# Static checks that need no container: shellcheck + shfmt on every plain
# shell script, `zsh -n` on dot_zshrc, and a parse of every plain .toml file.
# (Templates are checked after rendering, by tests/render.sh.)
set -euo pipefail
# shellcheck source=tests/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
ensure_tools
cd "$REPO_ROOT"

failed=0
mapfile -t scripts < <(plain_shell_scripts)
[[ ${#scripts[@]} -gt 0 ]] || die "found no shell scripts to lint"

log "shellcheck (severity=style) on ${#scripts[@]} plain shell scripts"
shellcheck --version | sed -n 2p
# -x follows `source` of other repo files (tests/lib/common.sh).
shellcheck -x --severity=style "${scripts[@]}" || failed=1

log "shfmt -d -i 4 (the repo's formatter of record, see CLAUDE.md)"
shfmt -d -i 4 "${scripts[@]}" || {
    echo "Fix with: shfmt -w -i 4 <file>" >&2
    failed=1
}

log "zsh -n dot_zshrc"
command -v zsh &>/dev/null || die "zsh is required for the dot_zshrc syntax check"
zsh -n dot_zshrc || failed=1

log "TOML parse of every non-template .toml file"
mapfile -t tomls < <(find . \( -name .git -o -path ./tests/.cache -o -path ./tests/.out \) -prune -o -name '*.toml' -print | sort)
python3 "$TESTS_DIR/lib/toml_parse.py" "${tomls[@]}" || failed=1

[[ $failed -eq 0 ]] || die "lint failed"
log "lint OK"
