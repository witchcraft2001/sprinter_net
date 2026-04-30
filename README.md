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

## Package Contents

- `NETPROBE.EXE`
- `NETRESET.EXE`
- `NETCFG.EXE`
- `NETUP.EXE`
- `TCPTEST.EXE`
- `PING.EXE`
- `WGET.EXE`
- `NTP.EXE`
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
TCPTEST.EXE host port path
                 test an HTTP path on a custom host and port
UDPTEST.EXE host port [message [local_port]]
                 send one UDP datagram and wait for one reply
TFTP.EXE tftp://host[:port]/path FILE
                 download one file over TFTP
PING.EXE host    test host reachability using ESP-AT AT+PING
WGET.EXE url file download an HTTP/1.0 URL to a local file
                  URL must currently include http://
NTP.EXE          set DSS time using NET.CFG TZ/NTP values
```

`NETCFG.EXE /W` stores the Wi-Fi password as clear text.
`NETUP.EXE` uses ESP-AT `_CUR` commands first, so normal setup does not write
settings to ESP flash; legacy commands are used only as fallback.
`BAUD` in `NET.CFG` may be set to `115200`, `57600`, `38400`, `19200` or
`9600`; automated tools use it after `NETUP.EXE` configures the ESP with
`AT+UART_CUR`.

## ESP-AT Firmware Baseline

The current baseline firmware checked for this project is the local ESP8266
ESP-AT package at `/Users/dmitry/Downloads/V2.2.1`. The AT binaries contain
command tokens for the project-critical command families below:

- Basic: `AT`, `ATE0`, `AT+GMR`, `AT+RST`, `AT+RESTORE`, `AT+SLEEP`,
  `AT+GSLP`, `AT+SYSMSG`.
- UART: `AT+UART`, `AT+UART_CUR`, `AT+UART_DEF`, legacy `AT+IPR`.
- Wi-Fi station/AP: `AT+CWMODE`, `AT+CWMODE_CUR`, `AT+CWMODE_DEF`,
  `AT+CWJAP`, `AT+CWJAP_CUR`, `AT+CWJAP_DEF`, `AT+CWQAP`, `AT+CWLAP`,
  `AT+CWLAPOPT`, `AT+CWAUTOCONN`, `AT+CWHOSTNAME`, `AT+CIFSR`.
- IP/DNS/DHCP: `AT+CIPSTA`, `AT+CIPSTA_CUR`, `AT+CIPSTA_DEF`,
  `AT+CIPAP`, `AT+CIPAP_CUR`, `AT+CIPAP_DEF`, `AT+CIPDNS_CUR`,
  `AT+CIPDNS_DEF`, `AT+CWDHCP`, `AT+CWDHCP_CUR`, `AT+CWDHCP_DEF`.
- TCP/UDP client/server: `AT+CIPSTART`, `AT+CIPCLOSE`, `AT+CIPSEND`,
  `AT+CIPSENDEX`, `AT+CIPSENDBUF`, `AT+CIPMUX`, `AT+CIPMODE`,
  `AT+CIPSTATUS`, `AT+CIPSERVER`, `AT+CIPSERVERMAXCONN`, `AT+CIPSTO`,
  `AT+CIPDINFO`, `AT+CIPDOMAIN`, `AT+CIPSSLSIZE`.
- Diagnostics and time: `AT+PING`, `AT+CIPSNTPCFG`, `AT+CIPSNTPTIME`.

The V2.2.1 binaries do not contain `AT+CIPRECVMODE` or `AT+CIPRECVDATA`, so
ESP-AT passive TCP receive should be treated as unsupported for this firmware.
WGET must keep a reliable active `+IPD` receive path for V2.2.1.

## License

BSD 3-Clause. See `LICENSE`.
