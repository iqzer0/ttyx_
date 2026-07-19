#!/bin/sh
set -e

# This script is supposed to run inside the ttyx Docker container
# on the CI system.
#
# dub test compiles the unittest configuration and runs every module's
# unit tests; xvfb provides a display for the GTK-touching test paths
# (test_integration.d skips its GTK cases gracefully when no display).

export DC=ldc2

#
# Run tests
#

xvfb-run -a dub test --compiler=$DC
