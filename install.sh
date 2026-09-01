#!/usr/bin/env sh
# exit on first error
set -o errexit

# Determine PREFIX.
if [ -z "$1" ]; then
    if [ -z "$PREFIX" ]; then
        PREFIX='/usr'
    fi
else
    PREFIX="$1"
fi
export PREFIX

if [ "$PREFIX" = "/usr" ] && [ "$(id -u)" != "0" ]; then
    # Make sure only root can run our script
    echo "This script must be run as root" 1>&2
    exit 1
fi

if [ ! -f ttyx ]; then
    echo "The ttyx executable does not exist, please run 'dub build --build=release' before using this script"
    exit 1
fi

# All generated intermediates go here, never into the source tree.
#
# This script used to write the compiled gresource, the localized .desktop and
# appdata files, and transient .mo files directly alongside their sources. Run
# under sudo — which is the normal case for the default /usr prefix — that left
# root-owned files scattered through a user-owned checkout, which then broke
# every subsequent non-root `dub build` and `./install.sh` with permission
# errors until they were manually removed.
#
# Override with BUILD_DIR=... if you want them somewhere else.
BUILD_DIR="${BUILD_DIR:-build}"
mkdir -p "$BUILD_DIR"

# Check availability of required commands.
#
# The command -> package hint is an explicit case rather than two parallel
# lists walked in lockstep by index. Two of the commands (glib-compile-schemas,
# glib-compile-resources) ship in the same package, so the old index
# arithmetic drifted by one and named the wrong package for 4 of the 7
# commands — a missing msgfmt told you to install desktop-file-utils.
COMMANDS="install glib-compile-schemas glib-compile-resources msgfmt desktop-file-validate gtk-update-icon-cache"
if [ "$PREFIX" = '/usr' ] || [ "$PREFIX" = "/usr/local" ]; then
    COMMANDS="$COMMANDS xdg-desktop-menu"
fi

package_for_command() {
    case "$1" in
        install)                                     echo 'coreutils' ;;
        glib-compile-schemas|glib-compile-resources) echo 'glib2' ;;
        msgfmt)                                      echo 'gettext' ;;
        desktop-file-validate)                       echo 'desktop-file-utils' ;;
        gtk-update-icon-cache)                       echo 'gtk-update-icon-cache' ;;
        xdg-desktop-menu)                            echo 'xdg-utils' ;;
        *)                                           echo "the package providing $1" ;;
    esac
}

for COMMAND in $COMMANDS; do
    if ! type "$COMMAND" >/dev/null 2>&1; then
        echo "Your system is missing command $COMMAND, please install $(package_for_command "$COMMAND")"
        exit 1
    fi
done

echo "Installing to prefix $PREFIX"

# Copy and compile schema
echo "Copying and compiling schema..."
install -Dm 644 data/gsettings/io.github.gwelr.ttyx.gschema.xml -t "$PREFIX/share/glib-2.0/schemas/"
glib-compile-schemas "$PREFIX/share/glib-2.0/schemas/"

export TTYX_SHARE="$PREFIX/share/ttyx"

# Compile and install the gresource bundle. --sourcedir lets us build straight
# into $BUILD_DIR instead of cd-ing into data/resources and emitting the
# artifact next to its own source.
echo "Building and copy resources..."
glib-compile-resources --sourcedir=data/resources \
    --target="$BUILD_DIR/ttyx.gresource" \
    data/resources/ttyx.gresource.xml
install -Dm 644 "$BUILD_DIR/ttyx.gresource" -t "$TTYX_SHARE/resources/"

# Copy shell integration script
echo "Copying scripts..."
install -Dm 755 data/scripts/* -t "$TTYX_SHARE/scripts/"

# Copy color schemes
echo "Copying color schemes..."
install -Dm 644 data/schemes/* -t "$TTYX_SHARE/schemes/"

# Note: po/LINGUAS is deliberately NOT regenerated here. It is a tracked file
# that nothing in this script reads, and extract-strings.sh — which owns the
# translation workflow — already regenerates it. Rewriting a tracked source
# file as a side effect of installing is not this script's business.

# Compile po files
echo "Copying and installing localization files"
for f in po/*.po; do
    echo "Processing $f"
    LOCALE=$(basename "$f" .po)
    # Transient .mo went into the repo root before; keep it in $BUILD_DIR.
    msgfmt "$f" -o "$BUILD_DIR/$LOCALE.mo"
    install -Dm 644 "$BUILD_DIR/$LOCALE.mo" "$PREFIX/share/locale/$LOCALE/LC_MESSAGES/ttyx.mo"
    rm -f "$BUILD_DIR/$LOCALE.mo"
done

# Generate desktop file.
#
# The fallback has to be part of the condition. `set -o errexit` is active from
# the top of this script, so the old trailing `if [ $? -ne 0 ]` could never
# run: msgfmt failing aborted the whole install instead of falling back to a
# plain copy, which is exactly the case the fallback existed to handle.
DESKTOP_OUT="$BUILD_DIR/io.github.gwelr.ttyx.desktop"
if ! msgfmt --desktop --template=data/pkg/desktop/io.github.gwelr.ttyx.desktop.in -d po -o "$DESKTOP_OUT"; then
    echo "Note that localizing the desktop file requires a newer version of gettext, copying instead"
    cp data/pkg/desktop/io.github.gwelr.ttyx.desktop.in "$DESKTOP_OUT"
fi

desktop-file-validate "$DESKTOP_OUT"

# Inject the release history from NEWS into the appdata template.
#
# The .in file carries no <releases> of its own; NEWS is the single source of
# truth (extract-strings.sh already generates a throwaway copy this way for
# string extraction). Without this step the *installed* appdata shipped with no
# release history at all, so software centres showed no version information.
# Optional, like the po4a man pages: skipped cleanly when appstreamcli is absent.
APPDATA_IN=data/metainfo/io.github.gwelr.ttyx.appdata.xml.in
APPDATA_SRC="$APPDATA_IN"
# The intermediate keeps the .appdata.xml.in suffix: msgfmt --xml picks its ITS
# translation rules from the file NAME, and anything else (e.g. a .rel.in tail)
# makes it fail with "cannot locate ITS rules".
APPDATA_REL="$BUILD_DIR/io.github.gwelr.ttyx.rel.appdata.xml.in"
APPDATA_OUT="$BUILD_DIR/io.github.gwelr.ttyx.appdata.xml"
if type appstreamcli >/dev/null 2>&1; then
    echo "Injecting release history from NEWS into appdata..."
    if appstreamcli news-to-metainfo NEWS "$APPDATA_IN" "$APPDATA_REL" >/dev/null 2>&1; then
        APPDATA_SRC="$APPDATA_REL"
    else
        echo "  appstreamcli could not convert NEWS, shipping appdata without release history"
    fi
else
    echo "appstreamcli not found, shipping appdata without release history"
fi

# Generate appdata file, requires gettext 0.19.7 (same errexit caveat as above)
if ! msgfmt --xml --template="$APPDATA_SRC" -d po -o "$APPDATA_OUT"; then
    echo "Note that localizing appdata requires gettext 0.19.7 or later, copying instead"
    cp "$APPDATA_SRC" "$APPDATA_OUT"
fi
rm -f "$APPDATA_REL"

# Copying Nautilus extension
echo "Copying Nautilus extension"
install -Dm 644 data/nautilus/open-ttyx.py -t "$PREFIX/share/nautilus-python/extensions/"

# Copy D-Bus service descriptor
install -Dm 644 data/dbus/io.github.gwelr.ttyx.service -t "$PREFIX/share/dbus-1/services/"

# Copy man page (quoted: an unquoted command substitution here word-split on
# any repository path containing whitespace)
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
. "${SCRIPT_DIR}/data/scripts/install-man-pages.sh"

# Copy Icons
cd data/icons/hicolor

find . -type f | while IFS= read -r f; do
    install -Dm 644 "$f" "$PREFIX/share/icons/hicolor/$f"
done

cd ../../..

# Copy executable, desktop and appdata file
install -Dm 755 ttyx -t "$PREFIX/bin/"

install -Dm 644 "$DESKTOP_OUT" -t "$PREFIX/share/applications/"
install -Dm 644 "$APPDATA_OUT" -t "$PREFIX/share/metainfo/"

# Update icon cache if Prefix is /usr
if [ "$PREFIX" = '/usr' ] || [ "$PREFIX" = "/usr/local" ]; then
    echo "Updating desktop file cache"
    xdg-desktop-menu forceupdate --mode system

    echo "Updating icon cache"
    gtk-update-icon-cache -f "$PREFIX/share/icons/hicolor/"
fi
