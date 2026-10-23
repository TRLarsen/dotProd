#!/bin/bash
# Runs as the non-root user 'tester' INSIDE the integration container (see
# tests/integration.sh), after integration-setup.sh has placed the checkout
# at ~/.local/share/chezmoi.
#
# 1. Bootstraps chezmoi exactly like README.md's one-liner (pinned version,
#    and no repo argument since the source dir is already populated), with
#    the init prompts answered non-interactively.
# 2. Checks the result: tools installed, a second apply is clean, and an
#    interactive zsh starts without writing anything to stderr.
# 3. Checks the machine-local ~/.zshrc.local hook: sourced last (so it can
#    override the shared .zshrc), and never touched or adopted by chezmoi.
set -euo pipefail
profile="${1:?usage: integration-apply.sh <profile>}"
: "${CHEZMOI_VERSION:?}"
cd "$HOME"

step() { printf '\n\033[1;34m--- %s\033[0m\n' "$*"; }
fail() {
    printf '\033[1;31mFAIL:\033[0m %s\n' "$*" >&2
    exit 1
}

if [[ "$profile" == minimal ]]; then
    step "Confirming this user has no sudo"
    if sudo -n true 2>/dev/null; then
        fail "the minimal-profile test user can sudo; the test would not prove minimal is sudoless"
    fi
    echo "ok: no sudo"
fi
[[ -n "${GITHUB_TOKEN:-}" ]] || echo "note: GITHUB_TOKEN is unset; mise may hit GitHub API rate limits"

# chezmoi's --prompt* flags are keyed by the prompt *text* (not the data
# key), so take the texts from the template itself.
src="$HOME/.local/share/chezmoi"
prompt_text() { sed -nE "s/.*$1 \. \"$2\" \"([^\"]+)\".*/\1/p" "$src/.chezmoi.toml.tmpl"; }
laptop_prompt="$(prompt_text promptBoolOnce laptop)"
profile_prompt="$(prompt_text promptChoiceOnce profile)"
[[ -n "$laptop_prompt" && -n "$profile_prompt" ]] || fail "could not find the init prompts in .chezmoi.toml.tmpl"

step "chezmoi init --apply (profile=$profile, laptop=false)"
# Same as README.md: sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin" init --apply <repo>
# PATH is left as-is (no ~/.local/bin), like a fresh login on a new machine.
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin" -t "v$CHEZMOI_VERSION" \
    init --apply --no-tty \
    --promptBool "$laptop_prompt=false" --promptChoice "$profile_prompt=$profile"

chezmoi="$HOME/.local/bin/chezmoi"
step "Machine-local config written by init"
"$chezmoi" cat-config
"$chezmoi" data --format json | grep -Eq "\"profile\": \"$profile\"" ||
    fail "chezmoi data does not report profile=$profile"

step "Every mise tool for this profile is installed"
missing="$("$HOME/.local/bin/mise" ls --missing --global 2>&1)" || fail "mise ls failed: $missing"
[[ -z "$missing" ]] || fail "mise reports missing tools: $missing"
"$HOME/.local/bin/mise" ls --global

step "A second chezmoi apply succeeds and leaves nothing to change"
"$chezmoi" apply --no-tty
"$chezmoi" verify --exclude=scripts || fail "chezmoi verify: target state differs after a second apply"

# The interactive-shell check. zsh runs on a pseudo-terminal (via
# `script`), like a real login, so ZLE is enabled -- without one, every
# plugin that touches ZLE errors out. Its stderr alone goes to a file.
# ZELLIJ is set so the generated zellij auto-start in .zshrc doesn't try to
# launch a multiplexer here. The first start may legitimately print one-time
# setup noise (sheldon cloning its plugins on first use), so it only has to
# succeed; the second start is the steady state every later shell sees and
# must write nothing to stderr.
# $1 = stderr file, $2 = command for zsh -c (default: exit; must not
# contain single quotes).
zsh_start() {
    script -qec "env ZELLIJ=0 TERM=xterm-256color zsh -i -c '${2:-exit}' 2>'$1'" /dev/null </dev/null
}
step "Interactive zsh, first start (one-time setup output allowed)"
zsh_start "$HOME/zsh-first.err" || fail "first interactive zsh exited non-zero: $(cat "$HOME/zsh-first.err")"
sed 's/^/  stderr: /' "$HOME/zsh-first.err"

# No ~/.zshrc.local exists yet, so this also proves its absence is silent.
step "Interactive zsh, second start (must print nothing to stderr)"
zsh_start "$HOME/zsh.err" || fail "interactive zsh exited non-zero: $(cat "$HOME/zsh.err")"
if [[ -s "$HOME/zsh.err" ]]; then
    echo "interactive zsh wrote to stderr:" >&2
    sed 's/^/  | /' "$HOME/zsh.err" >&2
    fail "interactive zsh startup is not clean on profile=$profile"
fi
echo "ok: interactive zsh startup is clean"

step "Machine-local ~/.zshrc.local is sourced last and left alone by chezmoi"
# Overrides EDITOR, which the shared .zshrc sets unconditionally, so the
# value seen in the shell proves the local file ran after it.
cat >"$HOME/.zshrc.local" <<'EOF'
export EDITOR=dotprod-local-editor
dotprod_local_marker=sourced
EOF
local_orig="$(<"$HOME/.zshrc.local")"
# shellcheck disable=SC2016 # Expanded by the inner zsh, not here.
zsh_start "$HOME/zsh-local.err" 'print -r -- "$dotprod_local_marker:$EDITOR" >"$HOME/zsh-local.out"' ||
    fail "interactive zsh exited non-zero with ~/.zshrc.local present: $(cat "$HOME/zsh-local.err")"
if [[ -s "$HOME/zsh-local.err" ]]; then
    sed 's/^/  | /' "$HOME/zsh-local.err" >&2
    fail "interactive zsh wrote to stderr with ~/.zshrc.local present"
fi
got="$(cat "$HOME/zsh-local.out")"
[[ "$got" == "sourced:dotprod-local-editor" ]] ||
    fail "expected ~/.zshrc.local to be sourced after the shared .zshrc (marker:EDITOR = 'sourced:dotprod-local-editor', got '$got')"
echo "ok: sourced, and its EDITOR overrides the shared one"

"$chezmoi" apply --no-tty
# (No cmp/diff: Fedora's baseline has no diffutils.)
[[ -f "$HOME/.zshrc.local" && "$(<"$HOME/.zshrc.local")" == "$local_orig" ]] ||
    fail "chezmoi apply modified or removed ~/.zshrc.local"
if "$chezmoi" managed | grep -qxF .zshrc.local; then fail "chezmoi manages ~/.zshrc.local"; fi
# .chezmoiignore lists it, so even an explicit `chezmoi add` must not pull
# it into the (shared) source state.
"$chezmoi" add --no-tty "$HOME/.zshrc.local" 2>&1 | sed 's/^/  chezmoi add: /'
if find "$src" -name '*zshrc.local*' | grep -q .; then
    fail "chezmoi add copied ~/.zshrc.local into the source state: $(find "$src" -name '*zshrc.local*')"
fi
echo "ok: chezmoi apply left it unchanged, and it is neither managed nor addable"
