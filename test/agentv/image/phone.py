#!/usr/bin/env python3
#
# A phone on the setup hotspot, for the image check (stage 4), as little of
# one as it needs:
#   phone.py dhcp <interface>      asks for an address the way a phone does,
#                                  and prints what it was given as JSON
#   phone.py dns <server> <name>   asks a name server for a name's address
# It runs as root in the phone's own network namespace, which has no DHCP
# client or resolver of its own.

import json
import random
import socket
import struct
import sys
import time


def dhcp(interface):
    with open(f"/sys/class/net/{interface}/address") as f:
        mac = bytes.fromhex(f.read().strip().replace(":", ""))
    xid = random.getrandbits(32)

    def packet(kind, extra=b""):
        # A BOOTREQUEST with the broadcast flag, since the phone has no
        # address to be answered at yet.
        head = struct.pack("!BBBBIHH", 1, 1, 6, 0, xid, 0, 0x8000) + bytes(16) + mac + bytes(10) + bytes(192)
        return head + b"\x63\x82\x53\x63" + bytes([53, 1, kind]) + extra + bytes([55, 4, 1, 3, 6, 114, 255])

    def options(data):
        found, i = {}, 240
        while i < len(data) and data[i] != 255:
            if data[i] == 0:
                i += 1
                continue
            found[data[i]] = data[i + 2 : i + 2 + data[i + 1]]
            i += 2 + data[i + 1]
        return found

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, interface.encode())
    sock.bind(("", 68))
    sock.settimeout(3)

    def wait(kind):
        until = time.time() + 6
        while time.time() < until:
            try:
                data, _ = sock.recvfrom(2048)
            except socket.timeout:
                return None
            if len(data) < 240 or struct.unpack("!I", data[4:8])[0] != xid:
                continue
            found = options(data)
            if found.get(53, b"\0")[0] == kind:
                return data, found
        return None

    offer = None
    for _ in range(5):
        sock.sendto(packet(1), ("255.255.255.255", 67))
        offer = wait(2)
        if offer:
            break
    if not offer:
        sys.exit("no DHCP offer")
    data, found = offer
    sock.sendto(packet(3, bytes([50, 4]) + data[16:20] + bytes([54, 4]) + found[54]), ("255.255.255.255", 67))
    ack = wait(5)
    if not ack:
        sys.exit("no DHCP ack")
    data, found = ack
    address = lambda code: socket.inet_ntoa(found[code][:4]) if code in found else None
    print(json.dumps({
        "address": socket.inet_ntoa(data[16:20]),
        "router": address(3),
        "dns": address(6),
        "captive": found.get(114, b"").decode(),
    }))


def dns(server, name):
    query = struct.pack("!HHHHHH", 0x4154, 0x0100, 1, 0, 0, 0)
    query += b"".join(bytes([len(part)]) + part.encode() for part in name.split(".")) + b"\0" + struct.pack("!HH", 1, 1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(5)
    sock.sendto(query, (server, 53))
    data, _ = sock.recvfrom(1024)
    answers = struct.unpack("!H", data[6:8])[0]
    i = 12
    while data[i] != 0:
        i += data[i] + 1
    i += 5
    for _ in range(answers):
        if data[i] & 0xC0 == 0xC0:
            i += 2
        else:
            while data[i] != 0:
                i += data[i] + 1
            i += 1
        kind, _, _, length = struct.unpack("!HHIH", data[i : i + 10])
        i += 10
        if kind == 1:
            print(socket.inet_ntoa(data[i : i + 4]))
            return
        i += length
    sys.exit(f"no address for {name}")


if __name__ == "__main__":
    if sys.argv[1:2] == ["dhcp"] and len(sys.argv) == 3:
        dhcp(sys.argv[2])
    elif sys.argv[1:2] == ["dns"] and len(sys.argv) == 4:
        dns(sys.argv[2], sys.argv[3])
    else:
        sys.exit("usage: phone.py dhcp <interface> | dns <server> <name>")
