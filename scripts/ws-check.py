#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tiny WebSocket check for the relay, standard library only (used by verify.sh).

Modes
  accept  Handshake must succeed (101). Then: send "hello", expect "hello" back; send
          "create_room" without an ALTCHA solution, expect the error code "altcha_required"
          (proves: open mode, proof-of-work on).
  reject  The handshake must be refused with HTTP 403 (a browser origin that is not allowed).

Exit code 0 = check passed, 1 = failed. Prints one line.
"""
import argparse
import base64
import hashlib
import json
import os
import socket
import ssl
import struct
import sys
import time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


class Stream:
    """A socket plus the bytes that were read past the end of the HTTP handshake (a server may send its
    first frame in the same TCP segment as the 101 answer; dropping or rejecting them made the check flaky)."""

    def __init__(self, sock, pending=b""):
        self.sock = sock
        self.pending = bytearray(pending)

    def sendall(self, data):
        self.sock.sendall(data)


def read_exact(stream, n):
    while len(stream.pending) < n:
        chunk = stream.sock.recv(max(4096, n - len(stream.pending)))
        if not chunk:
            raise ConnectionError("connection closed")
        stream.pending += chunk
    data = bytes(stream.pending[:n])
    del stream.pending[:n]
    return data


def send_text(sock, text):
    payload = text.encode()
    header = bytearray([0x81])
    if len(payload) < 126:
        header.append(0x80 | len(payload))
    elif len(payload) < 65536:
        header.append(0x80 | 126)
        header += struct.pack(">H", len(payload))
    else:
        header.append(0x80 | 127)
        header += struct.pack(">Q", len(payload))
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(bytes(header) + mask + masked)


def recv_text(sock):
    """Next text message; answers pings, fails on close."""
    while True:
        b1, b2 = read_exact(sock, 2)
        opcode = b1 & 0x0F
        length = b2 & 0x7F
        if length == 126:
            (length,) = struct.unpack(">H", read_exact(sock, 2))
        elif length == 127:
            (length,) = struct.unpack(">Q", read_exact(sock, 8))
        payload = read_exact(sock, length)
        if opcode == 0x1:
            return payload.decode()
        if opcode == 0x8:
            fail("server closed the connection: " + payload[2:].decode(errors="replace"))
        if opcode == 0x9:  # ping: answer with a masked pong
            mask = os.urandom(4)
            masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            sock.sendall(bytes([0x8A, 0x80 | len(payload)]) + mask + masked)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", required=True, help="host name (also SNI and Host header)")
    p.add_argument("--connect", help="IP address to connect to instead of resolving --host")
    p.add_argument("--port", type=int, default=443)
    p.add_argument("--cafile", help="CA bundle for the certificate (default: system store)")
    p.add_argument("--origin", help="send this Origin header (omit for a native client)")
    p.add_argument("--mode", choices=["accept", "reject"], default="accept")
    p.add_argument("--proto-version", type=int, default=2, help="protocol version of the hello message")
    p.add_argument("--timeout", type=float, default=10.0)
    a = p.parse_args()

    ctx = ssl.create_default_context(cafile=a.cafile)
    # The server allows 30 new connections per minute and address in open mode; a 429 on the handshake (several
    # verify.sh runs close together) is waited out, up to three times, instead of failing the check.
    for attempt in range(4):
        try:
            raw = socket.create_connection((a.connect or a.host, a.port), timeout=a.timeout)
            sock = ctx.wrap_socket(raw, server_hostname=a.host)
        except (OSError, ssl.SSLError) as e:
            fail("TLS connection failed: %s" % e)
        sock.settimeout(a.timeout)

        key = base64.b64encode(os.urandom(16)).decode()
        lines = [
            "GET /ws HTTP/1.1",
            "Host: " + a.host,
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: " + key,
            "Sec-WebSocket-Version: 13",
        ]
        if a.origin:
            lines.append("Origin: " + a.origin)
        sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())

        head = b""
        try:
            while b"\r\n\r\n" not in head:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                head += chunk
        except OSError as e:
            fail("no answer to the handshake: %s" % e)
        head_text, _, rest = head.partition(b"\r\n\r\n")
        status_line = head_text.split(b"\r\n", 1)[0].decode(errors="replace")
        parts = status_line.split(" ", 2)
        code = parts[1] if len(parts) > 1 else "?"
        if code != "429" or attempt == 3:
            break
        wait = 2.0
        for line in head_text.decode(errors="replace").split("\r\n")[1:]:
            name, _, value = line.partition(":")
            if name.strip().lower() == "retry-after" and value.strip().isdigit():
                wait = min(float(value.strip()), 10.0)
        sock.close()
        time.sleep(wait)

    if a.mode == "reject":
        if code == "403":
            print("ok: handshake refused with 403 for origin %s" % a.origin)
            return
        fail("expected 403 for origin %s, got: %s" % (a.origin, status_line))

    if code != "101":
        fail("handshake: expected 101, got: %s" % status_line)
    expected = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    if ("sec-websocket-accept: " + expected).lower() not in head_text.decode(errors="replace").lower():
        fail("handshake: wrong or missing Sec-WebSocket-Accept")
    stream = Stream(sock, rest)

    try:
        send_text(stream, json.dumps({"type": "hello", "proto_version": a.proto_version, "role": "receiver"}))
        msg = json.loads(recv_text(stream))
        if msg.get("type") != "hello":
            fail("expected hello, got %s" % json.dumps(msg))
        send_text(stream, json.dumps({"type": "create_room"}))
        msg = json.loads(recv_text(stream))
    except (OSError, ConnectionError, ValueError) as e:
        fail("WebSocket exchange failed: %s" % e)
    if msg.get("type") == "error" and msg.get("code") == "altcha_required":
        print("ok: 101, hello answered, create_room without proof-of-work answered altcha_required")
        return
    fail("create_room without ALTCHA should give altcha_required, got %s" % json.dumps(msg))


if __name__ == "__main__":
    main()
