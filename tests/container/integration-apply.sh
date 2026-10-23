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
# Profile discovery on a real user (the hint is first-init only, so the
# detection run below uses a scratch --config with nothing stored; a second run
# against the stored answers must stay quiet): no sudo for minimal, an admin-group
# sudoer for headless/standard, and no display in the container (standard
# gets one in the environment for this step only). Re-runs the real `chezmoi
# init` with --promptDefaults (take every detected default), on a pty so the
# explanation is printed, reading and writing a scratch config so the real one
# is left alone.
display=()
[[ "$profile" == standard ]] && display=(WAYLAND_DISPLAY=wayland-ci)
step "Profile discovery: a fresh init on this machine suggests \"$profile\""
script -qec "env ${display[*]} '$chezmoi' init --promptDefaults --config '$HOME/detected.toml'" \
    /dev/null </dev/null >"$HOME/detect.out" 2>&1 || fail "detection init failed: $(cat "$HOME/detect.out")"
sed 's/^/  | /' "$HOME/detect.out"
grep -q "suggesting \"$profile\"" "$HOME/detect.out" || fail "init did not explain a \"$profile\" suggestion"
grep -Eq "^[[:space:]]*profile[[:space:]]*=[[:space:]]*\"$profile\"[[:space:]]*$" "$HOME/detected.toml" ||
    fail "init --promptDefaults chose a different profile: $(cat "$HOME/detected.toml")"

step "Re-running init against a stored profile keeps it and prints no hint"
script -qec "env ${display[*]} '$chezmoi' init --promptDefaults --config '$HOME/detected.toml'" \
    /dev/null </dev/null >"$HOME/detect2.out" 2>&1 || fail "second init failed: $(cat "$HOME/detect2.out")"
! grep -q "Install profile detection" "$HOME/detect2.out" || fail "init repeated the detection hint on an existing machine"
grep -Eq "^[[:space:]]*profile[[:space:]]*=[[:space:]]*\"$profile\"" "$HOME/detected.toml" || fail "second init changed the stored profile"

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
zsh_start() {
    script -qec "env ZELLIJ=0 TERM=xterm-256color zsh -i -c exit 2>'$1'" /dev/null </dev/null
}
step "Interactive zsh, first start (one-time setup output allowed)"
zsh_start "$HOME/zsh-first.err" || fail "first interactive zsh exited non-zero: $(cat "$HOME/zsh-first.err")"
sed 's/^/  stderr: /' "$HOME/zsh-first.err"

step "Interactive zsh, second start (must print nothing to stderr)"
zsh_start "$HOME/zsh.err" || fail "interactive zsh exited non-zero: $(cat "$HOME/zsh.err")"
if [[ -s "$HOME/zsh.err" ]]; then
    echo "interactive zsh wrote to stderr:" >&2
    sed 's/^/  | /' "$HOME/zsh.err" >&2
    fail "interactive zsh startup is not clean on profile=$profile"
fi
echo "ok: interactive zsh startup is clean"
