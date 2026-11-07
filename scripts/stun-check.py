#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks the STUN service of the relay with raw UDP packets, standard library only (used by verify.sh).

Checks (each prints one line; exit code 0 only if all of them passed):
  binding   A STUN Binding request gets a Binding success response (RFC 5389/8489) with the same
            transaction id and an XOR-MAPPED-ADDRESS. The size of the answer is compared with the
            request: it must stay below --max-factor times the request (reflection/amplification).
  allocate  A TURN Allocate request (REQUESTED-TRANSPORT udp) must get NO answer at all. coturn 4.18.0 in
            stun-only mode drops every TURN request silently (checked with the real container). Any
            answer fails the check, because a STUN-only service has no business speaking TURN: a success
            means it relays, and an error such as 401 Unauthorized (credentials needed), 437 Allocation
            Mismatch or 441 Wrong Credentials is what a normal TURN server answers (it was seen to answer
            401 here), i.e. the service is a TURN server that merely refuses this request.
  garbage   Random bytes that are not a STUN message get no answer at all.
  malformed Binding requests with unknown attributes, a bad length, no magic cookie, other message types and
            the like: if one is answered, the answer must stay below --max-factor times the request too
            (the amplification claim holds for malformed requests, not only for the plain one).

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
ERROR_CODE = 0x0009
TURN_ERRORS = {401: "Unauthorized", 437: "Allocation Mismatch", 441: "Wrong Credentials"}


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


def error_code(resp):
    """The ERROR-CODE of an error response (class*100+number), or None."""
    if len(resp) < 20:
        return None
    pos = 20
    while pos + 4 <= len(resp):
        atype, alen = struct.unpack(">HH", resp[pos:pos + 4])
        value = resp[pos + 4:pos + 4 + alen]
        if atype == ERROR_CODE and len(value) >= 4:
            return (value[2] & 7) * 100 + value[3]
        pos += 4 + alen + (-alen % 4)
    return None


def attr(atype, value):
    return struct.pack(">HH", atype, len(value)) + value + b"\0" * (-len(value) % 4)


def malformed_requests():
    """(label, datagram) pairs: things a STUN server should drop, or answer with something small."""
    good, _ = header(BINDING_REQUEST)
    return [
        ("no magic cookie", struct.pack(">HHI", BINDING_REQUEST, 0, 0x12345678) + os.urandom(12)),
        ("unknown required attribute", header(BINDING_REQUEST, attr(0x0001, b"abcd"))[0]),
        ("unknown optional attribute", header(BINDING_REQUEST, attr(0x8099, b"abcd"))[0]),
        ("length field larger than the packet", good[:2] + struct.pack(">H", 400) + good[4:]),
        ("CHANGE-REQUEST", header(BINDING_REQUEST, attr(0x0003, b"\0\0\0\x06"))[0]),
        ("bad FINGERPRINT", header(BINDING_REQUEST, attr(0x8028, b"\0\0\0\0"))[0]),
        ("bad MESSAGE-INTEGRITY", header(BINDING_REQUEST, attr(0x0008, b"\0" * 20))[0]),
        ("USERNAME", header(BINDING_REQUEST, attr(0x0006, b"alice"))[0]),
        ("Binding indication", header(0x0011)[0]),
        ("Binding success as request", header(BINDING_SUCCESS)[0]),
        ("Binding error as request", header(0x0111)[0]),
        ("Shared Secret request", header(0x0002)[0]),
        ("Refresh", header(0x0004)[0]),
        ("CreatePermission", header(0x0008)[0]),
        ("ChannelData", struct.pack(">HH", 0x4000, 4) + b"abcd"),
        ("19 bytes", good[:19]),
        ("empty datagram", b""),
    ]


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

    # allocate: no answer at all (what coturn 4.18.0 stun-only really does)
    body = struct.pack(">HHBxxx", REQUESTED_TRANSPORT, 4, 17)
    req, _ = header(ALLOCATE_REQUEST, body)
    resp = exchange(addr, req, a.timeout)
    if resp is None:
        print("ok allocate: a TURN Allocate request is ignored (no answer)")
    else:
        rtype = struct.unpack(">H", resp[:2])[0] if len(resp) >= 2 else -1
        code = error_code(resp)
        if rtype == ALLOCATE_SUCCESS:
            print("FAIL allocate: the server ALLOCATED a relay (success answer): this is not a STUN-only service")
        elif code in TURN_ERRORS:
            print("FAIL allocate: answered with TURN error %d %s: a STUN-only service does not speak TURN at all (a normal TURN server answers like this)" % (code, TURN_ERRORS[code]))
        else:
            print("FAIL allocate: answered (type 0x%04x%s); a STUN-only service must stay silent for TURN requests" % (rtype, ", error %d" % code if code else ""))
        failed += 1

    # malformed requests: answered or not, never an amplifier
    worst = 0.0
    bad = 0
    answered = []
    for label, data in malformed_requests():
        resp = exchange(addr, data, min(a.timeout, 1.0))
        if resp is not None:
            factor = len(resp) / max(len(data), 1)
            worst = max(worst, factor)
            answered.append("%s (%d -> %d bytes)" % (label, len(data), len(resp)))
            if factor > a.max_factor:
                print("FAIL malformed: %s: answer %d bytes for a %d byte request (factor %.1f > %.1f)" % (label, len(resp), len(data), factor, a.max_factor))
                bad += 1
    failed += bad
    if not bad:
        print("ok malformed: %d malformed requests, %d answered%s; largest answer/request factor %.2f (limit %.1f)" % (len(malformed_requests()), len(answered), (" [" + "; ".join(answered) + "]") if answered else "", worst, a.max_factor))

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
