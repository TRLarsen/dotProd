#!/bin/bash
# Runs INSIDE a distro container (see tests/render.sh), so every template
# sees that distro's .chezmoi.osRelease.id. For each profile x laptop
# combination it renders .chezmoi.toml.tmpl the way `chezmoi init` would,
# then renders every other *.tmpl in the repo against that config, and
# checks the rendered shell with `bash -n` + shellcheck. The rendered tree is
# streamed to stdout as a tar (everything else goes to stderr) for the
# host-side semantic checks in tests/check_rendered.py.
#
# Expects: repo at /src (read-only), pinned chezmoi + shellcheck in /opt/ci-bin.
set -euo pipefail
exec 3>&1 1>&2 # fd 3 = tar stream; keep stdout clean

SRC=/src
export PATH="/opt/ci-bin:$PATH"
# shellcheck source=/dev/null # the container's own os-release
. /etc/os-release
DISTRO="$ID"
PROFILES=(standard headless minimal)

work="$(mktemp -d)"
out="$work/out"
mkdir -p "$out" "$work/home"
failures=()
fail() {
    echo "  FAIL: $*"
    failures+=("$*")
}

# Isolated chezmoi: never reads/writes any real config, state or cache.
cz() {
    chezmoi --source "$SRC" --persistent-state "$work/state.boltdb" --cache "$work/cache" \
        --destination "$work/home" --no-tty "$@"
}

# chezmoi's --promptBool/--promptChoice flags are keyed by the prompt *text*,
# not the data key, so pull the texts out of the template rather than
# duplicating them here (a reworded prompt would otherwise silently render
# the defaults; the value check below catches that too).
prompt_text() {
    sed -nE "s/.*$1 \. \"$2\" \"([^\"]+)\".*/\1/p" "$SRC/.chezmoi.toml.tmpl"
}
LAPTOP_PROMPT="$(prompt_text promptBoolOnce laptop)"
PROFILE_PROMPT="$(prompt_text promptChoiceOnce profile)"
[[ -n "$LAPTOP_PROMPT" && -n "$PROFILE_PROMPT" ]] ||
    {
        echo "could not find the laptop/profile prompts in .chezmoi.toml.tmpl"
        exit 1
    }

# Every template except the config template (rendered via --init below) and
# the .chezmoitemplates partials (only meaningful when included with args).
mapfile -t templates < <(cd "$SRC" && find . \( -name .git -o -path ./tests -o -path ./.chezmoitemplates \) -prune \
    -o -name '*.tmpl' ! -path ./.chezmoi.toml.tmpl -print | sed 's|^\./||' | sort)
echo "Rendering ${#templates[@]} templates on $DISTRO ($PRETTY_NAME) for profiles ${PROFILES[*]} x laptop true/false"

for profile in "${PROFILES[@]}"; do
    for laptop in true false; do
        case_dir="$out/$profile-laptop_$laptop"
        mkdir -p "$case_dir"
        cfg="$case_dir/chezmoi.toml"
        echo "--- $DISTRO / profile=$profile / laptop=$laptop"
        if ! cz --config "$work/no-such-config.toml" execute-template --init \
            --promptBool "$LAPTOP_PROMPT=$laptop" --promptChoice "$PROFILE_PROMPT=$profile" \
            <"$SRC/.chezmoi.toml.tmpl" >"$cfg"; then
            fail "$profile/laptop=$laptop: .chezmoi.toml.tmpl did not render"
            continue
        fi
        if ! grep -Eq "^[[:space:]]*laptop[[:space:]]*=[[:space:]]*${laptop}[[:space:]]*$" "$cfg" ||
            ! grep -Eq "^[[:space:]]*profile[[:space:]]*=[[:space:]]*\"$profile\"[[:space:]]*$" "$cfg"; then
            fail "$profile/laptop=$laptop: rendered config does not carry the requested answers"
            cat "$cfg"
            continue
        fi

        for t in "${templates[@]}"; do
            dest="$case_dir/${t%.tmpl}"
            mkdir -p "$(dirname "$dest")"
            if ! cz --config "$cfg" execute-template <"$SRC/$t" >"$dest" 2>"$dest.stderr"; then
                fail "$profile/laptop=$laptop: $t did not render: $(cat "$dest.stderr")"
                continue
            fi
            if [[ -s "$dest.stderr" ]]; then
                fail "$profile/laptop=$laptop: $t rendered with stderr output: $(cat "$dest.stderr")"
            fi
            rm -f "$dest.stderr"
            if [[ "$dest" == *.sh ]]; then
                bash -n "$dest" || fail "$profile/laptop=$laptop: rendered $t fails bash -n"
                # Rendered output is shaped by template whitespace, so style-
                # level findings (formatting, quoting the template already
                # controls) are noise here; warnings and errors are not.
                shellcheck --shell=bash --severity=warning "$dest" ||
                    fail "$profile/laptop=$laptop: rendered $t has shellcheck findings"
            fi
        done
    done
done

# Every package the rendered dispatchers would hand to the native package
# manager (system_tools, and native = true gui_apps) must exist in this
# distro's repos -- otherwise `chezmoi apply` dies with "Unable to locate
# package" on exactly the sudo-capable profiles. Tools installed by a
# .scripts/daemons script (from their own repo) aren't in this list.
echo "--- $DISTRO / native packages exist in the distro repos"
pkgs=()
for case_dir in "$out"/*/; do
    for f in "$case_dir"run_onchange_before_01_install_system_tools.sh "$case_dir"run_onchange_before_03_install_gui_apps.sh; do
        # shellcheck disable=SC2016 # matching the literal text `$PKG_MANAGER` in the rendered script
        mapfile -t found < <(sed -nE 's/^[[:space:]]*\$PKG_MANAGER "([^"]+)"[[:space:]]*$/\1/p' "$f")
        pkgs+=("${found[@]}")
    done
done
mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sed '/^$/d' | sort -u)
if [[ ${#pkgs[@]} -eq 0 ]]; then
    fail "found no \$PKG_MANAGER installs in any rendered profile (expected some on sudo profiles)"
else
    echo "checking ${#pkgs[@]} package(s): ${pkgs[*]}"
    case "$DISTRO" in
    fedora)
        dnf -q makecache >/dev/null
        # --whatprovides, like `dnf install` itself: Fedora has no
        # package *named* clangd, clang-tools-extra provides it.
        have() { [[ -n "$(dnf -q repoquery --whatprovides "$1" 2>/dev/null)" ]]; }
        ;;
    ubuntu | debian)
        apt-get update -qq >/dev/null
        # A simulated install resolves exactly as `apt-get install` would
        # (virtual packages, dependencies) without installing anything.
        have() { apt-get install -s -qq --no-install-recommends "$1" &>/dev/null; }
        ;;
    *) fail "no package-existence check for distro $DISTRO" ;;
    esac
    for p in "${pkgs[@]}"; do
        have "$p" || fail "package \"$p\" is not available in the $DISTRO repos"
    done
fi

# A machine whose stored profile isn't a [profiles] key must fail at render
# time in every install-tier dispatcher, rather than guessing.
echo "--- $DISTRO / profile=bogus (must fail loudly)"
printf '[data]\n    laptop = false\n    profile = "bogus"\n' >"$work/bogus.toml"
for t in run_onchange_before_01_install_system_tools.sh.tmpl \
    run_onchange_before_02_install_user_tools.sh.tmpl \
    run_onchange_before_03_install_gui_apps.sh.tmpl; do
    if cz --config "$work/bogus.toml" execute-template <"$SRC/$t" >/dev/null 2>"$work/bogus.err"; then
        fail "$t rendered for unknown profile \"bogus\" instead of failing"
    elif ! grep -q 'has no entry in \[profiles\]' "$work/bogus.err"; then
        fail "$t failed for unknown profile, but not with the expected message: $(cat "$work/bogus.err")"
    fi
done

tar -C "$out" -cf - . >&3

if [[ ${#failures[@]} -gt 0 ]]; then
    echo "${#failures[@]} render failure(s) on $DISTRO:"
    printf '  - %s\n' "${failures[@]}"
    exit 1
fi
echo "render OK on $DISTRO"
