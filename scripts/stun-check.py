#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks the STUN service of the relay with raw UDP packets, standard library only (used by verify.sh).

Checks (each prints one line; exit code 0 only if all of them passed):
  binding   A STUN Binding request gets a Binding success response (RFC 5389/8489) with the same
            transaction id and an XOR-MAPPED-ADDRESS. The size of the answer is compared with the
            request: it must stay below --max-factor times the request (reflection/amplification).
  allocate  A TURN Allocate request (REQUESTED-TRANSPORT udp) must NOT be answered with a success.
            Silence or an error answer is fine: the service must not relay.
  garbage   Random bytes that are not a STUN message get no answer at all.

Usage: stun-check.py --host NAME_OR_IP [--port 3478] [--timeout 3] [--max-factor 3]
"""
import argparse
import os
import socket
import struct
import sys

MAGIC = 0x2112A442
BINDING_REQUEST = 0x0001
BINDING_SUCCESS = 0x0101
ALLOCATE_REQUEST = 0x0003
ALLOCATE_SUCCESS = 0x0103
XOR_MAPPED_ADDRESS = 0x0020
REQUESTED_TRANSPORT = 0x0019


def header(msg_type, body=b"", tid=None):
    tid = tid or os.urandom(12)
    return struct.pack(">HHI", msg_type, len(body), MAGIC) + tid + body, tid


def exchange(addr, data, timeout):
    """Send one datagram, return the first answer or None after the timeout."""
    family, _, _, _, sockaddr = addr
    s = socket.socket(family, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(data, sockaddr)
        try:
            return s.recvfrom(4096)[0]
        except socket.timeout:
            return None
        except ConnectionRefusedError:
            return None
    finally:
        s.close()


def xor_mapped(attrs, tid):
    """Decode the XOR-MAPPED-ADDRESS attribute, or None when it is not there."""
    pos = 0
    while pos + 4 <= len(attrs):
        atype, alen = struct.unpack(">HH", attrs[pos:pos + 4])
        value = attrs[pos + 4:pos + 4 + alen]
        if atype == XOR_MAPPED_ADDRESS and len(value) >= 8:
            fam = value[1]
            port = struct.unpack(">H", value[2:4])[0] ^ (MAGIC >> 16)
            if fam == 1 and len(value) == 8:
                raw = bytes(a ^ b for a, b in zip(value[4:8], struct.pack(">I", MAGIC)))
                return "%s:%d" % (socket.inet_ntop(socket.AF_INET, raw), port)
            if fam == 2 and len(value) == 20:
                key = struct.pack(">I", MAGIC) + tid
                raw = bytes(a ^ b for a, b in zip(value[4:20], key))
                return "[%s]:%d" % (socket.inet_ntop(socket.AF_INET6, raw), port)
        pos += 4 + alen + (-alen % 4)
    return None


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", required=True, help="name or address of the STUN server")
    p.add_argument("--port", type=int, default=3478)
    p.add_argument("--timeout", type=float, default=3.0, help="seconds to wait for an answer")
    p.add_argument("--max-factor", type=float, default=3.0, help="largest allowed answer size / request size")
    a = p.parse_args()

    try:
        infos = socket.getaddrinfo(a.host, a.port, type=socket.SOCK_DGRAM)
    except socket.gaierror as e:
        print("FAIL: cannot resolve %s: %s" % (a.host, e))
        return 1
    addr = infos[0]
    failed = 0

    # binding
    req, tid = header(BINDING_REQUEST)
    resp = exchange(addr, req, a.timeout)
    if resp is None:
        print("FAIL binding: no answer from %s:%d/udp within %.0f s (firewall, wrong port, service down?)" % (a.host, a.port, a.timeout))
        return 1  # the other checks mean nothing without a working service
    if len(resp) < 20:
        print("FAIL binding: answer too short (%d bytes)" % len(resp))
        failed += 1
    else:
        rtype, rlen, rmagic = struct.unpack(">HHI", resp[:8])
        rtid = resp[8:20]
        mapped = xor_mapped(resp[20:20 + rlen], rtid)
        factor = len(resp) / len(req)
        if rtype != BINDING_SUCCESS or rmagic != MAGIC or rtid != tid:
            print("FAIL binding: not a matching Binding success (type 0x%04x)" % rtype)
            failed += 1
        elif mapped is None:
            print("FAIL binding: no XOR-MAPPED-ADDRESS in the answer")
            failed += 1
        elif factor > a.max_factor:
            print("FAIL binding: answer is %d bytes for a %d byte request (factor %.1f > %.1f): extra attributes switched on?" % (len(resp), len(req), factor, a.max_factor))
            failed += 1
        else:
            print("ok binding: success, you are %s, answer %d bytes for a %d byte request (factor %.1f)" % (mapped, len(resp), len(req), factor))

    # allocate must not succeed
    body = struct.pack(">HHBxxx", REQUESTED_TRANSPORT, 4, 17)
    req, _ = header(ALLOCATE_REQUEST, body)
    resp = exchange(addr, req, a.timeout)
    if resp is None:
        print("ok allocate: a TURN Allocate request is ignored (no answer)")
    elif len(resp) >= 2 and struct.unpack(">H", resp[:2])[0] == ALLOCATE_SUCCESS:
        print("FAIL allocate: the server ALLOCATED a relay (success answer): this is not a STUN-only service")
        failed += 1
    else:
        rtype = struct.unpack(">H", resp[:2])[0] if len(resp) >= 2 else -1
        print("ok allocate: a TURN Allocate request is refused (answer type 0x%04x, not a success)" % rtype)

    # garbage gets no answer
    resp = exchange(addr, os.urandom(64), min(a.timeout, 1.5))
    if resp is None:
        print("ok garbage: random bytes get no answer")
    else:
        print("FAIL garbage: random bytes were answered (%d bytes)" % len(resp))
        failed += 1

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
