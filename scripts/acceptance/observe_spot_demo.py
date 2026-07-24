#!/usr/bin/env python3
"""Capture credential-free Binance Spot Demo evidence for one Hushine Session."""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import signal
import socket
import ssl
import stat
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any


MAX_JSON_BYTES = 2 * 1024 * 1024
FORBIDDEN_CREDENTIAL_ENV = (
    "BINANCE_API_KEY",
    "BINANCE_API_SECRET",
    "BINANCE_KEY",
    "BINANCE_SECRET",
    "SPOT_DEMO_API_KEY",
    "SPOT_DEMO_API_SECRET",
)
DECIMAL_PATTERN = re.compile(r"^-?[0-9]+(?:\.[0-9]+)?$")
INTEGER_PATTERN = re.compile(r"^[0-9]+$")
EVIDENCE_FIELDS = {
    "schema_version",
    "complete",
    "run_id",
    "user_id",
    "portfolio_id",
    "venue_id",
    "session_id",
    "capture_started_at",
    "capture_completed_at",
    "subscription",
    "orders",
    "trades",
    "balances",
    "requested_endpoints",
    "canonical_payload_sha256",
}


class ObserverError(RuntimeError):
    pass


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def safe_run_id(value: str) -> str:
    if not value or not value[0].isalnum() or any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for char in value):
        raise argparse.ArgumentTypeError("run ID contains unsafe characters")
    return value


def validate_public_base(raw: str, schemes: tuple[str, ...], description: str) -> urllib.parse.SplitResult:
    parsed = urllib.parse.urlsplit(raw)
    if parsed.scheme not in schemes or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ObserverError(f"invalid {description}")
    return parsed


def read_fd_json(fd: int) -> dict[str, str]:
    if fd < 3:
        raise ObserverError("credential FD must be inherited and distinct from standard streams")
    chunks: list[bytes] = []
    size = 0
    try:
        while True:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            size += len(chunk)
            if size > 16 * 1024:
                raise ObserverError("credential envelope is too large")
            chunks.append(chunk)
    except OSError as error:
        raise ObserverError("credential FD is not readable") from error
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
    try:
        value = json.loads(b"".join(chunks))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ObserverError("credential envelope is invalid") from error
    if not isinstance(value, dict) or set(value) != {"api_key", "api_secret"}:
        raise ObserverError("credential envelope must contain exactly api_key and api_secret")
    api_key = value.get("api_key")
    api_secret = value.get("api_secret")
    if not isinstance(api_key, str) or not api_key or not isinstance(api_secret, str) or not api_secret:
        raise ObserverError("credential envelope contains empty values")
    return {"api_key": api_key, "api_secret": api_secret}


def read_session_handoff(expected_run_id: str) -> str:
    descriptor = sys.stdin.fileno()
    line = bytearray()
    while len(line) <= 64 * 1024:
        chunk = os.read(descriptor, 1)
        if not chunk:
            break
        line.extend(chunk)
        if chunk == b"\n":
            break
    if not line or len(line) > 64 * 1024 or not line.endswith(b"\n"):
        raise ObserverError("missing newline-delimited Session handoff")
    was_blocking = os.get_blocking(descriptor)
    try:
        os.set_blocking(descriptor, False)
        try:
            extra = os.read(descriptor, 1)
        except BlockingIOError:
            extra = b""
    finally:
        os.set_blocking(descriptor, was_blocking)
    if extra:
        raise ObserverError("Session handoff must contain exactly one line")
    try:
        value = json.loads(bytes(line))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ObserverError("Session handoff is invalid") from error
    if not isinstance(value, dict) or set(value) != {"run_id", "session_id"}:
        raise ObserverError("Session handoff must contain exactly run_id and session_id")
    if value.get("run_id") != expected_run_id:
        raise ObserverError("Session handoff run ID does not match observer run")
    session_id = value.get("session_id")
    if not isinstance(session_id, str) or not session_id.strip() or len(session_id) > 256:
        raise ObserverError("Session handoff session ID is invalid")
    return session_id.strip()


def require_owned_coverage_root(path: Path) -> Path:
    if not path.is_absolute():
        raise ObserverError("coverage root must be absolute")
    try:
        info = path.lstat()
    except FileNotFoundError as error:
        raise ObserverError("coverage root does not exist") from error
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise ObserverError("coverage root must be a real directory")
    if info.st_uid != os.getuid():
        raise ObserverError("coverage root must be owned by the current UID")
    if stat.S_IMODE(info.st_mode) != 0o700:
        raise ObserverError("coverage root mode must be 0700")
    resolved = path.resolve(strict=True)
    if resolved != path:
        raise ObserverError("coverage root must be canonical")
    return resolved


def reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ObserverError("evidence JSON contains duplicate keys")
        value[key] = item
    return value


def read_owned_evidence(root: Path, path: Path) -> dict[str, Any]:
    if not path.is_absolute():
        raise ObserverError("evidence path must be absolute")
    if path != root / "exchange-evidence.json":
        raise ObserverError("evidence path must be the run-owned exchange artifact")
    try:
        before = path.lstat()
    except FileNotFoundError as error:
        raise ObserverError("evidence file does not exist") from error
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise ObserverError("evidence must be a regular non-symlink file")
    if before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) != 0o600 or before.st_nlink != 1:
        raise ObserverError("evidence ownership, mode, or link count is invalid")
    if before.st_size <= 0 or before.st_size > MAX_JSON_BYTES:
        raise ObserverError("evidence size is invalid")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags)
    except OSError as error:
        raise ObserverError("evidence cannot be opened safely") from error
    try:
        opened = os.fstat(fd)
        if not os.path.samestat(before, opened) or not stat.S_ISREG(opened.st_mode):
            raise ObserverError("evidence changed while being opened")
        chunks: list[bytes] = []
        size = 0
        while True:
            chunk = os.read(fd, 64 * 1024)
            if not chunk:
                break
            size += len(chunk)
            if size > MAX_JSON_BYTES:
                raise ObserverError("evidence is too large")
            chunks.append(chunk)
    finally:
        os.close(fd)
    try:
        value = json.loads(b"".join(chunks), object_pairs_hook=reject_duplicate_pairs)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ObserverError("evidence JSON is invalid") from error
    if not isinstance(value, dict):
        raise ObserverError("evidence must be a JSON object")
    return value


def require_exact_fields(value: Any, fields: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        raise ObserverError(f"evidence {label} fields are invalid")
    return value


def require_decimal(value: Any, label: str) -> str:
    if not isinstance(value, str) or DECIMAL_PATTERN.fullmatch(value) is None:
        raise ObserverError(f"evidence decimal is invalid: {label}")
    return value


def require_timestamp(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise ObserverError(f"evidence timestamp is invalid: {label}")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ObserverError(f"evidence timestamp is invalid: {label}") from error
    if parsed.tzinfo is None:
        raise ObserverError(f"evidence timestamp is invalid: {label}")
    return parsed


def reject_secret_shaped_evidence(value: Any) -> None:
    forbidden_keys = ("api_key", "api_secret", "signature", "authorization", "credential", "header", "listenkey")

    def visit(item: Any) -> None:
        if isinstance(item, dict):
            for key, child in item.items():
                lowered = str(key).lower()
                if any(name in lowered for name in forbidden_keys):
                    raise ObserverError("evidence contains a credential-shaped field")
                visit(child)
        elif isinstance(item, list):
            for child in item:
                visit(child)
        elif isinstance(item, str):
            lowered = item.lower()
            if any(marker in lowered for marker in ("x-mbx-apikey", "authorization:", "api_key", "api_secret", "listenkey")):
                raise ObserverError("evidence contains credential-shaped content")

    visit(value)


def validate_evidence_payload(
    value: dict[str, Any],
    *,
    run_id: str,
    user_id: int,
    portfolio_id: int,
    venue_id: int,
    session_id: str,
) -> None:
    require_exact_fields(value, EVIDENCE_FIELDS, "root")
    if value["schema_version"] != 1 or value["complete"] is not True:
        raise ObserverError("evidence is not a complete schema-v1 artifact")
    expected_identity = {
        "run_id": run_id,
        "user_id": user_id,
        "portfolio_id": portfolio_id,
        "venue_id": venue_id,
        "session_id": session_id,
    }
    for key, expected in expected_identity.items():
        if value.get(key) != expected or type(value.get(key)) is not type(expected):
            raise ObserverError(f"evidence identity does not match: {key}")
    started = require_timestamp(value["capture_started_at"], "capture_started_at")
    completed = require_timestamp(value["capture_completed_at"], "capture_completed_at")
    if completed < started:
        raise ObserverError("evidence capture timestamps are out of order")

    subscription = require_exact_fields(
        value["subscription"], {"request_id", "subscription_id", "status"}, "subscription"
    )
    if subscription.get("status") != "acknowledged":
        raise ObserverError("evidence subscription is not acknowledged")
    for field in ("request_id", "subscription_id"):
        if not isinstance(subscription.get(field), str) or not subscription[field]:
            raise ObserverError(f"evidence subscription field is invalid: {field}")

    order_fields = {
        "symbol", "side", "type", "status", "orderId", "clientOrderId",
        "origQty", "executedQty", "cummulativeQuoteQty",
    }
    orders = value["orders"]
    if not isinstance(orders, list) or not orders:
        raise ObserverError("evidence orders are missing")
    for index, raw in enumerate(orders):
        order = require_exact_fields(raw, order_fields, f"order[{index}]")
        for field in ("symbol", "type", "status", "orderId", "clientOrderId"):
            if not isinstance(order[field], str) or not order[field]:
                raise ObserverError(f"evidence order field is invalid: {field}")
        if order["side"] not in ("BUY", "SELL"):
            raise ObserverError("evidence order side is invalid")
        for field in ("origQty", "executedQty", "cummulativeQuoteQty"):
            require_decimal(order[field], f"order.{field}")
    if {item["symbol"] for item in orders} != {"BTCUSDT", "ETHUSDT"}:
        raise ObserverError("evidence orders do not cover both Spot symbols")

    trade_fields = {
        "symbol", "orderId", "id", "qty", "price", "quoteQty",
        "commission", "commissionAsset", "time",
    }
    trades = value["trades"]
    if not isinstance(trades, list) or not trades:
        raise ObserverError("evidence trades are missing")
    for index, raw in enumerate(trades):
        trade = require_exact_fields(raw, trade_fields, f"trade[{index}]")
        for field in ("symbol", "orderId", "id", "commissionAsset"):
            if not isinstance(trade[field], str) or not trade[field]:
                raise ObserverError(f"evidence trade field is invalid: {field}")
        if not isinstance(trade["time"], str) or INTEGER_PATTERN.fullmatch(trade["time"]) is None:
            raise ObserverError("evidence trade time is invalid")
        for field in ("qty", "price", "quoteQty", "commission"):
            require_decimal(trade[field], f"trade.{field}")
    if {item["symbol"] for item in trades} != {"BTCUSDT", "ETHUSDT"}:
        raise ObserverError("evidence trades do not cover both Spot symbols")

    balances = value["balances"]
    if not isinstance(balances, list) or not balances:
        raise ObserverError("evidence balances are missing")
    balance_assets: set[str] = set()
    for index, raw in enumerate(balances):
        balance = require_exact_fields(raw, {"asset", "free", "locked"}, f"balance[{index}]")
        asset = balance.get("asset")
        if not isinstance(asset, str) or not asset or asset in balance_assets or asset.endswith("USDT") and asset != "USDT":
            raise ObserverError("evidence balance asset is invalid or duplicated")
        balance_assets.add(asset)
        require_decimal(balance["free"], "balance.free")
        require_decimal(balance["locked"], "balance.locked")
    if not {"BTC", "ETH", "USDT"}.issubset(balance_assets):
        raise ObserverError("evidence balances are missing required assets")

    endpoints = value["requested_endpoints"]
    if not isinstance(endpoints, list) or len(endpoints) < 9:
        raise ObserverError("evidence endpoint proof is incomplete")
    paths: set[str] = set()
    for index, raw in enumerate(endpoints):
        endpoint = require_exact_fields(raw, {"path", "status"}, f"endpoint[{index}]")
        path = endpoint.get("path")
        status_code = endpoint.get("status")
        if not isinstance(path, str) or not path.startswith("/") or "?" in path:
            raise ObserverError("evidence endpoint path is invalid")
        if type(status_code) is not int or status_code != 200:
            raise ObserverError("evidence endpoint status is not successful")
        paths.add(path)
    required_paths = {
        "/api/v3/account", "/api/v3/exchangeInfo", "/api/v3/myFilters",
        "/api/v3/avgPrice", "/api/v3/allOrders", "/api/v3/myTrades", "/ws-api/v3",
    }
    if not required_paths.issubset(paths) or "/api/v3/userDataStream" in paths:
        raise ObserverError("evidence official endpoint proof is invalid")

    expected_hash = value["canonical_payload_sha256"]
    if not isinstance(expected_hash, str) or re.fullmatch(r"[0-9a-f]{64}", expected_hash) is None:
        raise ObserverError("evidence canonical hash is invalid")
    unhashed = dict(value)
    unhashed.pop("canonical_payload_sha256")
    canonical = json.dumps(unhashed, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if not hmac.compare_digest(hashlib.sha256(canonical).hexdigest(), expected_hash):
        raise ObserverError("evidence canonical hash does not match")
    reject_secret_shaped_evidence(value)


def validate_evidence_file(
    root: Path,
    path: Path,
    *,
    run_id: str,
    user_id: int,
    portfolio_id: int,
    venue_id: int,
    session_id: str,
) -> None:
    value = read_owned_evidence(root, path)
    validate_evidence_payload(
        value,
        run_id=run_id,
        user_id=user_id,
        portfolio_id=portfolio_id,
        venue_id=venue_id,
        session_id=session_id,
    )


def reserve_temporary(root: Path) -> tuple[Path, Path, int]:
    temporary = root / "exchange-evidence.json.tmp"
    final = root / "exchange-evidence.json"
    for candidate in (temporary, final):
        try:
            candidate.lstat()
        except FileNotFoundError:
            continue
        raise ObserverError(f"run-owned artifact already exists: {candidate.name}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(temporary, flags, 0o600)
    os.fchmod(fd, 0o600)
    return temporary, final, fd


def sign_params(params: dict[str, str], secret: str) -> str:
    query = urllib.parse.urlencode(sorted(params.items()))
    return hmac.new(secret.encode(), query.encode(), hashlib.sha256).hexdigest()


class ExchangeClient:
    def __init__(self, http_base: str, ws_url: str, api_key: str, api_secret: str, deadline: float) -> None:
        self.http_base = http_base.rstrip("/")
        self.ws_url = ws_url
        self.api_key = api_key
        self.api_secret = api_secret
        self.deadline = deadline
        self.requested: list[dict[str, Any]] = []

    def remaining(self) -> float:
        value = self.deadline - time.monotonic()
        if value <= 0:
            raise ObserverError("exchange evidence capture timed out")
        return max(0.05, value)

    def get_json(self, path: str, params: dict[str, str] | None = None, signed: bool = False) -> Any:
        query_params = dict(params or {})
        if signed:
            query_params["timestamp"] = str(int(time.time() * 1000))
            query_params["signature"] = sign_params(query_params, self.api_secret)
        query = urllib.parse.urlencode(query_params)
        url = f"{self.http_base}{path}{'?' + query if query else ''}"
        headers = {"Accept": "application/json"}
        if signed:
            headers["X-MBX-APIKEY"] = self.api_key
        status = 0
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=self.remaining()) as response:
                status = int(response.status)
                body = response.read(MAX_JSON_BYTES + 1)
        except urllib.error.HTTPError as error:
            status = int(error.code)
            self.requested.append({"path": path, "status": status})
            raise ObserverError(f"exchange request failed: {path} status {status}") from None
        except (urllib.error.URLError, TimeoutError, socket.timeout, OSError) as error:
            self.requested.append({"path": path, "status": 599})
            raise ObserverError(f"exchange request failed: {path} network error") from error
        self.requested.append({"path": path, "status": status})
        if status != 200:
            raise ObserverError(f"exchange request failed: {path} status {status}")
        if len(body) > MAX_JSON_BYTES:
            raise ObserverError(f"exchange response is too large: {path}")
        try:
            return json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ObserverError(f"exchange response schema is invalid: {path}") from error

    def subscribe(self, request_id: str) -> dict[str, str]:
        parsed = validate_public_base(self.ws_url, ("ws", "wss"), "WebSocket URL")
        port = parsed.port or (443 if parsed.scheme == "wss" else 80)
        raw_socket = socket.create_connection((parsed.hostname, port), timeout=self.remaining())
        connection: socket.socket
        if parsed.scheme == "wss":
            connection = ssl.create_default_context().wrap_socket(raw_socket, server_hostname=parsed.hostname)
        else:
            connection = raw_socket
        connection.settimeout(self.remaining())
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        path = parsed.path or "/"
        host = parsed.hostname if parsed.port is None else f"{parsed.hostname}:{parsed.port}"
        handshake = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        ).encode()
        try:
            connection.sendall(handshake)
            header = receive_until(connection, b"\r\n\r\n", 64 * 1024)
            first_line = header.split(b"\r\n", 1)[0]
            if b" 101 " not in first_line:
                self.requested.append({"path": path, "status": 502})
                raise ObserverError("WebSocket subscription handshake failed")
            timestamp = str(int(time.time() * 1000))
            params = {"apiKey": self.api_key, "timestamp": timestamp}
            params["signature"] = sign_params(params, self.api_secret)
            message = json.dumps({
                "id": request_id,
                "method": "userDataStream.subscribe.signature",
                "params": params,
            }, separators=(",", ":")).encode()
            connection.sendall(masked_websocket_text_frame(message))
            response = json.loads(read_websocket_text(connection))
        except (OSError, ValueError, json.JSONDecodeError) as error:
            self.requested.append({"path": path, "status": 599})
            raise ObserverError("WebSocket subscription failed") from error
        finally:
            connection.close()
        status = int(response.get("status", 0)) if isinstance(response, dict) else 0
        self.requested.append({"path": path, "status": status or 500})
        result = response.get("result") if isinstance(response, dict) else None
        subscription_id = result.get("subscriptionId") if isinstance(result, dict) else None
        if status != 200 or subscription_id is None or str(response.get("id", "")) != request_id:
            raise ObserverError("WebSocket subscription was not acknowledged")
        return {"request_id": request_id, "subscription_id": str(subscription_id), "status": "acknowledged"}


def receive_exact(connection: socket.socket, count: int) -> bytes:
    chunks: list[bytes] = []
    remaining = count
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise ValueError("connection closed")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def receive_until(connection: socket.socket, marker: bytes, limit: int) -> bytes:
    value = bytearray()
    while marker not in value:
        chunk = connection.recv(4096)
        if not chunk:
            raise ValueError("connection closed")
        value.extend(chunk)
        if len(value) > limit:
            raise ValueError("response is too large")
    return bytes(value)


def masked_websocket_text_frame(payload: bytes) -> bytes:
    mask = secrets.token_bytes(4)
    length = len(payload)
    if length < 126:
        header = bytes((0x81, 0x80 | length))
    elif length <= 0xFFFF:
        header = bytes((0x81, 0x80 | 126)) + struct.pack("!H", length)
    else:
        header = bytes((0x81, 0x80 | 127)) + struct.pack("!Q", length)
    masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return header + mask + masked


def read_websocket_text(connection: socket.socket) -> bytes:
    header = receive_exact(connection, 2)
    opcode = header[0] & 0x0F
    if opcode != 1:
        raise ValueError("expected text frame")
    length = header[1] & 0x7F
    if length == 126:
        length = struct.unpack("!H", receive_exact(connection, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", receive_exact(connection, 8))[0]
    if header[1] & 0x80:
        raise ValueError("server frames must not be masked")
    if length > MAX_JSON_BYTES:
        raise ValueError("WebSocket response is too large")
    return receive_exact(connection, length)


def require_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise ObserverError(f"exchange response field is invalid: {field}")
    return value


def normalize_orders(value: Any) -> list[dict[str, str]]:
    if not isinstance(value, list):
        raise ObserverError("exchange order response must be an array")
    required = ("symbol", "side", "type", "status", "orderId", "clientOrderId", "origQty", "executedQty", "cummulativeQuoteQty")
    output: list[dict[str, str]] = []
    for item in value:
        if not isinstance(item, dict):
            raise ObserverError("exchange order entry is invalid")
        row: dict[str, str] = {}
        for field in required:
            raw = item.get(field)
            if field == "orderId" and isinstance(raw, int):
                raw = str(raw)
            row[field] = require_string(raw, f"order.{field}")
        for field in ("origQty", "executedQty", "cummulativeQuoteQty"):
            if DECIMAL_PATTERN.fullmatch(row[field]) is None:
                raise ObserverError(f"exchange response field is invalid: order.{field}")
        if row["side"] not in ("BUY", "SELL"):
            raise ObserverError("exchange order side is invalid")
        output.append(row)
    return output


def normalize_trades(value: Any) -> list[dict[str, str]]:
    if not isinstance(value, list):
        raise ObserverError("exchange trade response must be an array")
    required = ("symbol", "orderId", "id", "qty", "price", "quoteQty", "commission", "commissionAsset", "time")
    output: list[dict[str, str]] = []
    for item in value:
        if not isinstance(item, dict):
            raise ObserverError("exchange trade entry is invalid")
        row: dict[str, str] = {}
        for field in required:
            raw = item.get(field)
            if field in ("orderId", "id", "time") and isinstance(raw, int):
                raw = str(raw)
            row[field] = require_string(raw, f"trade.{field}")
        for field in ("qty", "price", "quoteQty", "commission"):
            if DECIMAL_PATTERN.fullmatch(row[field]) is None:
                raise ObserverError(f"exchange response field is invalid: trade.{field}")
        output.append(row)
    return output


def normalize_balances(account: Any) -> list[dict[str, str]]:
    if not isinstance(account, dict) or account.get("canTrade") is not True or account.get("accountType") != "SPOT":
        raise ObserverError("exchange account capability is invalid")
    values = account.get("balances")
    if not isinstance(values, list):
        raise ObserverError("exchange account balances are invalid")
    output: list[dict[str, str]] = []
    seen: set[str] = set()
    for item in values:
        if not isinstance(item, dict):
            raise ObserverError("exchange balance entry is invalid")
        asset = require_string(item.get("asset"), "balance.asset").upper()
        free = require_string(item.get("free"), "balance.free")
        locked = require_string(item.get("locked"), "balance.locked")
        if asset in seen or asset in ("BTCUSDT", "ETHUSDT"):
            raise ObserverError("exchange balance asset is duplicated or symbol-shaped")
        seen.add(asset)
        if DECIMAL_PATTERN.fullmatch(free) is None or DECIMAL_PATTERN.fullmatch(locked) is None:
            raise ObserverError("exchange balance decimal is invalid")
        try:
            empty = Decimal(free) == 0 and Decimal(locked) == 0
        except InvalidOperation as error:
            raise ObserverError("exchange balance decimal is invalid") from error
        if empty and asset != "USDT":
            continue
        output.append({"asset": asset, "free": free, "locked": locked})
    return output


def capture(client: ExchangeClient, run_id: str) -> tuple[dict[str, str], list[dict[str, str]], list[dict[str, str]], list[dict[str, str]]]:
    symbols = ("BTCUSDT", "ETHUSDT")
    exchange_info = client.get_json(
        "/api/v3/exchangeInfo",
        {"symbols": json.dumps(symbols, separators=(",", ":"))},
    )
    if not isinstance(exchange_info, dict) or not isinstance(exchange_info.get("symbols"), list):
        raise ObserverError("exchange metadata response is invalid")
    metadata_symbols = {
        require_string(item.get("symbol"), "exchangeInfo.symbol")
        for item in exchange_info["symbols"]
        if isinstance(item, dict)
    }
    if metadata_symbols != set(symbols):
        raise ObserverError("exchange metadata does not contain both declared symbols")
    for symbol in symbols:
        account_filters = client.get_json("/api/v3/myFilters", {"symbol": symbol}, signed=True)
        if not isinstance(account_filters, dict) or any(
            not isinstance(account_filters.get(field), list)
            for field in ("exchangeFilters", "symbolFilters", "assetFilters")
        ):
            raise ObserverError("exchange account filter response is invalid")
        avg_price = client.get_json("/api/v3/avgPrice", {"symbol": symbol})
        if not isinstance(avg_price, dict) or not isinstance(avg_price.get("price"), str):
            raise ObserverError("exchange average price response is invalid")
    subscription = client.subscribe(f"spot-demo-{run_id}")

    orders: list[dict[str, str]] = []
    trades: list[dict[str, str]] = []
    while {item["symbol"] for item in orders} != set(symbols) or {item["symbol"] for item in trades} != set(symbols):
        orders = []
        trades = []
        for symbol in symbols:
            orders.extend(normalize_orders(client.get_json("/api/v3/allOrders", {"symbol": symbol}, signed=True)))
            trades.extend(normalize_trades(client.get_json("/api/v3/myTrades", {"symbol": symbol}, signed=True)))
        if {item["symbol"] for item in orders} != set(symbols) or {item["symbol"] for item in trades} != set(symbols):
            client.remaining()
            time.sleep(min(0.5, client.remaining()))
    account = client.get_json("/api/v3/account", signed=True)
    return subscription, orders, trades, normalize_balances(account)


def publish(fd: int, temporary: Path, final: Path, payload: dict[str, Any]) -> None:
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    payload["canonical_payload_sha256"] = hashlib.sha256(canonical).hexdigest()
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"
    view = memoryview(encoded)
    while view:
        written = os.write(fd, view)
        view = view[written:]
    os.fsync(fd)
    os.close(fd)
    os.replace(temporary, final)
    directory_fd = os.open(final.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-id", required=True, type=safe_run_id)
    parser.add_argument("--user-id", required=True, type=positive_int)
    parser.add_argument("--portfolio-id", required=True, type=positive_int)
    parser.add_argument("--venue-id", required=True, type=positive_int)
    parser.add_argument("--coverage-root", required=True, type=Path)
    parser.add_argument("--credential-fd", type=int)
    parser.add_argument("--validate-evidence", type=Path)
    parser.add_argument("--session-id")
    parser.add_argument("--timeout-seconds", type=positive_int, default=60)
    args = parser.parse_args()

    for name in FORBIDDEN_CREDENTIAL_ENV:
        if os.environ.get(name):
            raise ObserverError(f"credential environment is forbidden: {name}")
    root = require_owned_coverage_root(args.coverage_root)
    if args.validate_evidence is not None:
        if args.credential_fd is not None or not isinstance(args.session_id, str) or not args.session_id.strip():
            raise ObserverError("validation requires session ID and forbids credential FD")
        validate_evidence_file(
            root,
            args.validate_evidence,
            run_id=args.run_id,
            user_id=args.user_id,
            portfolio_id=args.portfolio_id,
            venue_id=args.venue_id,
            session_id=args.session_id.strip(),
        )
        print("evidence_valid=true")
        return 0
    if args.credential_fd is None or args.session_id is not None:
        raise ObserverError("capture requires credential FD and forbids session ID")
    temporary, final, temporary_fd = reserve_temporary(root)
    cleanup_needed = True

    def cleanup() -> None:
        nonlocal cleanup_needed, temporary_fd
        if not cleanup_needed:
            return
        cleanup_needed = False
        if temporary_fd >= 0:
            try:
                os.close(temporary_fd)
            except OSError:
                pass
            temporary_fd = -1
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass

    def handle_signal(signum: int, _frame: Any) -> None:
        cleanup()
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    try:
        credential = read_fd_json(args.credential_fd)
        session_id = read_session_handoff(args.run_id)
        started_at = utc_now()
        http_base = os.environ.get("HUSHINE_SPOT_DEMO_HTTP_BASE", "https://demo-api.binance.com")
        ws_url = os.environ.get(
            "HUSHINE_SPOT_DEMO_WS_URL",
            "wss://demo-ws-api.binance.com/ws-api/v3",
        )
        validate_public_base(http_base, ("http", "https"), "HTTP base")
        validate_public_base(ws_url, ("ws", "wss"), "WebSocket URL")
        client = ExchangeClient(
            http_base=http_base,
            ws_url=ws_url,
            api_key=credential["api_key"],
            api_secret=credential["api_secret"],
            deadline=time.monotonic() + args.timeout_seconds,
        )
        credential.clear()
        subscription, orders, trades, balances = capture(client, args.run_id)
        payload: dict[str, Any] = {
            "schema_version": 1,
            "complete": True,
            "run_id": args.run_id,
            "user_id": args.user_id,
            "portfolio_id": args.portfolio_id,
            "venue_id": args.venue_id,
            "session_id": session_id,
            "capture_started_at": started_at,
            "capture_completed_at": utc_now(),
            "subscription": subscription,
            "orders": orders,
            "trades": trades,
            "balances": balances,
            "requested_endpoints": client.requested,
        }
        publish(temporary_fd, temporary, final, payload)
        temporary_fd = -1
        cleanup_needed = False
    except BaseException:
        cleanup()
        raise
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ObserverError as error:
        print(f"observer failed: {error}", file=sys.stderr)
        raise SystemExit(1) from None
