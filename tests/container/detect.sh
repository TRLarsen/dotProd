#!/bin/bash
# Runs INSIDE a distro container (see tests/detect.sh) to check the install-
# profile discovery in .chezmoi.toml.tmpl: for each case it renders the
# template the way a fresh `chezmoi init --promptDefaults` would (no stored
# answers, no --prompt* flags, so every prompt returns its default) and
# checks the suggested profile.
#
# What the template inspects is controlled per case: PATH is reduced to a
# per-case bin dir holding `sh`, an `id` (real, or a stub printing chosen
# groups / failing) and optionally a `sudo` stub; the environment is cleared
# except for the case's display variables. The stub sudo records any call:
# detection must never actually run sudo.
#
# The mode picks the cases matching how tests/detect.sh started the container:
#   user          non-root, no desktop session files (on Fedora the session
#                 dirs exist but are empty -- that must not count as a desktop)
#   user-desktop  non-root, a .desktop file mounted in /usr/share/wayland-sessions
#   root          uid 0
#
# Expects: repo at /src (read-only), pinned chezmoi in /opt/ci-bin.
set -euo pipefail
mode="${1:?usage: detect.sh <user|user-desktop|root>}"
SRC=/src
# shellcheck source=/dev/null # the container's own os-release
. /etc/os-release

work="$(mktemp -d)"
real_sh="$(command -v sh)"
real_id="$(command -v id)"
failures=()
fail() {
    echo "  FAIL: $*"
    failures+=("$*")
}

# run_case <expected profile> <description> <sudo: yes|no> <groups: real|FAIL|"g1 g2 ..."> [VAR=value...]
n=0
run_case() {
    local expect="$1" desc="$2" sudo="$3" groups="$4"
    shift 4
    n=$((n + 1))
    local bin="$work/case$n/bin"
    mkdir -p "$bin" "$work/case$n/home"
    ln -s "$real_sh" "$bin/sh"
    if [[ "$groups" == real ]]; then
        ln -s "$real_id" "$bin/id"
    else
        # Only `id -Gn` is ever called by the template.
        printf '#!%s\n[ "%s" = FAIL ] && exit 1\necho "%s"\n' "$real_sh" "$groups" "$groups" >"$bin/id"
        chmod +x "$bin/id"
    fi
    if [[ "$sudo" == yes ]]; then
        printf '#!%s\necho "$*" >>"%s/sudo-called"\nexit 1\n' "$real_sh" "$work" >"$bin/sudo"
        chmod +x "$bin/sudo"
    fi

    local out
    if ! out="$(env -i HOME="$work/case$n/home" PATH="$bin:/opt/ci-bin" "$@" \
        chezmoi --source "$SRC" --config "$work/no-such-config.toml" \
        --persistent-state "$work/case$n/state.boltdb" --cache "$work/case$n/cache" \
        --destination "$work/case$n/home" --no-tty \
        execute-template --init <"$SRC/.chezmoi.toml.tmpl" 2>&1)"; then
        fail "$desc: .chezmoi.toml.tmpl did not render: $out"
        return
    fi
    local got
    got="$(sed -nE 's/^[[:space:]]*profile[[:space:]]*=[[:space:]]*"([^"]*)"[[:space:]]*$/\1/p' <<<"$out")"
    if [[ "$got" == "$expect" ]]; then
        echo "  ok: $desc -> $got"
    else
        fail "$desc: suggested profile \"$got\", expected \"$expect\""
    fi
    # stdin is not a terminal here, so the human-facing explanation must
    # stay out of the rendered config.
    if grep -q 'Install profile detection' <<<"$out"; then
        fail "$desc: the detection hint was written to non-interactive output"
    fi
}

echo "Profile detection on $ID ($PRETTY_NAME), mode=$mode, uid=$(id -u)"
case "$mode" in
user)
    run_case minimal "no sudo on PATH" no real
    run_case minimal "no sudo on PATH, display server running" no real WAYLAND_DISPLAY=wayland-0
    run_case minimal "sudo, but not in an admin group" yes "nobody users"
    run_case minimal "sudo, group name only contains 'wheel'" yes "nobody wheelers"
    run_case minimal "sudo, but \`id -Gn\` fails" yes FAIL
    run_case headless "sudo via wheel, no display/session" yes "nobody wheel"
    run_case headless "sudo via the sudo group, no display/session" yes "nobody sudo"
    run_case standard "sudo via admin, \$WAYLAND_DISPLAY set" yes "nobody admin" WAYLAND_DISPLAY=wayland-0
    run_case standard "sudo via wheel, \$DISPLAY set" yes "users wheel" DISPLAY=:0
    ;;
user-desktop)
    run_case standard "sudo via wheel, desktop session installed (e.g. over SSH)" yes "nobody wheel"
    run_case minimal "no sudo on PATH, desktop session installed" no real
    ;;
root)
    run_case headless "root, sudo installed" yes real
    run_case minimal "root, no sudo on PATH" no real
    ;;
*)
    echo "unknown mode '$mode'" >&2
    exit 2
    ;;
esac

if [[ -e "$work/sudo-called" ]]; then
    fail "detection ran sudo: $(cat "$work/sudo-called")"
fi
if [[ ${#failures[@]} -gt 0 ]]; then
    echo "${#failures[@]} detection failure(s) on $ID ($mode):"
    printf '  - %s\n' "${failures[@]}"
    exit 1
fi
