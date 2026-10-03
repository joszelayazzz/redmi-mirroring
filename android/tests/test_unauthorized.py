#!/usr/bin/env python3
"""Non-destructive physical-phone rejection test; never requests pairing or control."""
import argparse
import json
import secrets
import socket
import ssl
import struct
import uuid


def read_exact(stream, count):
    data = b""
    while len(data) < count:
        part = stream.recv(count - len(data))
        if not part:
            raise AssertionError("Unexpected end of frame")
        data += part
    return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("host", help="Owner-approved phone's private address")
    parser.add_argument("--port", type=int, default=39817)
    args = parser.parse_args()
    passed = 0
    for version in (ssl.TLSVersion.TLSv1_2, ssl.TLSVersion.TLSv1_3):
        # Deliberately inspect an untrusted endpoint for rejection testing only.
        # Production clients must pin the OOB invitation certificate before auth.
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        context.minimum_version = version
        context.maximum_version = version
        for case in ("unpaired", "empty-frame", "oversized-auth"):
            with socket.create_connection((args.host, args.port), timeout=5) as raw:
                with context.wrap_socket(raw, server_hostname="redmi-negative-test") as stream:
                    if case == "unpaired":
                        payload = json.dumps({"type": "auth", "version": 1, "clientId": str(uuid.uuid4()),
                                              "name": "Unpaired security test", "secret": secrets.token_hex(32),
                                              "pair": False}).encode()
                        stream.sendall(struct.pack(">I", len(payload) + 1) + bytes([1]) + payload)
                        size = struct.unpack(">I", read_exact(stream, 4))[0]
                        assert 1 < size < 4096
                        frame = read_exact(stream, size)
                        assert frame[0] == 1
                        response = json.loads(frame[1:])
                        assert response["type"] == "error"
                        assert "width" not in response and "projection" not in response
                    elif case == "empty-frame":
                        stream.sendall(struct.pack(">I", 0))
                    else:
                        # The server must reject the header before allocating/reading the payload.
                        stream.sendall(struct.pack(">I", 4098))
                    try:
                        assert stream.recv(1) == b"", "Unauthenticated endpoint leaked data"
                    except (ConnectionResetError, ssl.SSLEOFError):
                        pass
                    passed += 1
                    print(f"PASS {version.name}: {case} closed without capabilities/media")
    print(f"PASS: {passed} physical-phone security checks")


if __name__ == "__main__":
    main()
