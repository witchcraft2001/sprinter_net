# Sprinter DSS Network Kit Plan

## Goal

Build a package of Sprinter DSS network utilities for the SprinterESP Wi-Fi card
based on ESP12-F/ESP8266 with ESP-AT firmware.

The package must provide a shared networking foundation instead of independent
programs that each ask for Wi-Fi credentials or implement their own ESP-AT
parsing.

Initial target utilities:

- `netcfg.exe` / `wcfg.exe` - shared Wi-Fi and TCP/IP configuration.
- `netup.exe` - initialize SprinterESP and bring the configured network up.
- `tcptest.exe` - temporary TCP smoke test for the shared TCP client core.
- `udptest.exe` - temporary UDP smoke test for the shared UDP client core.
- `ping.exe` - host reachability and latency diagnostic.
- `wget.exe` - simple HTTP downloader.
- `ntp.exe` - set DSS time from network time.
- `tftp.exe` - simple TFTP client.
- `ftp.exe` - simple passive-mode FTP client.
- `chat.exe` / `irc.exe` - simplest text chat client.
- `wterm.exe` - diagnostic ESP-AT terminal.

Later expansion targets:

- Simple text web browser.
- Download manager.
- Simple mail client.
- Simple local web server, if practical with ESP-AT and Sprinter memory limits.

## Hardware And Platform Assumptions

- SprinterESP is exposed as a TL16C550 UART on ISA COM3, base port `0x03E8`,
  memory mapped at `0xC3E8` through Sprinter ISA access.
- Default UART mode is `115200,8,1,0,3`, with runtime `NET.CFG` override via
  `BAUD=115200|57600|38400|19200|9600`.
- Hardware RTS/CTS flow control is required for reliable operation at 115200.
- ESP firmware baseline is ESP8266 ESP-AT 2.2.1 or compatible.
- DSS programs use standard DSS EXE format and DSS file APIs.
- DSS filesystem uses FAT-style 8.3 names; paths use backslash.

### ESP8266 ESP-AT V2.2.1 Command Support

The local baseline package `/Users/dmitry/Downloads/V2.2.1` contains only short
flashing READMEs, so command availability was checked against ASCII command
tokens in the AT firmware binaries under `bin/at/`. The 512+512 and 1024+1024
AT binaries expose the same relevant command set.

Project-critical commands present in the V2.2.1 AT binaries:

- Basic and system:
  `AT`, `ATE0`, `AT+GMR`, `AT+RST`, `AT+RESTORE`, `AT+SLEEP`, `AT+GSLP`,
  `AT+SYSMSG`, `AT+SYSRAM`, `AT+SYSADC`, `AT+RFPOWER`, `AT+RFVDD`.
- UART:
  `AT+UART`, `AT+UART_CUR`, `AT+UART_DEF`, `AT+IPR`.
- Wi-Fi station/AP:
  `AT+CWMODE`, `AT+CWMODE_CUR`, `AT+CWMODE_DEF`, `AT+CWJAP`,
  `AT+CWJAP_CUR`, `AT+CWJAP_DEF`, `AT+CWQAP`, `AT+CWLAP`,
  `AT+CWLAPOPT`, `AT+CWAUTOCONN`, `AT+CWHOSTNAME`, `AT+CIFSR`,
  `AT+CWSAP`, `AT+CWSAP_CUR`, `AT+CWSAP_DEF`, `AT+CWLIF`,
  `AT+CWCOUNTRY_CUR`, `AT+CWCOUNTRY_DEF`.
- IP, DHCP and DNS:
  `AT+CIPSTA`, `AT+CIPSTA_CUR`, `AT+CIPSTA_DEF`, `AT+CIPAP`,
  `AT+CIPAP_CUR`, `AT+CIPAP_DEF`, `AT+CIPSTAMAC`,
  `AT+CIPSTAMAC_CUR`, `AT+CIPSTAMAC_DEF`, `AT+CIPAPMAC`,
  `AT+CIPAPMAC_CUR`, `AT+CIPAPMAC_DEF`, `AT+CWDHCP`,
  `AT+CWDHCP_CUR`, `AT+CWDHCP_DEF`, `AT+CWDHCPS_CUR`,
  `AT+CWDHCPS_DEF`, `AT+CIPDNS_CUR`, `AT+CIPDNS_DEF`.
- TCP/UDP/SSL:
  `AT+CIPSTART`, `AT+CIPCLOSE`, `AT+CIPSEND`, `AT+CIPSENDEX`,
  `AT+CIPSENDBUF`, `AT+CIPMUX`, `AT+CIPMODE`, `AT+CIPSTATUS`,
  `AT+CIPSERVER`, `AT+CIPSERVERMAXCONN`, `AT+CIPSTO`, `AT+CIPDINFO`,
  `AT+CIPDOMAIN`, `AT+CIPSSLSIZE`, `AT+CIPALIVE`, `AT+CIPBUFRESET`,
  `AT+CIPBUFSTATUS`, `AT+CIPCHECKQUEUE`, `AT+CIPCHECKSEQ`.
- Diagnostics, time and update:
  `AT+PING`, `AT+CIPSNTPCFG`, `AT+CIPSNTPTIME`, `AT+CIUPDATE`,
  `AT+MDNS`, `AT+WPS`.

Commands not present in the checked V2.2.1 binaries:

- `AT+CIPRECVMODE`
- `AT+CIPRECVDATA`

Implication: ESP-AT passive TCP receive is not available on the current V2.2.1
baseline. `wget.exe` may probe passive mode and fall back, but the reliable path
for this firmware must remain active `+IPD,<len>:<payload>` receive with correct
UART flow control and/or conservative receive pacing.

Multi-connection support is present in the checked V2.2.1 firmware. The binary
contains `AT+CIPMUX`, link-id `AT+CIPSTART`/`AT+CIPSEND` response formats and
`+IPD,<link>,<len>:<payload>` forms. FTP and future server-mode tools may use
`AT+CIPMUX=1`, but existing single-connection tools should keep `AT+CIPMUX=0`
unless they explicitly need parallel control/data sockets. Multi-connection
helpers must stay outside the common TCP include and live in
`src/lib/esp_tcp_multi.asm` so simple tools do not pay for unused code.

## Emulator Requirements

Primary emulation target is MAME Sprinter with `jesperl` acting as an ESP-AT
network peer.

Required behavior:

- Emulate TL16C550 receive timing closely enough that DSS code cannot receive
  large ESP bursts faster than the configured UART speed would allow.
- Respect or model hardware flow control state used by the SprinterESP stack:
  TL16C550 `MCR_AFE | MCR_RTS` on the Sprinter side and ESP-AT
  `AT+UART_CUR=<baud>,8,1,0,3` on the ESP side.
- Support configurable `+IPD` chunk size. The default for MAME debugging should
  be conservative, for example 256 or 512 payload bytes, while a stress mode may
  keep 1500 byte bursts.
- Support configurable pacing when sending data toward MAME/Z80, for example a
  short delay after each small output slice. This models physical UART delivery
  and avoids unrealistic instantaneous socket-to-UART bursts.
- Keep `AT+CIPSTART` non-blocking or bounded by a short explicit timeout. ESP
  reset and close commands must be able to abort a pending connection attempt.
- Preserve ESP-AT framing exactly: `+IPD,<len>:<payload>` or
  `+IPD,<link>,<len>:<payload>`, `SEND OK`, `CLOSED`, final `OK`/`ERROR`, and
  CRLF line endings.
- Support ESP SNTP commands used by the time utility:
  `AT+CIPSNTPCFG=1,<tz>,"server"` and `AT+CIPSNTPTIME?`, returning a realistic
  `+CIPSNTPTIME:<weekday> <month> <day> <hh:mm:ss> <year>` line.
- Provide deterministic test knobs, for example `JESPERL_IPD_CHUNK` and
  `JESPERL_Z_PACE_US`, so regressions can be reproduced.

Rationale:

- Real ESP modules send bytes through a physical UART and can be throttled by
  RTS/CTS. A host-side emulator that writes a full TCP packet to MAME
  immediately can overflow the emulated UART/FIFO or expose missing MAME flow
  control emulation, causing lost bytes and corrupted downloads.
- Smaller `+IPD` chunks do not violate ESP-AT semantics: clients must already
  handle multiple `+IPD` frames. Large chunks are still useful as stress tests
  after the transport layer is stable.

## Design Principles

- One shared config file is the source of truth for all tools.
- Avoid asking for SSID/password in every utility.
- Prefer ESP-AT current-session commands (`*_CUR`) for normal operation to avoid
  unnecessary ESP flash writes.
- Do not reset ESP on every program start unless recovery requires it.
- Keep protocol implementations separate from UART/AT transport.
- Treat received TCP/UDP data as binary, not ASCIIZ strings.
- Return meaningful DSS exit status from utilities that can be used by
  automation/batch scenarios.
- Do not clear the DSS console on startup; tools should append output at the
  current cursor position for scripts and logs.
- Do not store large zero-filled work buffers in EXE files. Runtime command,
  URL, packet, TCP/UDP receive and configuration buffers must be defined as
  explicit BSS memory maps (`EQU` ranges) and initialized at startup only when
  needed.
- Keep DSS file read/write buffers below the `0xC000` banking window unless the
  code explicitly handles page switching. Larger future buffers should use DSS
  paged memory mapped into `WIN0`-`WIN3`, not static EXE space.
- Make the first implementation narrow and reliable before adding protocol
  features.

## Proposed File Layout

```text
src/
  include/
    dss.inc
    sprinter.inc
    macro.inc
  lib/
    isa.asm
    uart16550.asm
    esp_at.asm
    esp_net.asm
    esp_tcp.asm
    netcfg.asm
    fileio.asm
    url.asm
    text.asm
  apps/
    netcfg.asm
    netup.asm
    tcptest.asm
    ping.asm
    wget.asm
    ntp.asm
    tftp.asm
    ftp.asm
    chat.asm
    wterm.asm
docs/
  esp-at-notes.md
  testing.md
specs.md
```

The exact layout can change after the first implementation pass, but the module
boundaries should stay close to this shape.

## Shared Configuration

Recommended package install directory:

```text
C:\NET
```

The directory should contain the network utilities, user-facing documentation
and runtime `NET.CFG`. OS distributions may preinstall the package elsewhere,
but all tools should share one package/config location instead of each utility
inventing its own.

Users should add the package directory to the DSS `PATH` environment variable,
or change to that directory before running the tools.

Default config path for the first implementation:

```text
NET.CFG
```

Optional future search order:

```text
.\NET.CFG
C:\NET\NET.CFG
```

Initial text format:

```ini
SSID=MyWifi
PASS=secret
DHCP=1
IP=
GATEWAY=
NETMASK=
DNS1=1.1.1.1
DNS2=8.8.8.8
TZ=+6
NTP=pool.ntp.org
AUTOJOIN=1
```

Rules:

- Unknown keys are ignored.
- Missing keys use safe defaults.
- `PASS` may be empty for open networks.
- Static IP fields are used only when `DHCP=0`.
- `TZ` is used by `ntp.exe` and by ESP SNTP setup.
- Future versions may add profiles, but v1 uses one active profile.

Security note: `NET.CFG` stores the Wi-Fi password in clear text because DSS has
no practical secret storage. Documentation and `.gitignore` must warn against
committing real credentials.

## Shared Library Layers

### `isa.asm` / `uart16550.asm`

Responsibilities:

- Find SprinterESP UART.
- Open/close ISA memory window.
- Initialize TL16C550.
- Read/write UART registers.
- Send and receive bytes with timeout.
- Reset RX/TX FIFO.
- Detect receiver errors.

Existing reference:

- `../ESPKit/sources/DSS/isa.asm`
- `../ESPKit/sources/DSS/esplib.asm`

### `esp_at.asm`

Responsibilities:

- Send plain AT commands.
- Wait for final status: `OK`, `ERROR`, `FAIL`.
- Wait for `>` prompt after `AT+CIPSEND`.
- Wait for `SEND OK`.
- Parse asynchronous text events: `CONNECT`, `CLOSED`, `WIFI CONNECTED`,
  `WIFI DISCONNECT`.
- Provide bounded line reading for command responses.

Important constraint:

- This layer is for AT control lines only. It must not be used as a generic
  TCP/UDP payload parser.

### `esp_net.asm`

Responsibilities:

- `net_init`
- `net_ensure_wifi`
- `tcp_open`
- `tcp_send`
- `tcp_recv`
- `tcp_close`
- `udp_open`
- `udp_send`
- `udp_recv`
- `udp_close`
- `dns_resolve` where useful
- `ping_host` using ESP-AT `AT+PING` when firmware supports it
- `sntp_enable`
- `sntp_get_time`

Payload parser:

- Parse `+IPD,<len>:<data>` in single-connection mode.
- Parse `+IPD,<link>,<len>:<data>` in multi-connection mode.
- Read exactly `<len>` bytes into a caller buffer or stream callback.
- Preserve binary bytes including `0x00`, CR and LF.

## Development Stages

### Stage 0 - Repository Foundation

- [x] Create high-level plan in `specs.md`.
- [x] Add `.gitignore` for generated binaries, temporary build outputs and
  local `NET.CFG`.
- [x] Add build, package and floppy image scripts.
- [x] Add a shared artifact manifest for future distributable files.
- [x] Add example BAT files to the package and test floppy image.
- [x] Decide initial source layout and copy/import only the needed DSS support
  files from `ESPKit`.
- [x] Add a short `README.md` with scope, build commands and current status.

Done when:

- The repository has a clear layout.
- Local credentials and build products are ignored.
- A new contributor can see where libraries and apps will live.

### Stage 1 - Hardware, UART And AT Healthcheck

- [x] Port or copy minimal `isa.asm`, UART definitions and utility code.
- [x] Implement a small `netprobe.exe`.
- [x] Detect SprinterESP in ISA slot.
- [x] Initialize UART at 115200 8N1 RTS/CTS by default.
- [x] Support runtime UART speed selection through `BAUD` in `NET.CFG`.
- [x] Send `AT`, `ATE0`, `AT+GMR`.
- [x] Retry each probe command once after ESP reset to recover from a confused
  UART/AT stream.
- [x] Report firmware version and UART status.
- [x] Provide `netreset.exe` for manual ESP reset/reinitialization.
- [x] Keep `wterm.exe` or equivalent terminal for manual diagnostics.

Done when:

- `netprobe.exe` assembles.
- It can find real or emulated SprinterESP.
- It prints ESP-AT version and exits with DSS error code on failure.

Manual tests:

```sh
sjasmplus src/apps/netprobe.asm
```

Then run on MAME+jesperl and real hardware where available.

### Stage 2 - Shared Config Reader/Writer

- [x] Implement `NET.CFG` parser.
- [x] Implement config defaults.
- [x] Implement config writer.
- [x] Implement `netcfg.exe` skeleton.
- [x] Allow manual SSID/password/DHCP/DNS/TZ entry.
- [x] Allow displaying current saved configuration.
- [x] Warn before writing password to disk.

Done when:

- `netcfg.exe` can create and update `NET.CFG`.
- Library callers can load config into a fixed-size structure.
- Bad or partial config files fail predictably or fall back to defaults.

### Stage 3 - Wi-Fi Bring-Up

- [x] Implement initial `net_ensure_wifi` flow inside `netup.exe`.
- [x] Use `AT+CWMODE_CUR=1`.
- [x] Use `AT+CWJAP?` to display existing connection state.
- [x] Use `AT+CWJAP_CUR="ssid","password"` to connect.
- [x] Apply current-session ESP UART flow-control settings before network
  commands so `netup.exe` does not depend on a previous `netreset.exe`.
- [x] Apply configured current-session ESP UART speed with `AT+UART_CUR`.
- [x] Apply DHCP/static IP settings.
- [x] Apply DNS settings where supported.
- [x] Prefer `_CUR` ESP-AT commands and use legacy commands only as fallback.
- [x] Implement `netup.exe`.
- [x] Display current AP state and IP information.
- [x] Treat final `AT+CIFSR` IP display as optional diagnostics, not as a
  connection failure.
- [x] Fall back to `AT+CIPSTA_CUR?` and `AT+CIPSTA?` when `AT+CIFSR` does not
  answer in firmware or emulator.

Done when:

- `netup.exe` brings the network up using only `NET.CFG`.
- Re-running `netup.exe` does not ask for credentials when already connected.
- Normal startup does not reset ESP unnecessarily.

### Stage 4 - TCP Client Core

- [x] Implement initial single-connection TCP open/send/receive/close.
- [x] Support `AT+CIPMUX=0`.
- [x] Support `AT+CIPSTART="TCP","host",port`.
- [x] Support `AT+CIPSEND=<len>` and `SEND OK`.
- [x] Implement initial `+IPD,<len>:` binary parser.
- [x] Preserve oversized `+IPD` payloads across multiple `TCP.RECEIVE` calls
  instead of dropping bytes beyond the caller buffer.
- [x] Handle `CLOSED`, timeout and receiver errors.
- [x] Add `tcptest.exe` as a small TCP test utility.

Done when:

- A utility can connect to a simple HTTP server, send bytes and save raw response.
- Binary payload reading is length-based and not string-based.

### Stage 5 - `ping.exe` Network Diagnostic

- [x] Check whether target ESP-AT firmware supports `AT+PING="host"`.
- [x] Add `jesperl` support for `AT+PING="host"` before relying on emulator
  results.
- [x] Implement `ping.exe host`.
- [x] Parse successful `+PING:<time_ms>` responses.
- [x] Print clear timeout/error output when ICMP is unavailable or host fails.
- [x] Return DSS exit status suitable for batch/script checks.
- [ ] Consider optional TCP connect fallback for hosts/firmware without
  `AT+PING`, but label it as TCP reachability, not ICMP ping.

Done when:

- `ping.exe example.com` reports latency or a clear ESP-AT unsupported/error
  status.
- The utility does not require Wi-Fi credentials and expects `NETUP` to have
  already configured the network.

### Stage 6 - `wget.exe` HTTP Downloader

- [x] Parse `http://host[:port]/path`.
- [x] Generate HTTP/1.0 GET request.
- [x] Send `Host`, `Connection: close`, `Accept-Encoding: identity`.
- [x] Receive response through TCP core.
- [x] Use ESP-AT passive receive mode for WGET when supported.
- [ ] Add `jesperl` support for `AT+CIPRECVMODE` and `AT+CIPRECVDATA`.
- [x] Parse status line.
- [x] Follow absolute `http://` redirects up to a small fixed limit.
- [x] Skip headers and write body to DSS file.
- [x] Print basic progress while body chunks are written.
- [x] Keep WGET receive/write buffers below the `0xC000` banking window.
- [x] Move WGET and shared NET.CFG work buffers out of the EXE image into
  runtime BSS address ranges.
- [ ] Clearly report unsupported HTTPS redirects, chunked transfer and gzip.

Done when:

- `wget.exe http://host/file.bin FILE.BIN` downloads a file.
- Output file is byte-identical for non-chunked, non-gzip HTTP/1.0 responses.

### Stage 7 - Network Time

- [x] Implement `ntp.exe` using ESP SNTP first.
- [x] Configure SNTP with `AT+CIPSNTPCFG=1,<tz>`.
- [x] Read time with `AT+CIPSNTPTIME?`.
- [x] Parse ESP time string.
- [x] Set DSS time through `DSS SETTIME`.
- [ ] Add `jesperl` support for ESP SNTP commands before emulator validation.
- [ ] Optionally add raw UDP NTP later.

Done when:

- `ntp.exe` reads `TZ` and `NTP` from `NET.CFG`.
- DSS time is updated and displayed.

### Stage 8 - UDP Core And TFTP

- [x] Add `udptest.exe` as a small UDP test utility.
- [x] Implement initial UDP open/send/receive/close.
- [x] Add `jesperl` support for UDP `CIPSTART`/`CIPSEND`/`+IPD`/`CIPSTATUS`.
- [x] Determine initial ESP-AT behavior for UDP reply port changes using mode 2.
- [x] Complete initial TFTP RRQ download.
- [x] Complete TFTP WRQ upload.
- [x] Implement DATA/ACK block state machine for RRQ.
- [x] Implement basic timeout and retry for RRQ.
- [x] Handle TFTP ERROR packets for RRQ.
- [x] Keep RFC 1350 baseline first; add options later only if needed.

Done when:

- `tftp.exe tftp://server/file FILE` downloads from a standard TFTP server.
- `tftp.exe /PUT FILE tftp://server/file` uploads where server permits writes.
  `tftp.exe /PUT tftp://server/file FILE` is accepted as an alternate order.
  `tftp.exe tftp://server/file PUT FILE` is accepted as a DSS compatibility form.

### Stage 9 - Passive FTP

- [x] Confirm ESP-AT V2.2.1 firmware exposes multi-connection commands and
  link-id response formats.
- [ ] Enable multi-connection mode with `AT+CIPMUX=1`.
- [x] Add initial link-aware TCP open/send/receive/close helpers in a separate
  `esp_tcp_multi.asm` include.
- [ ] Implement FTP control channel line parser.
- [ ] Support `USER`, `PASS`, `TYPE I`, `PASV`, `RETR`, `STOR`, `LIST`, `QUIT`.
- [ ] Parse `227 Entering Passive Mode (...)`.
- [ ] Download through data connection.
- [ ] Upload through data connection.
- [ ] Close data and control links cleanly.

Done when:

- `ftp.exe` can login to a simple FTP server in passive mode.
- Binary download and upload work for small and medium files.

### Stage 10 - Text Chat / IRC Baseline

- [ ] Implement a simple TCP line client first.
- [ ] Add reconnect and keepalive.
- [ ] Add screen UI suitable for 80x32 text mode.
- [ ] Add optional IRC mode: `NICK`, `USER`, `JOIN`, `PRIVMSG`, `PING/PONG`.
- [ ] Keep TLS/SASL out of the first implementation.

Done when:

- `chat.exe` can connect to a known plaintext TCP chat endpoint.
- Optional `irc.exe` can join a plaintext IRC server/channel.

### Stage 11 - Browser And Download Manager

- [ ] Reuse HTTP downloader core.
- [ ] Add simple HTML/text rendering.
- [ ] Add link extraction and navigation.
- [ ] Add partial UTF-8 handling or transliteration strategy.
- [ ] Add download queue/resume only after stable HTTP range support.

Done when:

- A small text page can be fetched, displayed and navigated.

### Stage 12 - Optional Local Web Server

- [ ] Evaluate ESP-AT `CIPSERVER` on real hardware.
- [ ] Implement multi-connection server event parser.
- [ ] Serve a tiny static response in LAN.
- [ ] Define practical connection and memory limits.

Done when:

- A browser on the same LAN can fetch a simple page from Sprinter.

## Testing Matrix

Each completed stage should be tested on at least one target:

- MAME Sprinter + local `jesperl`.
- Real Sprinter hardware + SprinterESP.
- ESP8266 ESP-AT 2.2.1 firmware.

Current known emulator gap:

- `jesperl` supports only a subset of ESP-AT and may need extension before TCP,
  UDP, SNTP or multi-connection tests are realistic.

## Open Questions

- Should the package use `NET.CFG` in current directory only, or a fixed system
  directory once the repo has install scripts?
- Should normal connection use `CWJAP_CUR` only, or provide an explicit
  `netcfg /save-to-esp` mode for `CWJAP_DEF` and `CWAUTOCONN=1`?
- Which assembler layout is preferable: include modules directly per app, or
  prebuild shared relocatable-like fragments where possible?
- How much UTF-8/CP866 conversion should be in v1?
- Is HTTPS via ESP8266 AT stable enough to expose in `wget.exe`, or should it be
  deferred behind a proxy recommendation?
