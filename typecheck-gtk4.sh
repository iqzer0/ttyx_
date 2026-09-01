#!/usr/bin/env bash
# Type-check individual modules against the GTK4 giD stack.
#
# Why this exists
# ---------------
# D has no partial compilation: one unresolved import and `dub build` produces
# nothing, so a wholesale GTK3 -> GTK4 port has no intermediate state where the
# tree compiles. That would mean porting ~20 interdependent files blind and
# finding out at the end.
#
# `ldc2 -o-` type-checks without codegen or linking, and it accepts a single
# module. That gives a per-file feedback loop: port one module, verify it, move
# on — instead of all-or-nothing. Errors from giD's own generated packages are
# filtered out by default since they are not ours to fix.
#
# Usage
#   ./typecheck-gtk4.sh source/gx/gtk/resource.d          # one module
#   ./typecheck-gtk4.sh $(git diff --name-only '*.d')     # everything you touched
#   ./typecheck-gtk4.sh --all                             # every module, summary only
#   RAW=1 ./typecheck-gtk4.sh <file>                      # don't filter giD-internal noise
#
# Exit status is the number of modules with errors (0 = all clean), so it works
# in a loop or as a crude progress meter during the migration.

set -o pipefail

GID_VERSION="${GID_VERSION:-0.9.13}"
GID_PACKAGES="${GID_PACKAGES:-$HOME/.dub/packages/gid/$GID_VERSION/gid/packages}"

if [ ! -d "$GID_PACKAGES" ]; then
    echo "giD packages not found at $GID_PACKAGES" >&2
    echo "Set GID_PACKAGES, or run 'dub build' once to populate ~/.dub." >&2
    exit 2
fi

# Include every giD package EXCEPT the GTK3 stack.
#
# This exclusion is load-bearing, not tidiness. gid:gtk3 and gid:gtk4 both
# provide `gtk/*.d`, gdk3/gdk4 both provide `gdk/*.d`, and vte2/vte3 both
# provide `vte/*.d`. Whichever import path is listed first wins — and "gtk3"
# sorts before "gtk4", so a naive glob silently type-checks everything against
# GTK3 and reports the port as already working. That produced a genuinely
# misleading result: StyleContext.addProviderForDisplay was rejected as "no
# property" because the GTK3 StyleContext (which only has addProviderForScreen)
# was being resolved.
#
# Everything else is included deliberately — they are import paths, not
# compiled inputs, so breadth is free and it avoids chasing transitive gaps by
# hand (harfbuzz0 needs freetype2, which is easy to miss).
GTK3_STACK_RE='/(gtk3|gdk3|vte2)$'
IMPORTS=()
for dir in "$GID_PACKAGES"/*/; do
    dir="${dir%/}"
    [ -d "$dir" ] || continue
    if printf '%s' "$dir" | grep -qE "$GTK3_STACK_RE"; then continue; fi
    IMPORTS+=("-I$dir")
done
IMPORTS+=("-Isource")

if [ "${1:-}" = "--all" ]; then
    mapfile -t FILES < <(find source -name '*.d' | sort)
    SUMMARY_ONLY=1
else
    FILES=("$@")
    SUMMARY_ONLY=0
fi

if [ ${#FILES[@]} -eq 0 ]; then
    echo "usage: $0 <module.d> [module.d ...]   |   $0 --all" >&2
    exit 2
fi

failed=0
clean=0
for f in "${FILES[@]}"; do
    case "$f" in *.d) ;; *) continue ;; esac
    [ -f "$f" ] || { echo "skip (missing): $f" >&2; continue; }

    out=$(ldc2 -o- "${IMPORTS[@]}" -verrors=0 "$f" 2>&1)
    if [ -z "${RAW:-}" ]; then
        # Drop errors originating inside giD's generated packages, and the
        # import-path dumps that follow a missing-module error.
        out=$(printf '%s\n' "$out" \
            | grep -vF "$GID_PACKAGES" \
            | grep -v '^import path\[' \
            | grep -v "^ *Expected '" )
    fi
    out=$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d')

    if [ -n "$out" ]; then
        failed=$((failed + 1))
        if [ "$SUMMARY_ONLY" = "1" ]; then
            n=$(printf '%s\n' "$out" | grep -c 'Error:')
            printf '  FAIL %-52s %s error(s)\n' "$f" "$n"
        else
            printf '=== %s ===\n%s\n' "$f" "$out"
        fi
    else
        clean=$((clean + 1))
        [ "$SUMMARY_ONLY" = "1" ] || printf '  OK   %s\n' "$f"
    fi
done

printf '\n%s clean, %s with errors\n' "$clean" "$failed"
exit $((failed > 255 ? 255 : failed))
