# Sprinter DSS Network Kit

Network utility package for Sprinter DSS and the SprinterESP Wi-Fi card
(ESP12-F/ESP8266 with ESP-AT firmware).

## Attribution

Sprinter DSS Network Kit project author:

- Dmitry Mikhalchenkov

This project builds on Sprinter-Wi-Fi / ESPKit DSS code authored by Roman
Boykov. The imported UART, ISA and ESP-AT support modules retain their original
BSD 3-Clause license headers.

Original SprinterESP / Sprinter-Wi-Fi repository:

https://github.com/romychs/SprinterESP

Additional project mirror/reference:

https://zxgit.org/romych/SprinterESP

Current status: project foundation, shared config, Wi-Fi bring-up and initial
TCP client core are in place. Implementation plan is tracked in `specs.md`.
User-facing setup notes are in `docs/USAGE.md`.

## Build

```sh
make build
make package
make image
```

Generated files are written to `build/` and `distr/`.

Current build output:

- `NETPROBE.EXE`
- `NETRESET.EXE`
- `NETCFG.EXE`
- `NETUP.EXE`
- `TCPTEST.EXE`
- `WTERM.EXE`

## Configuration

Use `config/NET.CFG.sample` as the template for runtime network configuration.
Do not commit real Wi-Fi credentials.

Recommended DSS install directory is `C:\NET`. Add that directory to `PATH`, or
change to it before running the tools. The runtime `NET.CFG` should live with
the installed network kit files.

On Sprinter DSS:

```text
NETCFG.EXE       show current NET.CFG values
NETCFG.EXE /W    edit and save NET.CFG interactively
NETUP.EXE        initialize ESP and connect using NET.CFG
TCPTEST.EXE      connect to example.com:80 and print a short HTTP response
```

`NETCFG.EXE /W` stores the Wi-Fi password as clear text.
`NETUP.EXE` uses ESP-AT `_CUR` commands first, so normal setup does not write
settings to ESP flash; legacy commands are used only as fallback.

## License

BSD 3-Clause. See `LICENSE`.
