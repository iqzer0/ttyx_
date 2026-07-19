#!/bin/sh
# Measure RSS memory footprint of ttyx at startup.
# Runs inside the CI container after the dub build.
# Always exits 0 — this step is informational, not a gate.

set -e

RUNDATA_DIR=".rundata"
SCHEMA_DIR="data/gsettings"

# Compile GSettings schemas from source tree
glib-compile-schemas "$SCHEMA_DIR"

# Compile the gresource where ttyx expects it under XDG_DATA_DIRS
mkdir -p "$RUNDATA_DIR/ttyx/resources"
glib-compile-resources --sourcedir=data/resources \
    --target="$RUNDATA_DIR/ttyx/resources/ttyx.gresource" \
    data/resources/ttyx.gresource.xml

# Start a virtual display
Xvfb :99 -screen 0 1024x768x24 &
XVFB_PID=$!
sleep 1

# Launch ttyx with:
#   --new-process    skip D-Bus session registration (no session bus in CI)
#   GSETTINGS_BACKEND=memory  bypass dconf (no D-Bus needed for settings)
DISPLAY=:99 \
GSETTINGS_BACKEND=memory \
GSETTINGS_SCHEMA_DIR="$(pwd)/$SCHEMA_DIR" \
XDG_DATA_DIRS="$(pwd)/$RUNDATA_DIR:/usr/local/share:/usr/share" \
./ttyx --new-process &
TTYX_PID=$!

# Give the GTK app time to fully initialise
sleep 6

if kill -0 "$TTYX_PID" 2>/dev/null; then
    RSS=$(ps -o rss= -p "$TTYX_PID" | tr -d ' ')
    MB=$(( ${RSS:-0} / 1024 ))
    echo "RSS at startup: ${MB} MB (${RSS} KB)"
    kill "$TTYX_PID" 2>/dev/null || true
    wait "$TTYX_PID" 2>/dev/null || true
else
    echo "WARNING: ttyx exited before RSS could be measured (check logs above)"
fi

kill "$XVFB_PID" 2>/dev/null || true
wait "$XVFB_PID" 2>/dev/null || true

exit 0
