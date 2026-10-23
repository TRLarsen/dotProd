#!/bin/bash
# Runs as root INSIDE a disposable distro container (see tests/collisions.sh).
# Tests the collision checks shared by run_onchange_before_02/03 and
# ~/.local/bin/dotprod-check (.chezmoitemplates/collision-check-*):
#
#   1. dotprod-check, rendered for "standard" from a copy of the source with
#      a fixture native = true app added, against PATH-shim stubs for `snap`
#      and `flatpak` (the container has neither, nor a display) and fake
#      binaries / desktop files.
#   2. The rendered GUI tier (03) end to end with the same stubs, plus a
#      logging `sudo` stub, so nothing is ever really installed: it must
#      abort before installing anything on a collision, and install exactly
#      what's missing otherwise.
#   3. Malformed [gui_apps] entries must fail the render, loudly.
#   4. A real `chezmoi apply` (profile minimal) with a fake `rg` first on
#      PATH must abort in 02 before deploying anything; deploying only
#      ~/.local/bin/dotprod-check must work without running any script.
#
# Expects: repo at /src (read-only), pinned chezmoi in /opt/ci-bin.
set -euo pipefail
# shellcheck source=/dev/null # the container's own os-release
. /etc/os-release

CHEZMOI=/opt/ci-bin/chezmoi
# Deliberately without /opt/ci-bin, so nothing but what a case adds is on PATH.
BASE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
work="$(mktemp -d)"
mkdir -p "$work/home" "$work/stubs" "$work/fake"
failures=()
fail() {
    echo "  FAIL: $*"
    failures+=("$*")
}
CASE=""
step() {
    CASE="$*"
    echo "--- $ID: $CASE"
}

case "$ID" in
fedora) REMOVE="sudo dnf remove" INSTALL="sudo dnf install -y" ;;
ubuntu | debian) REMOVE="sudo apt-get remove" INSTALL="sudo apt-get install -y" ;;
*)
    echo "unsupported distro $ID" >&2
    exit 1
    ;;
esac

# --- PATH-shim stubs ---------------------------------------------------------
# `snap list <name>` succeeds for the names in $STUB_SNAPS.
cat >"$work/stubs/snap" <<'EOF'
#!/bin/bash
echo "snap $*" >>"$STUB_LOG"
if [[ "${1:-}" == list ]]; then
    for s in ${STUB_SNAPS:-}; do [[ "$s" == "${2:-}" ]] && echo "$s 1.0 stable" && exit 0; done
fi
echo "error: no matching snaps installed" >&2
exit 1
EOF
# `flatpak list` reports $STUB_FLATPAKS ("<id>:<system|user> ..."); anything
# else is only logged.
cat >"$work/stubs/flatpak" <<'EOF'
#!/bin/bash
echo "flatpak $*" >>"$STUB_LOG"
case "$*" in
"list --app --columns=application,installation")
    for e in ${STUB_FLATPAKS:-}; do printf '%s\t%s\n' "${e%%:*}" "${e#*:}"; done ;;
"list --app --columns=application")
    for e in ${STUB_FLATPAKS:-}; do printf '%s\n' "${e%%:*}"; done ;;
esac
exit 0
EOF
# Never runs anything: just records what would have run as root.
cat >"$work/stubs/sudo" <<'EOF'
#!/bin/bash
echo "sudo $*" >>"$STUB_LOG"
exit 0
EOF
chmod +x "$work/stubs/"*

# A fake "outside" copy of program $1 in $work/fake.
fake_bin() {
    printf '#!/bin/sh\necho fake %s\n' "$1" >"$work/fake/$1"
    chmod +x "$work/fake/$1"
}
reset() {
    rm -rf "${work:?}/fake/"* "$work/home/.local/share/mise" /snap/bin
    rm -f /usr/share/applications/org.videolan.VLC.desktop
    : >"$work/stub.log"
}

# --- Source copies with fixture data -----------------------------------------
# $1 = destination; stdin = extra [gui_apps] lines (inserted right under the
# table header). $2 = "no-ghostty" also drops the ghostty entry, whose
# custom installer the GUI-tier run must not reach.
make_src() {
    local fixture
    mkdir -p "$1"
    tar -C /src --exclude=./.git --exclude=./tests -cf - . | tar -C "$1" -xf -
    fixture="$(cat)"
    if [[ "${2:-}" == no-ghostty ]]; then
        sed -i '/^ghostty = /d' "$1/.chezmoidata.toml"
    fi
    if [[ -n "$fixture" ]]; then
        printf '%s\n' "$fixture" >"$work/fixture.toml"
        sed -i "/^\[gui_apps\]$/r $work/fixture.toml" "$1/.chezmoidata.toml"
    fi
}
for p in standard minimal; do
    printf '[data]\n    laptop = false\n    profile = "%s"\n' "$p" >"$work/$p.toml"
done
# $1 = source dir, $2 = profile, $3 = template (relative to the source), $4 = output
render() {
    "$CHEZMOI" --source "$1" --config "$work/$2.toml" --persistent-state "$work/state.boltdb" \
        --cache "$work/cache" --destination "$work/home" --no-tty execute-template <"$1/$3" >"$4"
}

FIXTURE='fixture-native = { native = true, snap = "fixture-native-snap", bins = ["fixture-native-bin"], other_flatpaks = ["org.example.FixtureNative"] }'
make_src "$work/src" <<<"$FIXTURE"
render "$work/src" standard private_dot_local/bin/executable_dotprod-check.tmpl "$work/dotprod-check"
render "$work/src" minimal private_dot_local/bin/executable_dotprod-check.tmpl "$work/dotprod-check-minimal"

# run SCRIPT WANT_RC [VAR=value ...] [-- ARGS...]: runs a rendered script with
# the stubs and $work/fake first on PATH; output goes to $work/out.
run() {
    local script="$1" want="$2" rc=0 envs=()
    shift 2
    while [[ $# -gt 0 && "$1" != -- ]]; do
        envs+=("$1")
        shift
    done
    [[ "${1:-}" == -- ]] && shift
    env PATH="$work/stubs:$work/fake:$BASE_PATH" HOME="$work/home" STUB_LOG="$work/stub.log" "${envs[@]}" \
        bash "$script" "$@" >"$work/out" 2>&1 </dev/null || rc=$?
    [[ $rc -eq $want ]] || fail "$CASE: exit $rc, want $want. Output:$(printf '\n%s' "$(cat "$work/out")" | sed 's/^/      /')"
}
has() { grep -qF -- "$1" "$work/out" || fail "$CASE: output lacks: $1. Output:$(printf '\n%s' "$(cat "$work/out")" | sed 's/^/      /')"; }
lacks() { ! grep -qF -- "$1" "$work/out" || fail "$CASE: output unexpectedly has: $1"; }
logged() { grep -qxF -- "$1" "$work/stub.log" || fail "$CASE: stub log lacks: $1 (log: $(tr '\n' ';' <"$work/stub.log"))"; }
not_logged() { ! grep -qF -- "$1" "$work/stub.log" || fail "$CASE: stub log unexpectedly has: $1"; }

# --- 1. dotprod-check --------------------------------------------------------
DC="$work/dotprod-check"

step "dotprod-check: clean machine"
reset
run "$DC" 0
has "✔ No collisions."
has "not probed -- installed by a custom script that checks for itself: ghostty"

step "dotprod-check: Snap of a Flatpak-backed app"
reset
run "$DC" 1 STUB_SNAPS=brave
has '[COLLISION] brave: the Snap "brave" is already installed'
has "fix: sudo snap remove brave"

step "dotprod-check: Snap of a native = true app (snap override)"
reset
run "$DC" 1 STUB_SNAPS=fixture-native-snap
has '[COLLISION] fixture-native: the Snap "fixture-native-snap" is already installed'

step "dotprod-check: native binary of a Flatpak-backed app (bins override)"
reset
fake_bin brave-browser
run "$DC" 1
has "[COLLISION] brave: a non-Flatpak copy is already installed: $work/fake/brave-browser"
has "isn't owned by a system package"

step "dotprod-check: a native = true app's own binary is not a collision"
reset
fake_bin fixture-native-bin
run "$DC" 0

step "dotprod-check: Snap export dir ignored by the binary probe"
reset
mkdir -p /snap/bin
printf '#!/bin/sh\n' >/snap/bin/brave
chmod +x /snap/bin/brave
run "$DC" 0 PATH="$work/stubs:/snap/bin:$BASE_PATH"
reset

step "dotprod-check: native desktop file under the Flatpak ID"
reset
mkdir -p /usr/share/applications
echo '[Desktop Entry]' >/usr/share/applications/org.videolan.VLC.desktop
run "$DC" 1
has "[COLLISION] vlc: a native package already provides /usr/share/applications/org.videolan.VLC.desktop"
rm /usr/share/applications/org.videolan.VLC.desktop
echo '[Desktop Entry]' >"$work/exported.desktop"
ln -s "$work/exported.desktop" /usr/share/applications/org.videolan.VLC.desktop
step "dotprod-check: a symlinked desktop file (Flatpak export) is not a collision"
run "$DC" 0
reset

step "dotprod-check: alternate Flatpak ID of a Flatpak-backed app"
reset
run "$DC" 1 STUB_FLATPAKS=io.github.zen_browser.zen:user
has "[COLLISION] zen: the Flatpak io.github.zen_browser.zen is already installed (user)"
has "fix: flatpak uninstall --user io.github.zen_browser.zen"

step "dotprod-check: Flatpak of a native = true app"
reset
run "$DC" 1 STUB_FLATPAKS=org.example.FixtureNative:system
has "fix: sudo flatpak uninstall --system org.example.FixtureNative"

step "dotprod-check: the app's own Flatpak is not a collision"
reset
run "$DC" 0 "STUB_FLATPAKS=app.zen_browser.zen:system com.brave.Browser:user"

step "dotprod-check: user_tools binary first on PATH"
reset
fake_bin rg
run "$DC" 1
has "[COLLISION] rg: $work/fake/rg is first on PATH, ahead of the mise-managed copy"

step "dotprod-check: user_tools binary shadowed by mise's copy"
reset
mkdir -p "$work/home/.local/share/mise/installs/ripgrep"
printf '#!/bin/sh\n' >"$work/home/.local/share/mise/installs/ripgrep/rg"
chmod +x "$work/home/.local/share/mise/installs/ripgrep/rg"
fake_bin rg
run "$DC" 0 PATH="$work/stubs:$work/home/.local/share/mise/installs/ripgrep:$work/fake:$BASE_PATH"
has "[SHADOWED] rg: $work/fake/rg is also installed"
has "1 shadowed duplicate(s)"

step "dotprod-check: unowned symlink isn't blamed on its target's package"
reset
ln -s /usr/bin/bash "$work/fake/vlc"
run "$DC" 1
has "[COLLISION] vlc: a non-Flatpak copy is already installed: $work/fake/vlc"
lacks "(package bash)"

step "dotprod-check: owning package looked up for the remediation"
make_src "$work/src-owned" <<<'fixture-owned = { flatpak = "org.example.FixtureOwned", bins = ["bash"] }'
render "$work/src-owned" standard private_dot_local/bin/executable_dotprod-check.tmpl "$work/dotprod-check-owned"
reset
run "$work/dotprod-check-owned" 1
# (found as /usr/bin/bash or, where PATH lists it first and it's merged into /usr/bin, /usr/sbin/bash)
has "[COLLISION] fixture-owned: a non-Flatpak copy is already installed: /usr/"
has "bin/bash (package bash)"
has "fix: $REMOVE bash"

step "dotprod-check: --fix refuses without a terminal, or under chezmoi"
reset
run "$DC" 2 -- --fix
has "needs an interactive terminal"
run "$DC" 2 CHEZMOI=1 -- --fix
has "refusing --fix from inside a chezmoi run"
run "$DC" 2 -- --bogus
has "usage: dotprod-check [--fix]"

step "dotprod-check: profile without gui skips [gui_apps]"
reset
run "$work/dotprod-check-minimal" 0 STUB_SNAPS=brave
has '[gui_apps] skipped: profile "minimal" has no gui capability'
lacks "[COLLISION]"

# --- 2. The GUI install tier (03), end to end --------------------------------
make_src "$work/src-gui" no-ghostty <<<"$FIXTURE"
render "$work/src-gui" standard run_onchange_before_03_install_gui_apps.sh.tmpl "$work/03.sh"

step "03: aborts on a collision before installing or registering anything"
reset
run "$work/03.sh" 1 DISPLAY=:0 STUB_SNAPS=brave
has '[COLLISION] brave: the Snap "brave" is already installed'
has "FATAL: gui_apps install aborted"
not_logged "sudo "

step "03: native-package desktop file guard still aborts"
reset
mkdir -p /usr/share/applications
echo '[Desktop Entry]' >/usr/share/applications/org.videolan.VLC.desktop
run "$work/03.sh" 1 DISPLAY=:0
has "FATAL: gui_apps install aborted"
not_logged "flatpak install"
reset

step "03: clean machine installs every app"
reset
run "$work/03.sh" 0 DISPLAY=:0
for id in com.brave.Browser com.bitwarden.desktop org.videolan.VLC app.zen_browser.zen; do
    logged "sudo flatpak install -y flathub $id"
done
logged "$INSTALL fixture-native"

step "03: already-installed apps are left alone"
reset
fake_bin fixture-native-bin
run "$work/03.sh" 0 DISPLAY=:0 "STUB_FLATPAKS=com.brave.Browser:system"
has "✔ brave is already installed."
has "✔ fixture-native is already installed (native)."
not_logged "flatpak install -y flathub com.brave.Browser"
not_logged "install -y fixture-native"

step "03: no display server -> no checks, nothing installed"
reset
run "$work/03.sh" 0 STUB_SNAPS=brave
has "No display server detected"
lacks "[COLLISION]"

# --- 3. Malformed [gui_apps] entries fail the render -------------------------
# entry|expected error fragment
bad_cases=(
    'bad = { snap = "bad" }|needs exactly one of flatpak'
    'bad = { flatpak = "org.example.Bad", native = true }|needs exactly one of flatpak'
    'bad = { native = false }|sets native = false'
    'bad = { flatpak = "org.example.Bad", bogus = 1 }|unknown key "bogus"'
    'bad = { flatpak = "org.example.Bad", bins = [] }|bins must be a non-empty list'
    'bad = { flatpak = "org.example.Bad", bins = ["a b"] }|is not a plain binary name'
    'bad = { flatpak = "org.example.Bad", snap = "Bad_Snap" }|is not a valid Snap name'
    'bad = { flatpak = "org.example.Bad", other_flatpaks = ["org.example.Bad"] }|the app'"'"'s own Flatpak ID'
    'bad = { flatpak = "not-an-id" }|doesn'"'"'t look like a Flatpak app ID'
    'bad = "custom_script"|needs a custom installer at .scripts/gui/bad.sh.tmpl'
    'ghostty = { flatpak = "com.mitchellh.ghostty", snap = "ghostty" }|duplicate-install probes skip custom-script apps'
)
for c in "${bad_cases[@]}"; do
    entry="${c%%|*}" want="${c#*|}"
    step "render fails for: $entry"
    rm -rf "$work/src-bad"
    make_src "$work/src-bad" no-ghostty <<<"$entry"
    for t in run_onchange_before_03_install_gui_apps.sh.tmpl private_dot_local/bin/executable_dotprod-check.tmpl; do
        if render "$work/src-bad" standard "$t" "$work/bad.out" 2>"$work/bad.err"; then
            fail "$CASE: $t rendered instead of failing"
        elif ! grep -qF -- "$want" "$work/bad.err"; then
            fail "$CASE: $t failed without '$want': $(cat "$work/bad.err")"
        fi
    done
done

# --- 4. A real `chezmoi apply` aborts on a collision -------------------------
make_src "$work/src-apply" </dev/null
dest="$work/apply-home"
# On a real machine ~/.local/bin already exists by the time this matters:
# README's bootstrap installs chezmoi itself there.
mkdir -p "$dest/.local/bin"
cz_apply() {
    env PATH="$work/fake:$BASE_PATH" "$CHEZMOI" --source "$work/src-apply" --config "$work/minimal.toml" \
        --persistent-state "$work/apply-state.boltdb" --cache "$work/cache" --destination "$dest" --no-tty \
        apply "$@" >"$work/out" 2>&1
}

step "chezmoi apply (minimal) with a fake rg first on PATH aborts in 02"
reset
fake_bin rg
if cz_apply; then
    fail "$CASE: chezmoi apply succeeded despite the collision"
fi
has "[COLLISION] rg: $work/fake/rg is first on PATH"
has "FATAL: Environment initialization aborted"
[[ ! -e "$dest/.zshrc" ]] || fail "$CASE: files were deployed although a before-script aborted"

step "chezmoi apply ~/.local/bin/dotprod-check deploys only the checker (no scripts run)"
cz_apply "$dest/.local/bin/dotprod-check" || fail "$CASE: failed: $(cat "$work/out")"
[[ -x "$dest/.local/bin/dotprod-check" ]] || fail "$CASE: dotprod-check not deployed as an executable"
[[ ! -e "$dest/.zshrc" ]] || fail "$CASE: deployed more than the requested target"

step "the deployed dotprod-check reports the collision, then passes once it's gone"
run "$dest/.local/bin/dotprod-check" 1
has "[COLLISION] rg: $work/fake/rg is first on PATH"
reset
run "$dest/.local/bin/dotprod-check" 0
has "✔ No collisions."

if [[ ${#failures[@]} -gt 0 ]]; then
    echo "${#failures[@]} collision-check failure(s) on $ID:"
    printf '  - %s\n' "${failures[@]}"
    exit 1
fi
echo "collision checks OK on $ID"
