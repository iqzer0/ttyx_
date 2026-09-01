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

# Copy and compile icons
cd data/resources

echo "Building and copy resources..."
glib-compile-resources ttyx.gresource.xml
install -Dm 644 ttyx.gresource -t "$TTYX_SHARE/resources/"

cd ../..

# Copy shell integration script
echo "Copying scripts..."
install -Dm 755 data/scripts/* -t "$TTYX_SHARE/scripts/"

# Copy color schemes
echo "Copying color schemes..."
install -Dm 644 data/schemes/* -t "$TTYX_SHARE/schemes/"

# Create/Update LINGUAS file. Uses a plain glob + basename rather than
# `find -printf`, which is a GNU extension and not available under the
# busybox/BSD `sh` this script's shebang allows.
for f in po/*.po; do
    basename "$f" .po
done | sort > po/LINGUAS

# Compile po files
echo "Copying and installing localization files"
for f in po/*.po; do
    echo "Processing $f"
    LOCALE=$(basename "$f" .po)
    msgfmt "$f" -o "$LOCALE.mo"
    install -Dm 644 "$LOCALE.mo" "$PREFIX/share/locale/$LOCALE/LC_MESSAGES/ttyx.mo"
    rm -f "$LOCALE.mo"
done

# Generate desktop file.
#
# The fallback has to be part of the condition. `set -o errexit` is active from
# the top of this script, so the old trailing `if [ $? -ne 0 ]` could never
# run: msgfmt failing aborted the whole install instead of falling back to a
# plain copy, which is exactly the case the fallback existed to handle.
if ! msgfmt --desktop --template=data/pkg/desktop/io.github.gwelr.ttyx.desktop.in -d po -o data/pkg/desktop/io.github.gwelr.ttyx.desktop; then
    echo "Note that localizing the desktop file requires a newer version of gettext, copying instead"
    cp data/pkg/desktop/io.github.gwelr.ttyx.desktop.in data/pkg/desktop/io.github.gwelr.ttyx.desktop
fi

desktop-file-validate data/pkg/desktop/io.github.gwelr.ttyx.desktop

# Inject the release history from NEWS into the appdata template.
#
# The .in file carries no <releases> of its own; NEWS is the single source of
# truth (extract-strings.sh already generates a throwaway copy this way for
# string extraction). Without this step the *installed* appdata shipped with no
# release history at all, so software centres showed no version information.
# Optional, like the po4a man pages: skipped cleanly when appstreamcli is absent.
APPDATA_IN=data/metainfo/io.github.gwelr.ttyx.appdata.xml.in
APPDATA_SRC="$APPDATA_IN"
if type appstreamcli >/dev/null 2>&1; then
    echo "Injecting release history from NEWS into appdata..."
    if appstreamcli news-to-metainfo NEWS "$APPDATA_IN" \
            data/metainfo/io.github.gwelr.ttyx.rel.appdata.xml.in >/dev/null 2>&1; then
        APPDATA_SRC=data/metainfo/io.github.gwelr.ttyx.rel.appdata.xml.in
    else
        echo "  appstreamcli could not convert NEWS, shipping appdata without release history"
    fi
else
    echo "appstreamcli not found, shipping appdata without release history"
fi

# Generate appdata file, requires gettext 0.19.7 (same errexit caveat as above)
if ! msgfmt --xml --template="$APPDATA_SRC" -d po -o data/metainfo/io.github.gwelr.ttyx.appdata.xml; then
    echo "Note that localizing appdata requires gettext 0.19.7 or later, copying instead"
    cp "$APPDATA_SRC" data/metainfo/io.github.gwelr.ttyx.appdata.xml
fi
rm -f data/metainfo/io.github.gwelr.ttyx.rel.appdata.xml.in

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

install -Dm 644 data/pkg/desktop/io.github.gwelr.ttyx.desktop -t "$PREFIX/share/applications/"
install -Dm 644 data/metainfo/io.github.gwelr.ttyx.appdata.xml -t "$PREFIX/share/metainfo/"

# Update icon cache if Prefix is /usr
if [ "$PREFIX" = '/usr' ] || [ "$PREFIX" = "/usr/local" ]; then
    echo "Updating desktop file cache"
    xdg-desktop-menu forceupdate --mode system

    echo "Updating icon cache"
    gtk-update-icon-cache -f "$PREFIX/share/icons/hicolor/"
fi
