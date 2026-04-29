# Repository Guidelines

## Project Scope

This repository is for developing a package of network communication programs for Sprinter DSS. Internet access is provided through the Sprinter Wi-Fi network card, SprinterESP: <https://zxgit.org/romych/SprinterESP/src/branch/master>. Keep code and documentation focused on DSS networking workflows, ESP-AT command handling, and compatibility with real Sprinter Wi-Fi hardware.

## Project Structure & Module Organization

This repository uses `src/include/` for shared include files, `src/lib/` for
reusable DSS assembly modules, and `src/apps/` for utility entry points. Build
outputs go to `build/`; distributable zip and floppy images go to `distr/`.
Package membership is controlled by `tools/artifacts.sh`.

This workspace currently sits beside two Sprinter Wi-Fi projects. `../ESPKit/` contains software for the ISA-8 ESP8266 card: `sources/DSS/` holds sjasmplus assembly programs and shared libraries (`esplib.asm`, `isa.asm`, `util.asm`), while `sources/DOS/` holds FreeDOS/Borland C++ utilities. `../SprinterESP/` contains the hardware design: editable EasyEDA JSON files in `Sources/`, reference docs in `Docs/`, exported PDFs/images/BOM files in `Export/`, and manufacturing packages in `Gerber/`. Keep generated outputs separate from editable sources.

## Build, Test, and Development Commands

Use the project scripts for normal DSS package work:

```sh
make build      # assemble known DSS apps into build/*.EXE
make package    # create distr/sprinter-net.zip
make image      # create distr/sprinter-net.img FAT12 test floppy image
make clean      # remove generated outputs
```

The scripts are intentionally tolerant while the project is being bootstrapped:
apps listed in `tools/artifacts.sh` are skipped with a warning until their
`src/apps/*.asm` entry point exists. Direct sjasmplus builds remain useful when
debugging a single source file:

```sh
sjasmplus ../ESPKit/sources/DSS/wterm.asm
sjasmplus ../ESPKit/sources/DSS/wtftp.asm
```

Use Borland C++ 3.0-compatible tooling for `../ESPKit/sources/DOS/*.c`. Open hardware sources in EasyEDA via **Document > Open > EasyEDA Source**, then regenerate `Export/` and `Gerber/` artifacts for release changes.

## Distribution Artifacts

`tools/artifacts.sh` is the single manifest used by `tools/build.sh`,
`tools/package.sh`, and `tools/image.sh`. When adding anything that must ship
with the network package, update this manifest in the same change.

Rules for future additions:

- New DSS utility: add its lowercase entry point name to `BUILD_APPS`; the source
  must be `src/apps/<name>.asm`, and scripts will build/copy
  `build/<UPPERCASE_NAME>.EXE`.
- New user documentation: add the relative path to `DIST_DOC_FILES`. Markdown is
  copied unchanged to the zip and renamed to an 8.3 `.TXT` name in the floppy
  image.
- New sample configuration: add the relative path to `DIST_CONFIG_FILES`. Never
  add a real credential-bearing `NET.CFG`; ship only templates such as
  `config/NET.CFG.sample`.
- New small required runtime asset: add it to `DIST_EXTRA_FILES`.
- If an artifact needs a subdirectory or a special 8.3 name inside the floppy
  image, update `tools/image.sh` together with `tools/artifacts.sh`.
- After changing artifact lists, run at least `make package` and, when mtools is
  available, `make image`.

## Coding Style & Naming Conventions

Preserve existing style. Assembly uses tabs for instruction alignment, uppercase labels/constants, `EQU` constants, and semicolon comments. Keep reusable routines in library files and utility entry points in app-specific `.asm` files. DOS C code should remain compatible with older Borland compilers: avoid modern extensions, use uppercase macros, and follow the existing `snake_case` function and variable naming.

## Testing Guidelines

No automated test suite is present. For DSS assembly, assemble every touched entry program and smoke-test on Sprinter DSS, emulator, or hardware. For DOS utilities, compile the changed program and verify behavior against an ESP8266 running ESP-AT firmware. For hardware edits, run EasyEDA ERC/DRC, inspect ISA/UART signal names, and verify regenerated PDFs, BOMs, and Gerbers before publishing.

## Exit Status Guidelines

DSS utilities that can reasonably be used from batch scripts must return a
meaningful status through `DSS_EXIT`. Use `B=0` for success. Prefer these common
non-zero codes unless a program documents a stronger reason to differ:

- `1` - invalid command line or usage error.
- `2` - Sprinter-WiFi hardware was not found.
- `3` - ESP communication error, timeout, unsupported command, unreachable
  host, or unexpected ESP response.
- `4` - configuration error, for example missing or invalid `NET.CFG`.

Document utility-specific exit status behavior in `docs/USAGE.md` whenever a
new automation-friendly program is added or changed.

## Debugging Environment

Primary debugging uses the MAME Sprinter emulator with the local `jesperl` software ESP emulator at `/Users/dmitry/dev/zx/sprinter/mame_esp/jesperl` (<https://sourceforge.net/projects/jesperl/files/>). Real-hardware debugging may use an ESP12-F/ESP8266 module connected to a COM port and flashed with ESP-AT firmware. `jesperl` does not fully emulate the needed behavior, so tasks may require improving or extending its functionality before application bugs can be isolated reliably.

When an ESP-AT command fails in MAME/`jesperl`, do not immediately assume the
command is wrong for real ESP-AT firmware. First check whether `jesperl`
implements that exact command syntax in
`/Users/dmitry/dev/zx/sprinter/mame_esp/jesperl/jesperl_xtr.pl` and compare it
with the target ESP-AT firmware behavior. If the command is missing from
`jesperl` but valid for real ESP-AT, record it as an emulator gap and prefer
either adding a fallback path or extending `jesperl` before reverting the real
firmware-oriented implementation.

Current `jesperl` improvement mini-spec for this project:

- Support basic no-op success commands used during initialization:
  `ATE0`, `AT`, `AT+CWMODE=1`, `AT+CWMODE_CUR=1`, `AT+SLEEP=0`,
  `AT+UART_CUR=115200,8,1,0,3`, `AT+CWLAPOPT=1,23`.
- Support Wi-Fi status and connection commands:
  `AT+CWJAP?`, `AT+CWJAP="ssid","password"`,
  `AT+CWJAP_CUR="ssid","password"`, returning realistic `OK` and `+CWJAP`
  responses.
- Support IP/DHCP/DNS variants used by ESPKit and newer ESP-AT:
  `AT+CWDHCP=1,1`, `AT+CWDHCP_CUR=1,1`, `AT+CIPSTA?`,
  `AT+CIPSTA_CUR?`, `AT+CIPSTA="ip","gw","mask"`,
  `AT+CIPSTA_CUR="ip","gw","mask"`, `AT+CIFSR`, `AT+CIPDNS?`,
  `AT+CIPDNS_CUR?`, `AT+CIPDNS=1,"dns1","dns2"`,
  `AT+CIPDNS_CUR=1,"dns1","dns2"`.
- Support TCP smoke-test commands used by `tcptest.exe` and later protocol
  clients: `AT+CIPMUX=0`, `AT+CIPSTART="TCP","host",port`,
  `AT+CIPSEND=<len>` with `>` prompt and `SEND OK`, `AT+CIPCLOSE`,
  `CLOSED`, and `+IPD,<len>:<binary payload>`.
- Pace `+IPD` output toward MAME/Z80 instead of writing large TCP bursts
  instantaneously. Provide configurable knobs such as `JESPERL_IPD_CHUNK`
  (suggested default 256 or 512 bytes for debugging, 1500 for stress tests) and
  `JESPERL_Z_PACE_US` (delay between small output slices).
- Treat pacing as an emulator fidelity feature, not as a protocol change: real
  ESP modules deliver bytes through UART timing and hardware flow control, while
  current MAME/`jesperl` may not emulate RTS/CTS deeply enough to absorb large
  immediate bursts.
- `AT+CIPSTART` must not block the whole emulator process on OS-level TCP
  connect. Use non-blocking connect or a short explicit timeout, keep accepting
  Z-side input while a connection is pending, and let ESP reset/close commands
  abort the pending connect. Otherwise MAME appears to have a wedged ESP after
  a client tries an unreachable host.
- Support diagnostic commands used by `ping.exe`, especially `AT+PING="host"`
  with realistic `+PING:<time_ms>` and `OK` responses, plus `ERROR` for
  invalid or unreachable hosts.
- Support ESP SNTP commands used by `ntp.exe`: `AT+CIPSNTPCFG=1,<tz>,"server"`
  should store runtime SNTP settings and `AT+CIPSNTPTIME?` should return a
  realistic `+CIPSNTPTIME:<weekday> <month> <day> <hh:mm:ss> <year>` response
  followed by `OK`.
- Preserve enough emulator state to make the sequence realistic: selected SSID,
  connected/disconnected state, DHCP enabled flag, station IP/gateway/netmask,
  DNS servers.
- Keep responses close to ESP-AT style: CRLF line endings, final `OK`/`ERROR`,
  and optional informational lines such as `+CWJAP:...`, `+CIFSR:STAIP,...`,
  `+CIPSTA:ip:...`.
- Add quick host-side checks, for example `printf 'AT+CWJAP?\\r\\n' | nc ...`,
  for each newly supported command family.

## Commit & Pull Request Guidelines

Existing commits are short and descriptive, such as `optimization`, `Update README.md`, and `Refactoring code for best reuse in other utilities`. Prefer clearer imperative subjects, for example `Fix RTS/CTS handling in ESP library`. Pull requests should describe software or hardware scope, list manual tests and build commands, link related issues or docs, and include updated screenshots, PDFs, BOMs, or Gerbers when board outputs change.

## Security & Configuration Tips

Do not commit Wi-Fi credentials, local serial-port settings, temporary build files, or machine-specific IDE state. Document ESP-AT firmware version requirements when behavior depends on them.

## External reference sources
- You may consult the following local sibling repositories/directories for answers, platform details, and implementation ideas:
  - `/Users/dmitry/dev/zx/sprinter/sprinter_bios`
  - `/Users/dmitry/dev/zx/sprinter/Estex-DSS`
  - `/Users/dmitry/dev/zx/sprinter/sprinter_ai_doc/manual`
  - `/Users/dmitry/dev/zx/sprinter/sources/tasm_071/TASM`
  - `/Users/dmitry/dev/zx/sprinter/sources/fformat/src/fformat_v113`
  - `/Users/dmitry/dev/zx/sprinter/sources/fm/FM-SRC/FM`
  - `/Users/dmitry/dev/zx/sprinter/sdcc-sprinter-sdk`
  - `/Users/dmitry/dev/zx/sprinter/utils`
  - `/Users/dmitry/dev/zx/sprinter/sprinter_wifi/ESPKit`
  - `/Users/dmitry/dev/zx/sprinter/sprinter_wifi/SprinterESP`
- Treat them as reference material only; this repository remains the source of truth for changes you make here.
