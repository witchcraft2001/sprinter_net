#!/usr/bin/env python3
"""Simple UDP echo server for UDPTEST.EXE.

Equivalent one-liner:
python3 -u -c 'import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("0.0.0.0",7777)); print("UDP echo on 7777"); exec("while True:\n data,addr=s.recvfrom(2048)\n print(addr,data)\n s.sendto(data,addr)")'
"""

import socket


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", 7777))
    print("UDP echo on 7777", flush=True)

    while True:
        data, addr = sock.recvfrom(2048)
        print(addr, data, flush=True)
        sock.sendto(data, addr)


if __name__ == "__main__":
    main()
