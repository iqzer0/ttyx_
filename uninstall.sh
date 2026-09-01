#!/usr/bin/env sh

# Determine PREFIX.
if [ -z  "$1" ]; then
    export PREFIX=/usr
    # Make sure only root can run our script
    if [ "$(id -u)" != "0" ]; then
        echo "This script must be run as root" 1>&2
        exit 1
    fi
else
    export PREFIX="$1"
fi

# Every path below is quoted. Unquoted "${PREFIX}" word-split on any prefix
# containing whitespace, so `./uninstall.sh "/opt/my prefix"` expanded
# `rm -rf ${PREFIX}/share/ttyx` into `rm -rf /opt/my prefix/share/ttyx` — as
# root, that deleted /opt/my.
#
# Deliberately no `set -o errexit`: an uninstall should keep going past files a
# partial or older install never created, so removals use `rm -f` and the
# directory walks are guarded.

# prune <directory> <filename-pattern> — no-op when the directory is absent,
# which is the normal case for e.g. nautilus-python on a minimal system.
prune() {
    [ -d "$1" ] || return 0
    find "$1" -type f -name "$2" -delete
}

echo "Uninstalling from prefix ${PREFIX}"

rm -f "${PREFIX}/bin/ttyx"
rm -f "${PREFIX}/share/glib-2.0/schemas/io.github.gwelr.ttyx.gschema.xml"
if [ -d "${PREFIX}/share/glib-2.0/schemas" ]; then
    glib-compile-schemas "${PREFIX}/share/glib-2.0/schemas/"
fi
rm -rf "${PREFIX}/share/ttyx"

prune "${PREFIX}/share/locale" "ttyx.mo"
prune "${PREFIX}/share/icons/hicolor" "io.github.gwelr.ttyx.png"
prune "${PREFIX}/share/icons/hicolor" "io.github.gwelr.ttyx*.svg"

rm -f "${PREFIX}/share/nautilus-python/extensions/open-ttyx.py"
rm -f "${PREFIX}/share/dbus-1/services/io.github.gwelr.ttyx.service"
rm -f "${PREFIX}/share/applications/io.github.gwelr.ttyx.desktop"
rm -f "${PREFIX}/share/metainfo/io.github.gwelr.ttyx.appdata.xml"

# Man pages, including the po4a-translated ones under share/man/<locale>/man1.
# The old `rm ${PREFIX}/share/man/*/man1/ttyx.1.gz` failed whenever no
# translated pages were installed: an unmatched glob stays literal in POSIX sh,
# so rm was handed a path that does not exist.
prune "${PREFIX}/share/man" "ttyx.1.gz"
