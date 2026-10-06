"""Capture Android TV Remote v2 protocol fixtures from the reference implementation.

Drives the real `androidtvremote2` PairingProtocol / RemoteProtocol classes against a
fake transport and records every byte they write. The Swift tests then assert that
RemoteKit produces byte-identical output, so the fixtures come from the reference
implementation rather than from our own understanding of it.

Run:  uv run tools/fixtures/gen_androidtv_fixtures.py
Writes: Packages/RemoteKit/Tests/RemoteKitTests/Fixtures/androidtv.json

Style rules for this repo's Python: no zip(), no `with` for file operations.
"""

# /// script
# requires-python = ">=3.11"
# dependencies = ["androidtvremote2==0.3.2"]
# ///

from __future__ import annotations

import asyncio
import json
import os
import sys
import tempfile

from cryptography import x509
from cryptography.hazmat.primitives import serialization

from androidtvremote2.certificate_generator import generate_selfsigned_cert
from androidtvremote2.exceptions import InvalidAuth
from androidtvremote2.pairing import PairingProtocol
from androidtvremote2 import polo_pb2, remotemessage_pb2
from androidtvremote2.remote import RemoteProtocol

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_PATH = os.path.join(
    REPO_ROOT, "Packages", "RemoteKit", "Tests", "RemoteKitTests", "Fixtures", "androidtv.json"
)
CODE_SUFFIX = "A1B2"


def write_text(path: str, text: str) -> None:
    fp = open(path, "w", encoding="utf-8", newline="\n")
    try:
        fp.write(text)
    finally:
        fp.close()


def write_bytes(path: str, data: bytes) -> None:
    fp = open(path, "wb")
    try:
        fp.write(data)
    finally:
        fp.close()


def pem_to_der(cert_pem: bytes) -> bytes:
    cert = x509.load_pem_x509_certificate(cert_pem)
    return cert.public_bytes(serialization.Encoding.DER)


def read_varint(buf: bytes, pos: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while True:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, pos
        shift += 7


def split_frames(stream: bytes) -> list[bytes]:
    """Split a varint-length-prefixed byte stream into its message payloads."""
    frames = []
    pos = 0
    while pos < len(stream):
        length, start = read_varint(stream, pos)
        frames.append(stream[start : start + length])
        pos = start + length
    return frames


class FakeSSLObject:
    def __init__(self, peer_der: bytes) -> None:
        self.peer_der = peer_der

    def getpeercert(self, binary_form: bool = False) -> bytes:
        return self.peer_der


class FakeTransport:
    """Records writes. Optionally runs a hook after each write (used to ack pairing)."""

    def __init__(self, peer_der: bytes = b"") -> None:
        self.peer_der = peer_der
        self.written = bytearray()
        self.after_write = None

    def get_extra_info(self, name: str, default=None):
        if name == "ssl_object":
            return FakeSSLObject(self.peer_der)
        if name == "peername":
            return ("127.0.0.1", 6467)
        return default

    def is_closing(self) -> bool:
        return False

    def write(self, data: bytes) -> None:
        self.written += data
        if self.after_write is not None:
            self.after_write()

    def close(self) -> None:
        pass

    def take(self) -> bytes:
        data = bytes(self.written)
        self.written.clear()
        return data


def outer(**fields) -> polo_pb2.OuterMessage:
    msg = polo_pb2.OuterMessage()
    msg.protocol_version = 2
    msg.status = polo_pb2.OuterMessage.Status.STATUS_OK
    for name, value in fields.items():
        getattr(msg, name).CopyFrom(value)
    return msg


def record(entries: list, name: str, direction: str, written: bytes) -> None:
    frames = split_frames(written)
    if len(frames) != 1:
        raise RuntimeError(f"{name}: expected one frame, got {len(frames)}")
    entries.append(
        {"name": name, "direction": direction, "framed": written.hex(), "payload": frames[0].hex()}
    )


def record_incoming(entries: list, name: str, msg) -> bytes:
    payload = msg.SerializeToString()
    entries.append({"name": name, "direction": "tv_to_client", "payload": payload.hex()})
    return payload


async def capture_pairing(tmpdir: str, client_pem: bytes, server_der: bytes, entries: list) -> dict:
    loop = asyncio.get_running_loop()
    certfile = os.path.join(tmpdir, "client.pem")
    write_bytes(certfile, client_pem)

    proto = PairingProtocol(loop.create_future(), "Remote", certfile, loop)
    transport = FakeTransport(server_der)
    proto.connection_made(transport)

    # 1. PairingRequest. The TV answers with an ack, the client then sends Options.
    start = asyncio.ensure_future(proto.async_start_pairing())
    await asyncio.sleep(0)
    record(entries, "pairing_request", "client_to_tv", transport.take())

    ack = outer(pairing_request_ack=polo_pb2.PairingRequestAck(server_name="Living Room TV"))
    proto._handle_message(record_incoming(entries, "pairing_request_ack", ack))
    record(entries, "options", "client_to_tv", transport.take())

    tv_options = polo_pb2.Options()
    enc = tv_options.input_encodings.add()
    enc.type = polo_pb2.Options.Encoding.ENCODING_TYPE_HEXADECIMAL
    enc.symbol_length = 6
    tv_options.preferred_role = polo_pb2.Options.RoleType.ROLE_TYPE_INPUT
    proto._handle_message(record_incoming(entries, "options_from_tv", outer(options=tv_options)))
    record(entries, "configuration", "client_to_tv", transport.take())

    proto._handle_message(
        record_incoming(entries, "configuration_ack", outer(configuration_ack=polo_pb2.ConfigurationAck()))
    )
    await start

    # 2. Find the one check byte that the reference accepts for our fixed suffix.
    def ack_secret() -> None:
        fut = proto._on_pairing_finished
        if fut is not None:
            loop.call_soon(lambda: fut.done() or fut.set_result(True))

    transport.after_write = ack_secret
    good_code = None
    for prefix in range(256):
        code = f"{prefix:02X}{CODE_SUFFIX}"
        try:
            await proto.async_finish_pairing(code)
        except InvalidAuth:
            continue
        good_code = code
        break
    if good_code is None:
        raise RuntimeError("no pairing code matched")
    transport.after_write = None
    secret_written = transport.take()
    record(entries, "secret", "client_to_tv", secret_written)

    sent = polo_pb2.OuterMessage()
    sent.ParseFromString(split_frames(secret_written)[0])
    bad_prefix = (int(good_code[:2], 16) + 1) % 256
    return {
        "code": good_code,
        "mismatched_code": f"{bad_prefix:02X}{CODE_SUFFIX}",
        "secret": sent.secret.secret.hex(),
    }


async def capture_remote(entries: list) -> None:
    loop = asyncio.get_running_loop()
    transport = FakeTransport()
    proto = RemoteProtocol(
        loop.create_future(),
        loop.create_future(),
        lambda _on: None,
        lambda _app: None,
        lambda _vol: None,
        loop,
        enable_ime=True,
        enable_voice=False,
    )
    proto.connection_made(transport)

    cfg = remotemessage_pb2.RemoteMessage()
    cfg.remote_configure.code1 = 622
    cfg.remote_configure.device_info.model = "Fixture TV"
    cfg.remote_configure.device_info.vendor = "Fixture Co"
    cfg.remote_configure.device_info.unknown1 = 1
    cfg.remote_configure.device_info.unknown2 = "1"
    cfg.remote_configure.device_info.package_name = "com.google.android.tv.remote.service"
    cfg.remote_configure.device_info.app_version = "5.2.473254133"
    proto._handle_message(record_incoming(entries, "remote_configure_from_tv", cfg))
    record(entries, "remote_configure", "client_to_tv", transport.take())

    act = remotemessage_pb2.RemoteMessage()
    act.remote_set_active.SetInParent()
    proto._handle_message(record_incoming(entries, "remote_set_active_from_tv", act))
    record(entries, "remote_set_active", "client_to_tv", transport.take())

    ping = remotemessage_pb2.RemoteMessage()
    ping.remote_ping_request.val1 = 7
    ping.remote_ping_request.val2 = 0
    proto._handle_message(record_incoming(entries, "remote_ping_request", ping))
    record(entries, "remote_ping_response", "client_to_tv", transport.take())

    started = remotemessage_pb2.RemoteMessage()
    started.remote_start.started = True
    proto._handle_message(record_incoming(entries, "remote_start", started))

    vol = remotemessage_pb2.RemoteMessage()
    vol.remote_set_volume_level.volume_max = 100
    vol.remote_set_volume_level.volume_level = 23
    vol.remote_set_volume_level.volume_muted = False
    proto._handle_message(record_incoming(entries, "remote_set_volume_level", vol))

    ime = remotemessage_pb2.RemoteMessage()
    ime.remote_ime_batch_edit.ime_counter = 5
    ime.remote_ime_batch_edit.field_counter = 3
    proto._handle_message(record_incoming(entries, "remote_ime_batch_edit_from_tv", ime))

    proto.send_key_command("DPAD_UP")
    record(entries, "key_dpad_up_short", "client_to_tv", transport.take())
    proto.send_key_command(23, "START_LONG")
    record(entries, "key_dpad_center_start_long", "client_to_tv", transport.take())
    proto.send_key_command(23, "END_LONG")
    record(entries, "key_dpad_center_end_long", "client_to_tv", transport.take())
    proto.send_key_command("VOLUME_UP")
    record(entries, "key_volume_up_short", "client_to_tv", transport.take())

    proto.send_text("hello")
    record(entries, "ime_text_hello", "client_to_tv", transport.take())

    proto.send_launch_app_command("https://www.youtube.com")
    record(entries, "app_link_launch", "client_to_tv", transport.take())

    proto.close()


async def main() -> int:
    tmpdir = tempfile.mkdtemp(prefix="atv-fixtures-")
    client_pem, _client_key = generate_selfsigned_cert("atvremote")
    server_pem, _server_key = generate_selfsigned_cert("fixture-tv")
    server_der = pem_to_der(server_pem)

    entries: list = []
    pairing = await capture_pairing(tmpdir, client_pem, server_der, entries)
    await capture_remote(entries)

    fixture = {
        "generated_by": "tools/fixtures/gen_androidtv_fixtures.py with androidtvremote2==0.3.2",
        "client_cert_der": pem_to_der(client_pem).hex(),
        "server_cert_der": server_der.hex(),
        "pairing": pairing,
        "messages": entries,
    }
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    write_text(OUT_PATH, json.dumps(fixture, indent=2) + "\n")
    print(f"wrote {len(entries)} messages and pairing vector to {OUT_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
