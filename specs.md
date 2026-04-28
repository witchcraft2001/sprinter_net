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
- Default UART mode is `115200,8,1,0,3`.
- Hardware RTS/CTS flow control is required for reliable operation at 115200.
- ESP firmware baseline is ESP8266 ESP-AT 2.2.1 or compatible.
- DSS programs use standard DSS EXE format and DSS file APIs.
- DSS filesystem uses FAT-style 8.3 names; paths use backslash.

## Design Principles

- One shared config file is the source of truth for all tools.
- Avoid asking for SSID/password in every utility.
- Prefer ESP-AT current-session commands (`*_CUR`) for normal operation to avoid
  unnecessary ESP flash writes.
- Do not reset ESP on every program start unless recovery requires it.
- Keep protocol implementations separate from UART/AT transport.
- Treat received TCP/UDP data as binary, not ASCIIZ strings.
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
    netcfg.asm
    fileio.asm
    url.asm
    text.asm
  apps/
    netcfg.asm
    netup.asm
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

Default config path:

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
- [x] Initialize UART at 115200 8N1 RTS/CTS.
- [x] Send `AT`, `ATE0`, `AT+GMR`.
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
- [x] Apply DHCP/static IP settings.
- [x] Apply DNS settings where supported.
- [x] Implement `netup.exe`.
- [x] Display current AP state and IP information.

Done when:

- `netup.exe` brings the network up using only `NET.CFG`.
- Re-running `netup.exe` does not ask for credentials when already connected.
- Normal startup does not reset ESP unnecessarily.

### Stage 4 - TCP Client Core

- [ ] Implement single-connection TCP open/send/receive/close.
- [ ] Support `AT+CIPMUX=0`.
- [ ] Support `AT+CIPSTART="TCP","host",port`.
- [ ] Support `AT+CIPSEND=<len>` and `SEND OK`.
- [ ] Implement robust `+IPD,<len>:` binary parser.
- [ ] Handle `CLOSED`, timeout and receiver errors.
- [ ] Add a small TCP test utility if useful.

Done when:

- A utility can connect to a simple HTTP server, send bytes and save raw response.
- Binary payload reading is length-based and not string-based.

### Stage 5 - `wget.exe` HTTP Downloader

- [ ] Parse `http://host[:port]/path`.
- [ ] Generate HTTP/1.0 GET request.
- [ ] Send `Host`, `Connection: close`, `Accept-Encoding: identity`.
- [ ] Receive response through TCP core.
- [ ] Parse status line.
- [ ] Skip headers and write body to DSS file.
- [ ] Print progress by bytes received.
- [ ] Reject or clearly report unsupported redirects, chunked transfer and gzip.

Done when:

- `wget.exe http://host/file.bin FILE.BIN` downloads a file.
- Output file is byte-identical for non-chunked, non-gzip HTTP/1.0 responses.

### Stage 6 - Network Time

- [ ] Implement `ntp.exe` using ESP SNTP first.
- [ ] Configure SNTP with `AT+CIPSNTPCFG=1,<tz>`.
- [ ] Read time with `AT+CIPSNTPTIME?`.
- [ ] Parse ESP time string.
- [ ] Set DSS time through `DSS SETTIME`.
- [ ] Optionally add raw UDP NTP later.

Done when:

- `ntp.exe` reads `TZ` and `NTP` from `NET.CFG`.
- DSS time is updated and displayed.

### Stage 7 - UDP Core And TFTP

- [ ] Implement UDP open/send/receive/close.
- [ ] Determine reliable ESP-AT behavior for UDP reply port changes.
- [ ] Complete TFTP RRQ download.
- [ ] Complete TFTP WRQ upload.
- [ ] Implement DATA/ACK block state machine.
- [ ] Implement timeout and retry.
- [ ] Handle TFTP ERROR packets.
- [ ] Keep RFC 1350 baseline first; add options later only if needed.

Done when:

- `tftp.exe tftp://server/file FILE` downloads from a standard TFTP server.
- `tftp.exe FILE tftp://server/file` uploads where server permits writes.

### Stage 8 - Passive FTP

- [ ] Enable multi-connection mode with `AT+CIPMUX=1`.
- [ ] Implement link-aware TCP open/send/receive/close.
- [ ] Implement FTP control channel line parser.
- [ ] Support `USER`, `PASS`, `TYPE I`, `PASV`, `RETR`, `STOR`, `LIST`, `QUIT`.
- [ ] Parse `227 Entering Passive Mode (...)`.
- [ ] Download through data connection.
- [ ] Upload through data connection.
- [ ] Close data and control links cleanly.

Done when:

- `ftp.exe` can login to a simple FTP server in passive mode.
- Binary download and upload work for small and medium files.

### Stage 9 - Text Chat / IRC Baseline

- [ ] Implement a simple TCP line client first.
- [ ] Add reconnect and keepalive.
- [ ] Add screen UI suitable for 80x32 text mode.
- [ ] Add optional IRC mode: `NICK`, `USER`, `JOIN`, `PRIVMSG`, `PING/PONG`.
- [ ] Keep TLS/SASL out of the first implementation.

Done when:

- `chat.exe` can connect to a known plaintext TCP chat endpoint.
- Optional `irc.exe` can join a plaintext IRC server/channel.

### Stage 10 - Browser And Download Manager

- [ ] Reuse HTTP downloader core.
- [ ] Add simple HTML/text rendering.
- [ ] Add link extraction and navigation.
- [ ] Add partial UTF-8 handling or transliteration strategy.
- [ ] Add download queue/resume only after stable HTTP range support.

Done when:

- A small text page can be fetched, displayed and navigated.

### Stage 11 - Optional Local Web Server

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
