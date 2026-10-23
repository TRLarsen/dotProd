#!/bin/bash
# Shared helpers for the tests/ scripts: repo paths, pinned tool versions,
# the distro -> container image map, and the container engine wrapper.
# Sourced, never executed directly.

# shellcheck disable=SC2034 # Variables here are consumed by the scripts that source this file.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"

# Downloaded tool binaries and render output live under tests/ but are
# gitignored; the leading dot also keeps chezmoi from ever reading them.
CACHE_DIR="${DOTPROD_CI_CACHE:-$TESTS_DIR/.cache}"
TOOLS_DIR="$CACHE_DIR/bin"
OUT_DIR="${DOTPROD_CI_OUT:-$TESTS_DIR/.out}"

# Pinned tool versions. Bump the version AND its sha256 together.
CHEZMOI_VERSION="2.72.2"
CHEZMOI_SHA256="b2ff4d3c3e4fb0de0bf48cda50b888cb24f32562f622dc4688ee02f0291c4424" # chezmoi-linux-amd64-musl (static)
SHELLCHECK_VERSION="0.11.0"
SHELLCHECK_SHA256="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198" # release asset: shellcheck-vX.linux.x86_64.tar.xz
SHFMT_VERSION="3.14.1"
SHFMT_SHA256="76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf" # shfmt_vX_linux_amd64

# Distros the per-distro [system_tools] maps cover. Arch is deliberately not
# here: the dispatcher has an arch branch, but the per-distro maps have no
# arch entries, so rendering fails loudly there by design.
DISTROS=(fedora ubuntu debian)
PROFILES=(standard headless minimal)

image_for() {
    case "$1" in
    fedora) echo "docker.io/library/fedora:44" ;;
    ubuntu) echo "docker.io/library/ubuntu:24.04" ;;
    debian) echo "docker.io/library/debian:13" ;;
    *)
        echo "unknown distro '$1' (expected one of: ${DISTROS[*]})" >&2
        return 1
        ;;
    esac
}

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() {
    printf '\033[1;31mFAIL:\033[0m %s\n' "$*" >&2
    exit 1
}

# Downloads a file and checks its sha256. $1=url $2=dest $3=sha256
_fetch() {
    local tmp
    tmp="$(mktemp "$2.XXXXXX")"
    curl -fsSL --retry 3 -o "$tmp" "$1"
    if ! echo "$3  $tmp" | sha256sum -c --quiet -; then
        rm -f "$tmp"
        die "checksum mismatch for $1"
    fi
    mv "$tmp" "$2"
}

# Installs the pinned static chezmoi/shellcheck/shfmt binaries into
# $TOOLS_DIR (once) and puts that directory first on PATH, so local runs
# use exactly the versions CI uses regardless of what the host has.
ensure_tools() {
    [[ "$(uname -m)" == x86_64 ]] || die "tests/ only pins x86_64 tool binaries (got $(uname -m))"
    mkdir -p "$TOOLS_DIR"
    local stamp="$TOOLS_DIR/.versions"
    local want="chezmoi=$CHEZMOI_VERSION shellcheck=$SHELLCHECK_VERSION shfmt=$SHFMT_VERSION"
    if [[ "$(cat "$stamp" 2>/dev/null)" != "$want" ]]; then
        log "Installing pinned tools into $TOOLS_DIR ($want)"
        _fetch "https://github.com/twpayne/chezmoi/releases/download/v$CHEZMOI_VERSION/chezmoi-linux-amd64-musl" \
            "$TOOLS_DIR/chezmoi" "$CHEZMOI_SHA256"
        _fetch "https://github.com/mvdan/sh/releases/download/v$SHFMT_VERSION/shfmt_v${SHFMT_VERSION}_linux_amd64" \
            "$TOOLS_DIR/shfmt" "$SHFMT_SHA256"
        _fetch "https://github.com/koalaman/shellcheck/releases/download/v$SHELLCHECK_VERSION/shellcheck-v$SHELLCHECK_VERSION.linux.x86_64.tar.xz" \
            "$TOOLS_DIR/shellcheck.tar.xz" "$SHELLCHECK_SHA256"
        tar -xJf "$TOOLS_DIR/shellcheck.tar.xz" -C "$TOOLS_DIR" --strip-components=1 "shellcheck-v$SHELLCHECK_VERSION/shellcheck"
        rm -f "$TOOLS_DIR/shellcheck.tar.xz"
        chmod +x "$TOOLS_DIR/chezmoi" "$TOOLS_DIR/shfmt" "$TOOLS_DIR/shellcheck"
        echo "$want" >"$stamp"
    fi
    export PATH="$TOOLS_DIR:$PATH"
}

# Container engine: $CONTAINER_ENGINE if set, else podman, else docker.
engine() {
    if [[ -n "${CONTAINER_ENGINE:-}" ]]; then
        "$CONTAINER_ENGINE" "$@"
    elif command -v podman &>/dev/null; then
        podman "$@"
    elif command -v docker &>/dev/null; then
        docker "$@"
    else
        die "need podman or docker (or set CONTAINER_ENGINE)"
    fi
}

# Every plain (non-template) shell script in the repo: *.sh files plus
# extensionless files with a sh/bash shebang (e.g. executable_md-preview).
# dot_zshrc is zsh, which shellcheck/shfmt don't support; it gets `zsh -n`.
plain_shell_scripts() {
    local f
    while IFS= read -r -d '' f; do
        case "$f" in
        *.sh) echo "$f" ;;
        *.tmpl | *.toml | *.md | *.py | *.js) ;;
        *)
            if head -n1 "$f" | grep -Eq '^#!.*(/|env )(ba)?sh\b'; then
                echo "$f"
            fi
            ;;
        esac
    done < <(find "$REPO_ROOT" \( -name .git -o -path "$TESTS_DIR/.cache" -o -path "$TESTS_DIR/.out" \) -prune \
        -o -type f -print0 | sort -z)
}
