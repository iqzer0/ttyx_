#!/bin/sh
set -e

# This script is supposed to run inside the ttyx Docker container
# on the CI system.
#
# ttyx builds with dub against the giD bindings (a source-only dub
# package fetched from the dub registry); meson was retired with the
# GtkD -> giD migration. install.sh performs the data install that
# meson's subdirs used to do (schemas, gresource, icons, po, desktop).

export DC=ldc2
echo "D compiler: $DC"
set -x
$DC --version
dub --version

#
# Build (release, same optimization intent as the old debugoptimized)
#

dub build --compiler=$DC --build=release

#
# Verify the install layout into a throwaway prefix
#

./install.sh /tmp/install_root/usr
rm -r /tmp/install_root/
