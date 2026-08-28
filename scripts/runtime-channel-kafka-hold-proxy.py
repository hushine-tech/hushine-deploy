#!/usr/bin/env python3
"""Harness-owned Kafka proxy that can hold one correlated Produce response.

The proxy is deliberately Kafka-frame aware: metadata and API negotiation keep
flowing, while a Produce request containing the owner correlation is recorded
and its matching response is withheld until the hold file is removed.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import struct
import threading
import time
from pathlib import Path


def atomic_json(path: Path, value: dict[str, object]) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{time.time_ns()}.tmp")
    with temporary.open("x", encoding="utf-8") as handle:
        os.chmod(temporary, 0o600)
        json.dump(value, handle, separators=(",", ":"), sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def recv_exact(sock: socket.socket, size: int) -> bytes | None:
    chunks: list[bytes] = []
    remaining = size
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            return None
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def recv_frame(sock: socket.socket) -> bytes | None:
    header = recv_exact(sock, 4)
    if header is None:
        return None
    (size,) = struct.unpack(">i", header)
    if size < 4 or size > 128 * 1024 * 1024:
        raise RuntimeError(f"unsafe Kafka frame size: {size}")
    body = recv_exact(sock, size)
    return None if body is None else header + body


def rewrite_metadata_response(
    frame: bytes, version: int, advertised_host: str, advertised_port: int
) -> bytes:
    """Rewrite non-flexible Metadata v0-v8 broker endpoints."""
    if version < 0 or version > 8:
        raise RuntimeError(f"unsupported Metadata response version: {version}")
    body = frame[4:]
    offset = 4  # correlation id

    def take(size: int) -> bytes:
        nonlocal offset
        if size < 0 or offset + size > len(body):
            raise RuntimeError("truncated Kafka Metadata response")
        value = body[offset : offset + size]
        offset += size
        return value

    if version >= 3:
        take(4)  # throttle time
    prefix_end = offset
    (broker_count,) = struct.unpack(">i", take(4))
    if broker_count < 0 or broker_count > 10000:
        raise RuntimeError(f"unsafe Kafka Metadata broker count: {broker_count}")
    rewritten = bytearray(body[:prefix_end])
    rewritten.extend(struct.pack(">i", broker_count))
    encoded_host = advertised_host.encode("utf-8")
    if not encoded_host or len(encoded_host) > 32767:
        raise RuntimeError("unsafe advertised Kafka proxy host")
    for _ in range(broker_count):
        node_id = take(4)
        (host_size,) = struct.unpack(">h", take(2))
        if host_size < 0:
            raise RuntimeError("Kafka Metadata broker host is null")
        take(host_size)
        take(4)  # original port
        rewritten.extend(node_id)
        rewritten.extend(struct.pack(">h", len(encoded_host)))
        rewritten.extend(encoded_host)
        rewritten.extend(struct.pack(">i", advertised_port))
        if version >= 1:
            rack_size_raw = take(2)
            (rack_size,) = struct.unpack(">h", rack_size_raw)
            if rack_size < -1:
                raise RuntimeError("invalid Kafka Metadata rack length")
            rewritten.extend(rack_size_raw)
            if rack_size >= 0:
                rewritten.extend(take(rack_size))
    rewritten.extend(body[offset:])
    return struct.pack(">i", len(rewritten)) + bytes(rewritten)


class HoldProxy:
    def __init__(self, target_host: str, target_port: int, control_dir: Path) -> None:
        self.target = (target_host, target_port)
        self.control_dir = control_dir
        self.lock = threading.Lock()
        self.held: dict[tuple[int, int], bytes] = {}
        self.requests: dict[tuple[int, int], tuple[int, int]] = {}
        self.request_counts: dict[str, int] = {}
        self.advertised_endpoint: tuple[str, int] | None = None
        self.next_connection_id = 1

    def set_advertised_endpoint(self, host: str, port: int) -> None:
        if not host or port <= 0 or port >= 65536:
            raise RuntimeError("invalid advertised Kafka proxy endpoint")
        self.advertised_endpoint = (host, port)

    def allocate_connection_id(self) -> int:
        with self.lock:
            connection_id = self.next_connection_id
            self.next_connection_id += 1
        return connection_id

    @property
    def hold_path(self) -> Path:
        return self.control_dir / "hold.json"

    def hold_value(self) -> tuple[str, bytes] | None:
        try:
            raw = json.loads(self.hold_path.read_text(encoding="utf-8"))
            correlation = str(raw.get("correlation_id") or "")
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return None
        if not correlation or not correlation.startswith("rpc-"):
            return None
        return correlation, correlation.encode("utf-8")

    def record_request(
        self, correlation: str, connection_id: int, kafka_correlation: int
    ) -> None:
        with self.lock:
            count = self.request_counts.get(correlation, 0) + 1
            self.request_counts[correlation] = count
            atomic_json(
                self.control_dir / "produce-observation.json",
                {
                    "correlation_id": correlation,
                    "connection_id": connection_id,
                    "kafka_correlation_id": kafka_correlation,
                    "produce_request_count": count,
                    "observed_at_ns": time.time_ns(),
                },
            )

    def client_to_broker(
        self, connection_id: int, client: socket.socket, broker: socket.socket
    ) -> None:
        try:
            while (frame := recv_frame(client)) is not None:
                body = frame[4:]
                if len(body) < 8:
                    raise RuntimeError("truncated Kafka request header")
                api_key, version, kafka_correlation = struct.unpack(">hhi", body[:8])
                request_key = (connection_id, kafka_correlation)
                with self.lock:
                    if request_key in self.requests:
                        raise RuntimeError("duplicate in-flight Kafka correlation")
                    self.requests[request_key] = (api_key, version)
                hold = self.hold_value()
                if api_key == 0 and hold is not None and hold[1] in body:
                    with self.lock:
                        self.held[request_key] = b""
                    self.record_request(hold[0], connection_id, kafka_correlation)
                broker.sendall(frame)
        finally:
            try:
                broker.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def broker_to_client(
        self, connection_id: int, broker: socket.socket, client: socket.socket
    ) -> None:
        try:
            while (frame := recv_frame(broker)) is not None:
                (kafka_correlation,) = struct.unpack(">i", frame[4:8])
                request_key = (connection_id, kafka_correlation)
                with self.lock:
                    request = self.requests.pop(request_key, None)
                    should_hold = request_key in self.held
                if request is None:
                    raise RuntimeError("Kafka response has no matching request on connection")
                api_key, version = request
                if api_key == 3:
                    if self.advertised_endpoint is None:
                        raise RuntimeError("Kafka proxy advertised endpoint is unset")
                    frame = rewrite_metadata_response(
                        frame, version, *self.advertised_endpoint
                    )
                    atomic_json(
                        self.control_dir / "metadata-observation.json",
                        {
                            "api_key": api_key,
                            "api_version": version,
                            "connection_id": connection_id,
                            "kafka_correlation_id": kafka_correlation,
                            "advertised_endpoint": (
                                f"{self.advertised_endpoint[0]}:"
                                f"{self.advertised_endpoint[1]}"
                            ),
                            "observed_at_ns": time.time_ns(),
                        },
                    )
                if should_hold:
                    atomic_json(
                        self.control_dir / "response-held.json",
                        {
                            "kafka_correlation_id": kafka_correlation,
                            "connection_id": connection_id,
                            "held_at_ns": time.time_ns(),
                        },
                    )
                    while self.hold_path.exists():
                        time.sleep(0.01)
                    with self.lock:
                        self.held.pop(request_key, None)
                client.sendall(frame)
        finally:
            try:
                client.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def handle(self, client: socket.socket) -> None:
        connection_id = self.allocate_connection_id()
        try:
            broker = socket.create_connection(self.target, timeout=5)
            client.settimeout(None)
            broker.settimeout(None)
            upstream = threading.Thread(
                target=self.client_to_broker,
                args=(connection_id, client, broker),
                daemon=True,
            )
            upstream.start()
            self.broker_to_client(connection_id, broker, client)
        except (OSError, RuntimeError):
            pass
        finally:
            try:
                client.close()
            except OSError:
                pass


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, default=0)
    parser.add_argument("--target-host", default="127.0.0.1")
    parser.add_argument("--target-port", type=int, required=True)
    parser.add_argument("--control-dir", type=Path, required=True)
    args = parser.parse_args()
    args.control_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(args.control_dir, 0o700)
    proxy = HoldProxy(args.target_host, args.target_port, args.control_dir)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((args.listen_host, args.listen_port))
        server.listen(16)
        proxy.set_advertised_endpoint(args.listen_host, server.getsockname()[1])
        atomic_json(
            args.control_dir / "endpoint.json",
            {"host": args.listen_host, "port": server.getsockname()[1], "pid": os.getpid()},
        )
        while True:
            client, _address = server.accept()
            threading.Thread(target=proxy.handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
