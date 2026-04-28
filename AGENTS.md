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

## Debugging Environment

Primary debugging uses the MAME Sprinter emulator with the local `jesperl` software ESP emulator at `/Users/dmitry/dev/zx/sprinter/mame_esp/jesperl` (<https://sourceforge.net/projects/jesperl/files/>). Real-hardware debugging may use an ESP12-F/ESP8266 module connected to a COM port and flashed with ESP-AT firmware. `jesperl` does not fully emulate the needed behavior, so tasks may require improving or extending its functionality before application bugs can be isolated reliably.

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
