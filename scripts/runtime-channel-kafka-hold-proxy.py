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


class HoldProxy:
    def __init__(self, target_host: str, target_port: int, control_dir: Path) -> None:
        self.target = (target_host, target_port)
        self.control_dir = control_dir
        self.lock = threading.Lock()
        self.held: dict[int, bytes] = {}
        self.request_counts: dict[str, int] = {}

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

    def record_request(self, correlation: str, kafka_correlation: int) -> None:
        with self.lock:
            count = self.request_counts.get(correlation, 0) + 1
            self.request_counts[correlation] = count
            atomic_json(
                self.control_dir / "produce-observation.json",
                {
                    "correlation_id": correlation,
                    "kafka_correlation_id": kafka_correlation,
                    "produce_request_count": count,
                    "observed_at_ns": time.time_ns(),
                },
            )

    def client_to_broker(self, client: socket.socket, broker: socket.socket) -> None:
        try:
            while (frame := recv_frame(client)) is not None:
                body = frame[4:]
                api_key, _version, kafka_correlation = struct.unpack(">hhi", body[:8])
                hold = self.hold_value()
                if api_key == 0 and hold is not None and hold[1] in body:
                    with self.lock:
                        self.held[kafka_correlation] = b""
                    self.record_request(hold[0], kafka_correlation)
                broker.sendall(frame)
        finally:
            try:
                broker.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def broker_to_client(self, broker: socket.socket, client: socket.socket) -> None:
        try:
            while (frame := recv_frame(broker)) is not None:
                (kafka_correlation,) = struct.unpack(">i", frame[4:8])
                with self.lock:
                    should_hold = kafka_correlation in self.held
                if should_hold:
                    atomic_json(
                        self.control_dir / "response-held.json",
                        {
                            "kafka_correlation_id": kafka_correlation,
                            "held_at_ns": time.time_ns(),
                        },
                    )
                    while self.hold_path.exists():
                        time.sleep(0.01)
                    with self.lock:
                        self.held.pop(kafka_correlation, None)
                client.sendall(frame)
        finally:
            try:
                client.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def handle(self, client: socket.socket) -> None:
        try:
            broker = socket.create_connection(self.target, timeout=5)
            client.settimeout(None)
            broker.settimeout(None)
            upstream = threading.Thread(
                target=self.client_to_broker, args=(client, broker), daemon=True
            )
            upstream.start()
            self.broker_to_client(broker, client)
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
        atomic_json(
            args.control_dir / "endpoint.json",
            {"host": args.listen_host, "port": server.getsockname()[1], "pid": os.getpid()},
        )
        while True:
            client, _address = server.accept()
            threading.Thread(target=proxy.handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
