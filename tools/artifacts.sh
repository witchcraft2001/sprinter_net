#!/usr/bin/env bash

# Central artifact manifest for build, package and floppy image scripts.
# When a new DSS utility, document, config template or bundled data file becomes
# part of the network package, add it here first.

DIST_NAME="sprinter-net"
DIST_DIR_NAME="SPNET"

# DSS application entry points. Each item maps to src/apps/<name>.asm and
# build/<UPPERCASE_NAME>.EXE. Add apps here only when their source is present.
# Planned apps include: netprobe, netcfg, netup, wget, ntp, tftp, ftp, chat,
# wterm.
BUILD_APPS=(
  netprobe
)

# Text/documentation files copied to the distribution root.
DIST_DOC_FILES=(
  specs.md
  README.md
)

# Configuration examples copied to the distribution root.
DIST_CONFIG_FILES=(
  config/NET.CFG.sample
)

# Extra files copied to the distribution root. Keep this for small required
# runtime files that are neither docs nor configs.
DIST_EXTRA_FILES=(
)
