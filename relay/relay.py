#!/usr/bin/env python3
"""Bounded, opaque TLS relay for Redmi Mirroring. Python 3.11+, no packages.

The bytes after the framed admission acknowledgement are an independent inner
TLS session. This broker never terminates that session or handles media/input.
"""
import argparse
import asyncio
import hashlib
import json
import os
import re
import secrets
import ssl
import struct
import sys
import time
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path

FRAME_MAX = 4096
CHUNK = 65536
ROOM_RE = re.compile(r"^[0-9a-f]{64}$")


async def read_message(reader):
    length = struct.unpack("!I", await reader.readexactly(4))[0]
    if length < 2 or length > FRAME_MAX:
        raise ValueError("Invalid admission frame")
    message = json.loads((await reader.readexactly(length)).decode("utf-8"))
    if not isinstance(message, dict):
        raise ValueError("Invalid admission object")
    return message


async def write_message(writer, message):
    payload = json.dumps(message, separators=(",", ":")).encode()
    writer.write(struct.pack("!I", len(payload)) + payload)
    await asyncio.wait_for(writer.drain(), 10)


@dataclass(eq=False)
class Peer:
    reader: asyncio.StreamReader
    writer: asyncio.StreamWriter
    role: str
    room_hash: str
    mate: asyncio.Future


class Relay:
    def __init__(self, allowed_rooms=None, capacity=64, wait=120, idle=45,
                 session_ttl=28800, attempts_per_minute=30):
        self.allowed_rooms = allowed_rooms
        self.capacity = max(2, min(capacity, 1024))
        self.wait = max(1, min(wait, 120))
        self.idle = max(5, min(idle, 300))
        self.session_ttl = max(5, min(session_ttl, 86400))
        self.attempts_per_minute = max(1, attempts_per_minute)
        self.waiting = {}
        self.clients = set()
        self.rates = OrderedDict()

    def admit_address(self, address):
        now = time.monotonic()
        times = [stamp for stamp in self.rates.pop(address, []) if now - stamp < 60]
        times.append(now)
        self.rates[address] = times[-self.attempts_per_minute - 1:]
        while len(self.rates) > 4096:
            self.rates.popitem(last=False)
        return len(times) <= self.attempts_per_minute

    async def reject(self, writer, reason):
        try:
            await write_message(writer, {"ok": False, "error": reason})
        except (Exception, asyncio.CancelledError):
            pass

    async def handle(self, reader, writer):
        address = writer.get_extra_info("peername")
        address = str(address[0]) if address else "unknown"
        peer = mate = None
        watcher = None
        admitted = False
        writer.transport.set_write_buffer_limits(high=CHUNK, low=CHUNK // 4)
        try:
            if not self.admit_address(address):
                await self.reject(writer, "Admission rate exceeded")
                return
            if len(self.clients) >= self.capacity:
                await self.reject(writer, "Relay is at capacity")
                return
            self.clients.add(writer)
            admitted = True
            try:
                request = await asyncio.wait_for(read_message(reader), 10)
                role, room = request.get("role"), request.get("room")
                if set(request) != {"role", "room"} or role not in ("phone", "mac"):
                    raise ValueError("Invalid admission request")
                if not isinstance(room, str) or not ROOM_RE.fullmatch(room):
                    raise ValueError("Room must be a random 256-bit hex token")
            except (ValueError, UnicodeError, json.JSONDecodeError, asyncio.IncompleteReadError):
                await self.reject(writer, "Invalid admission request")
                return
            room_hash = hashlib.sha256(room.encode("ascii")).hexdigest()
            # Never retain or log the room token itself after admission.
            request.clear()
            room = None
            if self.allowed_rooms is not None and room_hash not in self.allowed_rooms:
                await self.reject(writer, "Room is not authorized")
                return
            peer = Peer(reader, writer, role, room_hash, asyncio.get_running_loop().create_future())
            existing = self.waiting.get(room_hash)
            if existing is not None and existing.role == role:
                await self.reject(writer, "This room already has that device role")
                return
            if existing is not None and not existing.writer.is_closing():
                self.waiting.pop(room_hash, None)
                peer.mate.set_result(existing)
                existing.mate.set_result(peer)
            else:
                self.waiting[room_hash] = peer
            # Abort disconnected or early-data clients instead of buffering
            # arbitrary application bytes during the rendezvous period.
            watcher = asyncio.create_task(reader.read(1))
            done, _ = await asyncio.wait((peer.mate, watcher), timeout=self.wait,
                                         return_when=asyncio.FIRST_COMPLETED)
            if watcher in done:
                await self.reject(writer, "Device disconnected or sent data before admission")
                return
            if peer.mate not in done:
                await self.reject(writer, "Waiting for the other device timed out")
                return
            watcher.cancel()
            await asyncio.gather(watcher, return_exceptions=True)
            watcher = None
            mate = peer.mate.result()
            await write_message(writer, {"ok": True})
            await asyncio.wait_for(self.copy(reader, mate.writer), self.session_ttl)
        except (OSError, ssl.SSLError, asyncio.TimeoutError, asyncio.IncompleteReadError):
            pass
        finally:
            if watcher is not None:
                watcher.cancel()
                await asyncio.gather(watcher, return_exceptions=True)
            if peer is not None and self.waiting.get(peer.room_hash) is peer:
                self.waiting.pop(peer.room_hash, None)
            if peer is not None and peer.mate.done() and not peer.mate.cancelled():
                mate = peer.mate.result()
            writer.close()
            if mate is not None:
                mate.writer.close()
            if admitted:
                self.clients.discard(writer)
            try:
                await asyncio.wait_for(writer.wait_closed(), 3)
            except (Exception, asyncio.CancelledError):
                pass

    async def copy(self, reader, writer):
        while True:
            data = await asyncio.wait_for(reader.read(CHUNK), self.idle)
            if not data:
                return
            writer.write(data)
            await asyncio.wait_for(writer.drain(), 15)


def server_context(cert, key):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    return context


async def serve(args):
    allowed = None
    if args.rooms_file:
        allowed = {line.strip() for line in Path(args.rooms_file).read_text().splitlines()
                   if line.strip() and not line.lstrip().startswith("#")}
        if any(not ROOM_RE.fullmatch(item) for item in allowed):
            raise ValueError("Rooms file must contain SHA-256 hashes, one per line")
    relay = Relay(allowed, args.capacity, args.wait, args.idle, args.session_ttl)
    server = await asyncio.start_server(relay.handle, args.host, args.port,
                                       ssl=server_context(args.cert, args.key),
                                       ssl_handshake_timeout=10, limit=CHUNK)
    addresses = ", ".join(str(sock.getsockname()) for sock in server.sockets)
    print(f"Redmi Mirroring opaque TLS relay listening on {addresses}", flush=True)
    print("Provisioned room allowlist enabled" if allowed is not None else
          "Random room admission enabled; use --rooms-file on shared/public brokers", flush=True)
    async with server:
        await server.serve_forever()


def self_test():
    """Actual loopback TLS tests, including TLS nested inside the relay.

    A synthetic TLS test peer is explicitly a QA fixture, not an Android device.
    """
    import subprocess
    import tempfile
    import unittest

    with tempfile.TemporaryDirectory(prefix="redmi-relay-tests-") as directory:
        def certificate(label):
            cert, key = Path(directory) / f"{label}.pem", Path(directory) / f"{label}.key"
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                            "-keyout", str(key), "-out", str(cert), "-days", "1",
                            "-subj", "/CN=localhost"], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return str(cert), str(key)
        outer_cert, outer_key = certificate("relay")
        inner_cert, inner_key = certificate("phone-fixture")
        room = secrets.token_hex(32)
        expected_pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert(Path(inner_cert).read_text())).hexdigest()

        class NestedTLS:
            def __init__(self, reader, writer, context, server=False, pin=None):
                self.reader, self.writer = reader, writer
                self.incoming, self.outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
                self.tls = context.wrap_bio(self.incoming, self.outgoing, server_side=server,
                                           server_hostname=None if server else "localhost")
                self.pin = pin

            async def flush(self):
                while self.outgoing.pending:
                    self.writer.write(self.outgoing.read())
                await self.writer.drain()

            async def operate(self, function):
                while True:
                    try:
                        value = function()
                        await self.flush()
                        return value
                    except ssl.SSLWantWriteError:
                        await self.flush()
                    except ssl.SSLWantReadError:
                        await self.flush()
                        data = await asyncio.wait_for(self.reader.read(CHUNK), 5)
                        if not data:
                            raise EOFError("Inner TLS disconnected")
                        self.incoming.write(data)

            async def handshake(self):
                await self.operate(self.tls.do_handshake)
                if self.pin is not None:
                    actual = hashlib.sha256(self.tls.getpeercert(binary_form=True)).hexdigest()
                    if not secrets.compare_digest(actual, self.pin):
                        raise ssl.SSLError("Inner phone certificate pin mismatch")

        class Tests(unittest.IsolatedAsyncioTestCase):
            async def asyncSetUp(self):
                self.relay = Relay({hashlib.sha256(room.encode()).hexdigest()}, wait=1)
                self.server = await asyncio.start_server(self.relay.handle, "127.0.0.1", 0,
                    ssl=server_context(outer_cert, outer_key), limit=CHUNK)
                self.port = self.server.sockets[0].getsockname()[1]
                self.context = ssl.create_default_context(cafile=outer_cert)
                self.writers = []

            async def asyncTearDown(self):
                for writer in self.writers:
                    writer.close()
                await asyncio.gather(*(w.wait_closed() for w in self.writers), return_exceptions=True)
                self.server.close()
                await self.server.wait_closed()
                await asyncio.sleep(0.02)

            async def client(self, request):
                reader, writer = await asyncio.open_connection("127.0.0.1", self.port,
                    ssl=self.context, server_hostname="localhost", limit=CHUNK)
                self.writers.append(writer)
                await write_message(writer, request)
                return reader, writer

            async def pair(self):
                phone = await self.client({"role": "phone", "room": room})
                mac = await self.client({"role": "mac", "room": room})
                self.assertEqual(await read_message(phone[0]), {"ok": True})
                self.assertEqual(await read_message(mac[0]), {"ok": True})
                return phone, mac

            async def test_wrong_room_rejected(self):
                reader, _ = await self.client({"role": "mac", "room": secrets.token_hex(32)})
                self.assertFalse((await read_message(reader))["ok"])

            async def test_malformed_role_rejected(self):
                reader, _ = await self.client({"role": "administrator", "room": room})
                self.assertFalse((await read_message(reader))["ok"])

            async def test_short_room_rejected(self):
                reader, _ = await self.client({"role": "mac", "room": "123456"})
                self.assertFalse((await read_message(reader))["ok"])

            async def test_duplicate_role_rejected(self):
                await self.client({"role": "phone", "room": room})
                await asyncio.sleep(0.02)
                reader, _ = await self.client({"role": "phone", "room": room})
                self.assertFalse((await read_message(reader))["ok"])

            async def test_wait_timeout(self):
                reader, _ = await self.client({"role": "mac", "room": room})
                self.assertFalse((await asyncio.wait_for(read_message(reader), 2))["ok"])

            async def test_oversized_frame_rejected(self):
                reader, writer = await asyncio.open_connection("127.0.0.1", self.port,
                    ssl=self.context, server_hostname="localhost")
                self.writers.append(writer)
                writer.write(struct.pack("!I", FRAME_MAX + 1))
                await writer.drain()
                self.assertFalse((await read_message(reader))["ok"])

            async def test_early_application_data_rejected(self):
                reader, writer = await self.client({"role": "phone", "room": room})
                writer.write(b"premature application bytes")
                await writer.drain()
                self.assertFalse((await read_message(reader))["ok"])

            async def test_capacity_limit(self):
                self.relay.capacity = 2
                await self.pair()
                reader, _ = await self.client({"role": "phone", "room": room})
                self.assertIn("capacity", (await read_message(reader))["error"])

            async def test_admission_rate_limit(self):
                self.relay.attempts_per_minute = 1
                await self.client({"role": "phone", "room": room})
                reader, _ = await self.client({"role": "mac", "room": room})
                self.assertIn("rate", (await read_message(reader))["error"])

            async def test_bidirectional_and_reconnect(self):
                phone, mac = await self.pair()
                phone[1].write(b"phone-to-mac")
                await phone[1].drain()
                self.assertEqual(await mac[0].readexactly(12), b"phone-to-mac")
                mac[1].write(b"mac-to-phone")
                await mac[1].drain()
                self.assertEqual(await phone[0].readexactly(12), b"mac-to-phone")
                phone[1].close()
                await phone[1].wait_closed()
                self.assertEqual(await asyncio.wait_for(mac[0].read(1), 2), b"")
                await asyncio.sleep(0.02)
                await self.pair()

            async def nested_pair(self, pin):
                phone, mac = await self.pair()
                phone_tls = NestedTLS(*phone, server_context(inner_cert, inner_key), server=True)
                mac_tls = NestedTLS(*mac, ssl.create_default_context(cafile=inner_cert), pin=pin)
                await asyncio.gather(phone_tls.handshake(), mac_tls.handshake())
                return phone_tls, mac_tls

            async def test_inner_tls_phone_pin_and_media(self):
                phone, mac = await self.nested_pair(expected_pin)
                secret_media = os.urandom(256 * 1024)
                async def send():
                    for offset in range(0, len(secret_media), 16384):
                        await phone.operate(lambda offset=offset: phone.tls.write(secret_media[offset:offset + 16384]))
                async def receive():
                    payload = bytearray()
                    while len(payload) < len(secret_media):
                        payload.extend(await mac.operate(lambda: mac.tls.read(16384)))
                    return bytes(payload)
                _, result = await asyncio.gather(send(), receive())
                self.assertEqual(result, secret_media)
                await mac.operate(lambda: mac.tls.write(b"authenticated-input"))
                self.assertEqual(await phone.operate(lambda: phone.tls.read(1024)), b"authenticated-input")

            async def test_wrong_inner_pin_rejected(self):
                with self.assertRaises(ssl.SSLError):
                    await self.nested_pair("0" * 64)

            async def test_wrong_outer_certificate_rejected(self):
                wrong_context = ssl.create_default_context(cafile=inner_cert)
                with self.assertRaises(ssl.SSLCertVerificationError):
                    await asyncio.open_connection("127.0.0.1", self.port,
                        ssl=wrong_context, server_hostname="localhost")

        suite = unittest.defaultTestLoader.loadTestsFromTestCase(Tests)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        return 0 if result.wasSuccessful() else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--new-room", action="store_true")
    parser.add_argument("--room-hash", action="store_true", help="Read token from stdin and print its provisioned hash")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9443)
    parser.add_argument("--cert")
    parser.add_argument("--key")
    parser.add_argument("--rooms-file")
    parser.add_argument("--capacity", type=int, default=64)
    parser.add_argument("--wait", type=int, default=120)
    parser.add_argument("--idle", type=int, default=45)
    parser.add_argument("--session-ttl", type=int, default=28800)
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.new_room:
        print(secrets.token_hex(32))
        return 0
    if args.room_hash:
        token = sys.stdin.readline().strip()
        if not ROOM_RE.fullmatch(token):
            parser.error("Expected a 256-bit room token on standard input")
        print(hashlib.sha256(token.encode("ascii")).hexdigest())
        return 0
    if not args.cert or not args.key:
        parser.error("--cert and --key are required; unencrypted relay operation is unsupported")
    try:
        asyncio.run(serve(args))
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
