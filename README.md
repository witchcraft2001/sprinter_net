# Sprinter DSS Network Kit

Network utility package for Sprinter DSS and the SprinterESP Wi-Fi card
(ESP12-F/ESP8266 with ESP-AT firmware).

Current status: project foundation and distribution scripts are being prepared.
Implementation plan is tracked in `specs.md`.

## Build

```sh
make build
make package
make image
```

Generated files are written to `build/` and `distr/`.

## Configuration

Use `config/NET.CFG.sample` as the template for runtime network configuration.
Do not commit real Wi-Fi credentials.
