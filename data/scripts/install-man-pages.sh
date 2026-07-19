#!/bin/env sh

# Determine PREFIX.
if [ -z "$1" ]; then
    if [ -z "$PREFIX" ]; then
        PREFIX='/usr'
    fi
else
    PREFIX="$1"
fi
export PREFIX

echo "Installing man pages"
install -Dm 644 'data/man/ttyx.1' "$PREFIX/share/man/man1/ttyx.1"
gzip -f "$PREFIX/share/man/man1/ttyx.1"

if type po4a-translate >/dev/null 2>&1; then
    for f in data/man/po/*.man.po; do
        LOCALE=$(basename "$f" .man.po)
        install -d "$PREFIX/share/man/$LOCALE/man1"
        po4a-translate -k 0 -f man -m data/man/ttyx.1 -p "data/man/po/$LOCALE.man.po" -l "$PREFIX/share/man/$LOCALE/man1/ttyx.1"
        gzip -f "$PREFIX/share/man/$LOCALE/man1/ttyx.1"
    done
fi
