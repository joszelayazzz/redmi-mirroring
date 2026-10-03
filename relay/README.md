# Optional remote relay

This component supplies an outbound-only connection path when the Mac and phone are on different networks. Both devices connect to a user-configured Internet-accessible TLS broker; no port on the phone or Mac must be publicly forwarded. The existing, independently pinned phone TLS session runs **inside** the tunnel. The broker sees encrypted phone-session bytes, traffic sizes/timing, IP addresses, and the relay room token; it never receives decrypted screen/audio/input/clipboard/file data or the inner device-pairing secret.

This is an opaque TCP relay, not a WebRTC/ICE/STUN/TURN implementation. Local Bonjour connections remain the direct LAN path. Remote P2P negotiation is a future transport option; this relay supplies the fallback directly. The room token admits a connection to a tunnel, while the existing phone certificate pin and pairing credential separately authenticate remote control. Even a malicious broker cannot impersonate the pinned phone without its private key.

## Status and dependencies

- Python 3.11+ with its standard library and TLS support; no Python packages.
- Native bridges: `NativeRemoteTunnel` on macOS and `RemoteTunnel` on Android.
- Verified on loopback with genuine TLS: admission validation, room isolation, duplicate roles, timeout, bidirectional bytes, reconnect, nested inner TLS, wrong relay trust, and wrong phone certificate pin.
- The actual Swift bridge also passed a local nested TLS echo and automatic reconnect against a labeled phone QA fixture; its two measured echo round trips were 0.69 ms and 0.72 ms. These are loopback transport figures, not phone capture latency or Internet performance.
- Cross-network operation and unattended HyperOS lifecycle are unverified until a relay endpoint is configured and the real devices are tested on separate networks.
- No broker is deployed, no external account is created, and no cloud service is purchased by this project.

## Provision a server you control

Use a computer or server that you explicitly choose, with a reachable TLS port. Keep the TLS private key restricted to the broker's user. A TLS certificate from a CA or a self-signed certificate can be used because the apps pin the exact leaf certificate. Configure both apps with the relay host, port, and SHA-256 fingerprint of the leaf certificate's DER bytes. Certificate rotation requires updating that fingerprint on both apps.

```sh
openssl x509 -in relay-cert.pem -outform DER | shasum -a 256
python3 relay.py --new-room
```

The generated room is 32 cryptographically random bytes represented by exactly 64 lowercase hex characters. Use a separate room for each Mac/phone pair, store it through the apps' Keychain/Keystore-backed settings, and transfer it privately. Do not use a PIN, hostname, email address, or memorable password as a room token. Room revocation requires changing it on both devices.

An optional room allowlist contains **SHA-256 hashes of the ASCII room tokens**, one lowercase hex hash per line. The broker stores these hashes rather than raw provisioned tokens. Produce a hash by passing the token on standard input, avoiding the process command line:

```sh
python3 relay.py --room-hash > rooms.sha256
```

Paste the token, then press Return. Add later room hashes as extra lines. Start the broker with the allowlist on a server you have approved:

```sh
python3 relay.py --host 0.0.0.0 --port 9443 \
  --cert relay-cert.pem --key relay-key.pem --rooms-file rooms.sha256
```

The default bind address is loopback, so Internet serving must be explicitly configured. TLS is mandatory; there is no plaintext mode. Reloading the allowlist requires restarting the broker. Stop/restart closes active tunnels as well as waiting peers, so this can revoke existing access. Without an allowlist, unguessable rooms still separate peers, but unknown clients can consume the broker's bounded admission capacity; use an allowlist for a shared/public deployment.

Default limits: 64 admitted TLS clients, 30 admission attempts per minute per IP, 10-second authentication deadline, 120-second rendezvous wait, 45-second idle stream timeout, 15-second blocked-write timeout, and 8-hour session TTL. Configure lower capacity if server resources require it. Stream reads/writes use bounded 64 KiB chunks and transport backpressure. The room rate ledger retains at most 4096 source IP entries. TLS handshakes are managed by the operating system/Python TLS stack; an Internet deployment should additionally apply host firewall/connection limits to protect against handshake floods.

## Protocol

The outer TLS connection verifies the user-configured relay certificate. Each client sends a 4-byte unsigned big-endian JSON length (2–4096) followed by UTF-8 JSON:

```json
{"role":"phone","room":"<64 lowercase hex characters>"}
```

The Mac uses role `mac`. No application bytes may be sent before admission. When opposite roles in the same room match, the broker sends each client one identically framed `{"ok":true}`. Everything after that acknowledgement is an opaque bidirectional byte stream. Rejection uses `{"ok":false,"error":"..."}` and then closes. No room token is written to broker logs.

The Android bridge opens `127.0.0.1:39817` and forwards the inner TLS bytes between that socket and the outer relay connection. The Mac creates an ephemeral TCP listener bound strictly to `127.0.0.1`; after admission it reports the port to the app. The app connects its ordinary `SecureTransport` to that listener **using the original phone certificate pin and device pairing credential**. Never replace that inner phone pin with the relay fingerprint.

## APIs

```swift
@MainActor
NativeRemoteTunnel.start(host: String, port: UInt16,
    fingerprint: String, room: String,
    onReady: (UInt16) -> Void, onFailure: (String) -> Void)
NativeRemoteTunnel.stop()
```

Retain the tunnel object. `onReady` runs on the main thread on each successful rendezvous, including recovery; reconnect the ordinary inner transport to its loopback port. `onFailure` reports interruption or refusal. Certificate mismatch and invalid admission are fatal; ordinary network failures retry with bounded backoff. Stop it when remote mode is disabled, when the selected phone changes, or on shutdown.

```kotlin
RemoteTunnel.start(host: String, port: Int,
    fingerprint: String, room: String,
    localPort: Int = 39817, onError: (String) -> Unit)
RemoteTunnel.stop()
```

Retain it in the phone's active companion service and call `stop()` when the service stops or configuration changes. Errors arrive on the main thread. It retries ordinary network failure with bounded backoff, rejects unexpected relay certificates, and keeps at most one socket pair and one bounded buffer per direction. Remote settings storage and onboarding belong to the native app, rather than this byte-transport component.

## Verification

```sh
python3 relay.py --self-test
```

Tests generate temporary test certificates with OpenSSL and start loopback-only servers. Their synthetic phone peer is a labeled QA fixture; it is not evidence that the Redmi's capture, controls, or separate-network performance has passed testing.

Android capture consent and lock restrictions still apply in remote mode. A relay cannot restart an expired MediaProjection permission, keep a force-stopped app alive, or unlock the phone. The phone must already be running the companion and an authorized capture session. An interruption can reconnect that surviving session; new capture authorization requires the phone's system consent.
