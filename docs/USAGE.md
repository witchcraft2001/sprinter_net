# Sprinter DSS Network Kit Usage

This package provides small Sprinter DSS utilities for the SprinterESP /
Sprinter-WiFi card with ESP8266 ESP-AT firmware.

## Utilities

- `NETCFG.EXE` shows current `NET.CFG` values.
- `NETCFG.EXE /W` edits and saves `NET.CFG`.
- `NETUP.EXE` initializes the ESP module and connects to Wi-Fi using `NET.CFG`.
- `TCPTEST.EXE` opens a TCP connection to `example.com:80` and prints a short
  HTTP response. Use it after `NETUP`.
- `PING.EXE host` checks host reachability using ESP-AT `AT+PING`.
- `NETPROBE.EXE` checks low-level UART and ESP-AT firmware response. It is a
  diagnostic tool, not a network bring-up command.
- `NETRESET.EXE` resets and reinitializes the ESP module.
- `WTERM.EXE` opens an ESP-AT terminal for manual commands.

Planned utilities include `WGET.EXE`, `NTP.EXE`, `TFTP.EXE`, `FTP.EXE`,
`CHAT.EXE` and `IRC.EXE`.

## Installation

The package is distributed as a ZIP archive or may be preinstalled with the OS.
The recommended standard location is:

```text
C:\NET
```

Keep all package programs, documentation and the runtime `NET.CFG` together in
that directory unless the OS distribution provides another system location.

For convenient use, add the network kit directory to the DSS `PATH` environment
variable. If it is not in `PATH`, change to the install directory before running
the utilities:

```text
C:
CD \NET
```

Future tools should use the same install convention and look for shared network
configuration in the common network kit location.

## First Run

1. Unpack the ZIP package to `C:\NET`, or use the OS-preinstalled copy.
2. Add `C:\NET` to `PATH`, or change to `C:\NET` before running the tools.
3. Run `NETCFG.EXE /W`.
4. Enter `SSID` and `PASS`.
5. Keep `DHCP=1` for normal home/router networks.
6. Save the configuration.
7. Run `NETUP.EXE`.
8. Run `TCPTEST.EXE` to verify real TCP access.

Typical sequence:

```text
NETCFG.EXE /W
NETUP.EXE
TCPTEST.EXE
PING.EXE example.com
```

## Configuration File

Runtime settings are stored in `NET.CFG`. The recommended location is the
network kit install directory, normally:

```text
C:\NET\NET.CFG
```

Important keys:

- `SSID` - Wi-Fi network name.
- `PASS` - Wi-Fi password, stored as clear text.
- `DHCP` - `1` for DHCP, `0` for static IP.
- `IP`, `GATEWAY`, `NETMASK` - used when `DHCP=0`.
- `DNS1`, `DNS2` - DNS servers.
- `TZ`, `NTP` - reserved for the planned time utility.

Do not distribute a real `NET.CFG` with private Wi-Fi credentials.

## Recommended Workflow

Use this order during normal testing:

1. `NETCFG.EXE` - verify saved settings.
2. `NETUP.EXE` - connect to Wi-Fi.
3. `TCPTEST.EXE` - verify TCP access.
4. `PING.EXE example.com` - verify ESP-AT ping support and host reachability.
5. Run protocol tools such as future `WGET.EXE` or `NTP.EXE`.

Use this order when something is stuck:

1. `NETRESET.EXE`
2. `NETPROBE.EXE`
3. `NETUP.EXE`
4. `TCPTEST.EXE`

## Diagnostic Notes

`NETPROBE.EXE` sends `AT`, `ATE0` and `AT+GMR`. It now retries each command once
after an ESP reset. If `NETPROBE.EXE` fails after `NETUP.EXE` and `TCPTEST.EXE`
have already succeeded, the network path may still be fine; run `NETRESET.EXE`
and repeat `NETPROBE.EXE` for a clean firmware diagnostic.

`WTERM.EXE` is useful for manual ESP-AT checks. After using the terminal, run
`NETRESET.EXE` before automated tools if the ESP stream looks confused.

## Exit Codes

Utilities return a DSS process status in the exit code register used by
`DSS_EXIT`.

Common status codes for automation-friendly utilities:

- `0` - success.
- `1` - invalid command line or usage error.
- `2` - Sprinter-WiFi hardware was not found.
- `3` - ESP communication error, timeout, unsupported command, unreachable
  host, or unexpected ESP response.
- `4` - configuration error, for example missing or invalid `NET.CFG`.

Current utility-specific notes:

- `PING.EXE` returns `0` only when `+PING:<time_ms>` was received.
- `NETUP.EXE` returns `4` when `NET.CFG` is missing, unreadable or lacks SSID.
- `NETRESET.EXE` returns `0` on successful reset/reinitialization, `2` when
  hardware is not found and `3` on ESP communication failure.

This allows DSS batch scenarios to run `PING.EXE router-or-host` before starting
another network command and stop when the status is non-zero.

## Build From Source

Host-side build commands:

```sh
make build
make package
make image
```

Generated files are written to `build/` and `distr/`.
