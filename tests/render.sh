#!/bin/bash
# Render matrix for one distro: renders every template inside that distro's
# container (tests/container/render.sh), then runs the host-side semantic
# checks (tests/check_rendered.py) on the rendered tree.
#
# Usage: tests/render.sh <fedora|ubuntu|debian>
set -euo pipefail
# shellcheck source=tests/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

distro="${1:?usage: tests/render.sh <distro> (one of: ${DISTROS[*]})}"
image="$(image_for "$distro")"
ensure_tools

out="$OUT_DIR/render/$distro"
rm -rf "$out"
mkdir -p "$out"

log "Rendering templates in $image"
rc=0
# The rendered tree comes back as a tar on stdout (no bind-mounted output
# dir, so no root-owned files on the host under docker).
engine run --rm --security-opt label=disable \
    -v "$REPO_ROOT:/src:ro" -v "$TOOLS_DIR:/opt/ci-bin:ro" \
    "$image" bash /src/tests/container/render.sh >"$out.tar" || rc=$?
tar -xf "$out.tar" -C "$out" || [[ $rc -ne 0 ]] || die "container produced no render output"
rm -f "$out.tar"
[[ $rc -eq 0 ]] || die "rendering failed on $distro (rendered files kept in $out)"

log "Semantic checks on the rendered output"
python3 "$TESTS_DIR/check_rendered.py" "$REPO_ROOT" "$distro" "$out"
log "render OK on $distro"
