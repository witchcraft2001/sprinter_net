# Sprinter DSS Network Kit Usage

This package provides small Sprinter DSS utilities for the SprinterESP /
Sprinter-WiFi card with ESP8266 ESP-AT firmware.

## Utilities

- `NETCFG.EXE` shows current `NET.CFG` values.
- `NETCFG.EXE /W` edits and saves `NET.CFG`.
- `NETUP.EXE` initializes the ESP module and connects to Wi-Fi using `NET.CFG`.
- `TCPTEST.EXE [host [port [path]]]` opens a TCP connection and prints a short
  HTTP response. Use it after `NETUP`.
- `UDPTEST.EXE host port [message [local_port]]` sends one UDP datagram and
  waits for one reply. Use it before testing TFTP.
- `TFTP.EXE tftp://host[:port]/path FILE` downloads one file over TFTP.
- `TFTP.EXE /PUT FILE tftp://host[:port]/path` uploads one file over TFTP.
  `TFTP.EXE /PUT tftp://host[:port]/path FILE` is also accepted.
  `TFTP.EXE tftp://host[:port]/path PUT FILE` is accepted for DSS shells that
  pass `/PUT` as a positional token.
- `FTP.EXE host[:port] [user [password]]` verifies FTP control-channel login
  through ESP-AT multi-connection mode. Passive file transfer is not enabled yet.
- `PING.EXE host` checks host reachability using ESP-AT `AT+PING`.
- `WGET.EXE http://host[:port]/path FILE` downloads an HTTP/1.0 resource to a
  local DSS file.
- `NTP.EXE` sets DSS time using ESP-AT SNTP and the `TZ`/`NTP` values from
  `NET.CFG`.
- `NETPROBE.EXE` checks low-level UART and ESP-AT firmware response. It is a
  diagnostic tool, not a network bring-up command.
- `NETRESET.EXE` resets and reinitializes the ESP module.
- `WTERM.EXE` opens an ESP-AT terminal for manual commands.

Planned utilities include `CHAT.EXE` and `IRC.EXE`.

Each current utility also has a short standalone TXT reference file:
`NETCFG.TXT`, `NETUP.TXT`, `NETRESET.TXT`, `NETPROBE.TXT`, `TCPTEST.TXT`,
`UDPTEST.TXT`, `TFTP.TXT`, `FTP.TXT`, `PING.TXT`, `WGET.TXT`, `NTP.TXT` and
`WTERM.TXT`.

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
WGET.EXE http://example.com INDEX.HTM
NTP.EXE
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
- `TZ`, `NTP` - used by `NTP.EXE`.
- `BAUD` - UART speed used after `NETUP.EXE` configures ESP with
  `AT+UART_CUR`. Supported values: `115200`, `57600`, `38400`, `19200`,
  `9600`. Use `57600` or `38400` if `115200` loses bytes on your setup.

Do not distribute a real `NET.CFG` with private Wi-Fi credentials.

## Recommended Workflow

Use this order during normal testing:

1. `NETCFG.EXE` - verify saved settings.
2. `NETUP.EXE` - connect to Wi-Fi.
3. `TCPTEST.EXE` - verify TCP access.
4. `PING.EXE example.com` - verify ESP-AT ping support and host reachability.
5. `WGET.EXE http://example.com INDEX.HTM` - verify HTTP download.
6. `NTP.EXE` - set DSS time from ESP SNTP.
7. `UDPTEST.EXE server 7777 hello` - verify UDP echo.
8. `TFTP.EXE tftp://server/file FILE` - verify TFTP download.
9. `TFTP.EXE /PUT FILE tftp://server/file` - verify TFTP upload where the
   server permits writes.

Bundled batch examples:

- `CONNECT.BAT` runs `NETRESET.EXE`, `NETUP.EXE` and `PING.EXE 8.8.8.8`.
- `WGETGUT.BAT` tries the requested Project Gutenberg `pg1.txt` URL. It may
  fail when the server redirects plain HTTP to HTTPS; TLS is not implemented.
- `WGETCERN.BAT` downloads the short CERN home page as `CERN.HTM`.
  Keep BAT examples short; some DSS shells are sensitive to long command lines.
- `TFTPGET.BAT` and `TFTPPUT.BAT` show TFTP download/upload forms for
  `192.168.1.36`.
- `UDPECHO.BAT` runs `UDPTEST.EXE 192.168.1.36 7777 hello`.

For local receive tests, point `TCPTEST.EXE` at a small file on a local HTTP
server:

```text
TCPTEST.EXE 192.168.1.36 80 /check-2k.txt
```

Use this order when something is stuck:

1. `NETRESET.EXE`
2. `NETPROBE.EXE`
3. `NETUP.EXE`
4. `TCPTEST.EXE`

## Diagnostic Notes

Network kit utilities do not clear the screen on startup. They continue
printing at the current DSS console cursor position, so they can be used in
batch logs and command sequences without erasing previous output.

`NETPROBE.EXE` sends `AT`, `ATE0` and `AT+GMR`. It now retries each command once
after an ESP reset. If `NETPROBE.EXE` fails after `NETUP.EXE` and `TCPTEST.EXE`
have already succeeded, the network path may still be fine; run `NETRESET.EXE`
and repeat `NETPROBE.EXE` for a clean firmware diagnostic.

`WTERM.EXE` is useful for manual ESP-AT checks. After using the terminal, run
`NETRESET.EXE` before automated tools if the ESP stream looks confused.

`NETRESET.EXE` and `WTERM.EXE` are recovery/manual tools and use the default
115200 startup speed after ESP reset. Automated clients use `BAUD` from
`NET.CFG` when the file is available.

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
- `WGET.EXE` returns `0` after a successful body download, `1` for invalid
  command line or URL, `2` when hardware is not found, `3` for ESP/TCP/HTTP
  errors and `5` for local output file errors.
- `NTP.EXE` returns `0` after DSS time is set, `2` when hardware is not found
  and `3` on ESP SNTP, response parse or DSS SETTIME failure.
- `UDPTEST.EXE` returns `0` when the echoed UDP payload is received, `1` for
  invalid command line, `2` when hardware is not found and `3` on ESP/UDP
  errors.
- `TFTP.EXE` returns `0` after a successful download or upload, `1` for invalid
  command line, `2` when hardware is not found, `3` on ESP/UDP/TFTP protocol
  errors and `5` for local DSS file errors.

Current `WGET.EXE` limitations:

- Supports plain `http://` only, not HTTPS.
- If the URL has no scheme, `WGET.EXE` assumes `http://` and prints a warning.
- Uses ESP-AT passive TCP receive when available, and falls back to active
  `+IPD` receive with a warning when the firmware or emulator does not support
  `AT+CIPRECVMODE` / `AT+CIPRECVDATA`.
- Downloads HTTP 2xx responses.
- Follows absolute `http://` redirects up to five hops. HTTPS redirects are
  reported but cannot be downloaded.
- Detects chunked transfer encoding and gzip content encoding, then reports them
  as unsupported instead of writing undecodable data.

This allows DSS batch scenarios to run `PING.EXE router-or-host` before starting
another network command and stop when the status is non-zero.
