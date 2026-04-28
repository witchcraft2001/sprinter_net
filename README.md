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

Current status: project foundation is in place. `NETPROBE.EXE` is the first
diagnostic utility and checks basic SprinterESP UART/ESP-AT communication.
Implementation plan is tracked in `specs.md`.

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
- `WTERM.EXE`

## Configuration

Use `config/NET.CFG.sample` as the template for runtime network configuration.
Do not commit real Wi-Fi credentials.

On Sprinter DSS:

```text
NETCFG.EXE       show current NET.CFG values
NETCFG.EXE /W    edit and save NET.CFG interactively
```

`NETCFG.EXE /W` stores the Wi-Fi password as clear text.

## License

BSD 3-Clause. See `LICENSE`.
