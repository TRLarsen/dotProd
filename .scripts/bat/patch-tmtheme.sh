#!/bin/sh
# chezmoi external filter for bat themes (see .chezmoiexternal.toml): reads a
# downloaded .tmTheme on stdin and writes it to stdout with the fixes from
# its [bat_themes.<name>.patch] table in .chezmoidata.toml applied.
#
# Usage: patch-tmtheme.sh [--setting KEY VALUE | --scope SELECTOR STYLE]...
#
#   --setting  Replaces the value of KEY (e.g. gutterForeground) in the
#              theme's global settings. Fails if the theme doesn't set KEY.
#   --scope    Adds a rule for SELECTOR (a TextMate scope selector). STYLE
#              is optional font styles then a color, e.g. "bold #7aa2f7".
#              Added rules go first in the theme's rule list, because bat
#              (syntect) settles ties between equally specific selectors in
#              favor of the earlier rule. So they win over the theme's rules
#              for the same selector, but a more specific theme rule still
#              wins (use a more specific selector to beat it).
#
# Anything malformed fails (and with it `chezmoi apply`) rather than
# silently producing a broken theme.
set -eu

die() {
    echo "patch-tmtheme: $*" >&2
    exit 1
}

settings="" # newline-separated "KEY VALUE" pairs
rules=""    # XML <dict> fragments to insert

while [ $# -gt 0 ]; do
    case "$1" in
    --setting)
        [ $# -ge 3 ] || die "--setting needs KEY and VALUE"
        case "$2$3" in *[!A-Za-z0-9#]*) die "bad --setting '$2' '$3'" ;; esac
        settings="$settings$2 $3
"
        shift 3
        ;;
    --scope)
        [ $# -ge 3 ] || die "--scope needs SELECTOR and STYLE"
        selector=$2
        case "$selector" in *[!a-z0-9._,\ -]* | "") die "bad selector '$selector'" ;; esac
        color="" fontstyle=""
        for word in $3; do
            case "$word" in
            bold | italic | underline) fontstyle="${fontstyle:+$fontstyle }$word" ;;
            \#*)
                [ -z "$color" ] || die "two colors in style '$3' for '$selector'"
                case "$word" in
                \#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
                *) die "bad color '$word' for '$selector' (want #rrggbb)" ;;
                esac
                color=$word
                ;;
            *) die "unknown style word '$word' for '$selector'" ;;
            esac
        done
        [ -n "$color" ] || die "no color in style '$3' for '$selector'"
        rules="$rules<dict><key>scope</key><string>$selector</string><key>settings</key><dict><key>foreground</key><string>$color</string><key>fontStyle</key><string>$fontstyle</string></dict></dict>
"
        shift 3
        ;;
    *) die "unknown argument '$1'" ;;
    esac
done

# Buffer the whole file so that a missing settings key or an unexpected
# layout fails before anything is written. The rule list is the <array>
# under the top-level "settings" key; its first <dict> (spread over several
# lines, holding a nested <dict>) is the global settings, and the rules go
# right after it.
SETTINGS="$settings" RULES="$rules" awk '
BEGIN {
    n = split(ENVIRON["SETTINGS"], pairs, "\n")
    for (i = 1; i <= n; i++) {
        if (pairs[i] == "") continue
        split(pairs[i], kv, " ")
        want[kv[1]] = kv[2]
    }
}
{ line[NR] = $0 }
# Track <dict> nesting inside the first <array> to find where its first
# <dict> closes.
!insert_after && /<array>/ { in_array = 1 }
in_array && !insert_after {
    depth += gsub(/<dict>/, "&") - gsub(/<\/dict>/, "&")
    if (depth > 0) opened = 1
    else if (opened) insert_after = NR
}
# A wanted key: its value is the next <string> line.
match($0, /<key>[A-Za-z0-9]+<\/key>/) {
    key = substr($0, RSTART + 5, RLENGTH - 11)
    if ((key in want) && !(key in done)) pending = key
    next
}
pending != "" && /<string>/ {
    sub(/<string>[^<]*<\/string>/, "<string>" want[pending] "</string>", line[NR])
    done[pending] = 1
    pending = ""
}
END {
    for (k in want)
        if (!(k in done)) {
            print "patch-tmtheme: theme has no global setting \"" k "\"" > "/dev/stderr"
            exit 1
        }
    if (ENVIRON["RULES"] != "" && !insert_after) {
        print "patch-tmtheme: no global settings <dict> found; not a .tmTheme?" > "/dev/stderr"
        exit 1
    }
    for (i = 1; i <= NR; i++) {
        print line[i]
        if (i == insert_after) printf "%s", ENVIRON["RULES"]
    }
}'
