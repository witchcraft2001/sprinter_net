#!/usr/bin/env bash

# Central artifact manifest for build, package and floppy image scripts.
# When a new DSS utility, document, config template or bundled data file becomes
# part of the network package, add it here first.

DIST_NAME="sprinter-net"
DIST_DIR_NAME="SPNET"

# DSS application entry points. Each item maps to src/apps/<name>.asm and
# build/<UPPERCASE_NAME>.EXE. Add apps here only when their source is present.
# Planned apps include: wget, ntp, tftp, ftp and chat.
BUILD_APPS=(
  netprobe
  netreset
  netcfg
  netup
  tcptest
  udptest
  ping
  wget
  ntp
  tftp
  wterm
)

# Text/documentation files copied to the distribution root.
DIST_DOC_FILES=(
  README.md
  docs/USAGE.md
  docs/NETCFG.TXT
  docs/NETUP.TXT
  docs/NETRESET.TXT
  docs/NETPROBE.TXT
  docs/TCPTEST.TXT
  docs/UDPTEST.TXT
  docs/PING.TXT
  docs/WGET.TXT
  docs/NTP.TXT
  docs/TFTP.TXT
  docs/WTERM.TXT
  LICENSE
)

# Configuration examples copied to the distribution root.
DIST_CONFIG_FILES=(
  config/NET.CFG.sample
)

# Extra files copied to the distribution root. Keep this for small required
# runtime files that are neither docs nor configs.
DIST_EXTRA_FILES=(
  examples/CONNECT.BAT
  examples/WGETGUT.BAT
  examples/WGETCERN.BAT
  examples/TFTPGET.BAT
  examples/TFTPPUT.BAT
  examples/UDPECHO.BAT
  examples/UDP_ECHO.PY
)
