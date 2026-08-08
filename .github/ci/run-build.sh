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
# Build (debug): these containerized jobs exist to catch distro-specific
# dependency and link breakage, which a debug build surfaces identically.
# A release (-O3) compile of the giD bindings takes >1h on a hosted
# runner. Release-flag acceptance is guarded in the workflow's Dub job;
# actual optimized builds happen at release time per RELEASE.md.
#

dub build --compiler=$DC --build=debug

#
# Verify the install layout into a throwaway prefix
#

./install.sh /tmp/install_root/usr
rm -r /tmp/install_root/
