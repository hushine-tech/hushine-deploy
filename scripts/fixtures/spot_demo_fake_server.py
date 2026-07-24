#!/usr/bin/env python3
"""Behavioral Binance Spot REST/WebSocket API fixture for acceptance contracts."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import signal
import struct
import threading
import time
import urllib.parse
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


class FixtureState:
    def __init__(self, path: Path, scenario: str) -> None:
        self.path = path
        self.scenario = scenario
        self.lock = threading.Lock()
        self.value: dict[str, Any] = {
            "port": 0,
            "scenario": scenario,
            "requests": [],
            "subscription_method": "",
            "credential_header_seen": False,
        }

    def publish(self) -> None:
        encoded = json.dumps(self.value, sort_keys=True, separators=(",", ":"))
        temporary = self.path.with_name(f".{self.path.name}.{os.getpid()}.tmp")
        temporary.write_text(encoded, encoding="utf-8")
        os.replace(temporary, self.path)

    def ready(self, port: int) -> None:
        with self.lock:
            self.value["port"] = port
            self.publish()

    def record(self, path: str, status: int, credential_seen: bool = False) -> None:
        with self.lock:
            self.value["requests"].append({"path": path, "status": status})
            self.value["credential_header_seen"] = self.value["credential_header_seen"] or credential_seen
            self.publish()

    def subscription(self, method: str, status: int) -> None:
        with self.lock:
            self.value["subscription_method"] = method
            self.value["requests"].append({"path": "/ws-api/v3", "status": status})
            self.publish()


def json_bytes(value: Any) -> bytes:
    return json.dumps(value, separators=(",", ":")).encode("utf-8")


def read_websocket_frame(stream: Any) -> bytes:
    first = stream.read(2)
    if len(first) != 2:
        raise ValueError("missing WebSocket frame")
    _opcode = first[0] & 0x0F
    masked = bool(first[1] & 0x80)
    length = first[1] & 0x7F
    if length == 126:
        length = struct.unpack("!H", stream.read(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", stream.read(8))[0]
    mask = stream.read(4) if masked else b""
    payload = bytearray(stream.read(length))
    if len(payload) != length:
        raise ValueError("truncated WebSocket frame")
    if mask:
        for index in range(length):
            payload[index] ^= mask[index % 4]
    return bytes(payload)


def websocket_text_frame(payload: bytes) -> bytes:
    length = len(payload)
    if length < 126:
        header = bytes((0x81, length))
    elif length <= 0xFFFF:
        header = bytes((0x81, 126)) + struct.pack("!H", length)
    else:
        header = bytes((0x81, 127)) + struct.pack("!Q", length)
    return header + payload


class BinanceFixtureHandler(BaseHTTPRequestHandler):
    server: "BinanceFixtureServer"
    protocol_version = "HTTP/1.1"

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def write_json(self, status: int, value: Any) -> None:
        body = json_bytes(value)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        parsed_path = urllib.parse.urlsplit(self.path)
        path = parsed_path.path
        if path == "/ws-api/v3" and self.headers.get("Upgrade", "").lower() == "websocket":
            self.handle_websocket(path)
            return

        credential_seen = self.headers.get("X-MBX-APIKEY") == "demo-key"
        scenario = self.server.state.scenario
        if scenario == "429" and path == "/api/v3/account":
            self.server.state.record(path, HTTPStatus.TOO_MANY_REQUESTS, credential_seen)
            self.write_json(HTTPStatus.TOO_MANY_REQUESTS, {"code": -1003, "msg": "Too many requests"})
            return
        if scenario == "permission" and path == "/api/v3/account":
            self.server.state.record(path, HTTPStatus.UNAUTHORIZED, credential_seen)
            self.write_json(HTTPStatus.UNAUTHORIZED, {"code": -2015, "msg": "Invalid API-key, IP, or permissions"})
            return
        if scenario == "5xx" and path == "/api/v3/exchangeInfo":
            self.server.state.record(path, HTTPStatus.SERVICE_UNAVAILABLE, credential_seen)
            self.write_json(HTTPStatus.SERVICE_UNAVAILABLE, {"code": -1000, "msg": "Internal error"})
            return
        if scenario == "timeout" and path == "/api/v3/myTrades":
            time.sleep(3)

        routes: dict[str, Any] = {
            "/api/v3/account": {
                "canTrade": True,
                "accountType": "SPOT",
                "permissions": ["SPOT"],
                "balances": [
                    {"asset": "USDT", "free": "949.75000000", "locked": "0.00000000"},
                    {"asset": "BTC", "free": "0.00100000", "locked": "0.00000000"},
                    {"asset": "ETH", "free": "0.01000000", "locked": "0.00000000"},
                ],
            },
            "/api/v3/exchangeInfo": {
                "timezone": "UTC",
                "serverTime": 1780000000000,
                "symbols": [
                    {
                        "symbol": "BTCUSDT",
                        "status": "TRADING",
                        "baseAsset": "BTC",
                        "baseAssetPrecision": 8,
                        "quoteAsset": "USDT",
                        "quoteAssetPrecision": 8,
                        "orderTypes": ["LIMIT", "MARKET"],
                        "isSpotTradingAllowed": True,
                        "permissionSets": [["SPOT"]],
                        "filters": [
                            {"filterType": "PRICE_FILTER", "minPrice": "0.01000000", "maxPrice": "1000000.00000000", "tickSize": "0.01000000"},
                            {"filterType": "LOT_SIZE", "minQty": "0.00001000", "maxQty": "9000.00000000", "stepSize": "0.00001000"},
                            {"filterType": "NOTIONAL", "minNotional": "5.00000000", "applyMinToMarket": True, "maxNotional": "1000000.00000000", "applyMaxToMarket": False},
                        ],
                    },
                    {
                        "symbol": "ETHUSDT",
                        "status": "TRADING",
                        "baseAsset": "ETH",
                        "baseAssetPrecision": 8,
                        "quoteAsset": "USDT",
                        "quoteAssetPrecision": 8,
                        "orderTypes": ["LIMIT", "MARKET"],
                        "isSpotTradingAllowed": True,
                        "permissionSets": [["SPOT"]],
                        "filters": [
                            {"filterType": "PRICE_FILTER", "minPrice": "0.01000000", "maxPrice": "100000.00000000", "tickSize": "0.01000000"},
                            {"filterType": "LOT_SIZE", "minQty": "0.00010000", "maxQty": "9000.00000000", "stepSize": "0.00010000"},
                            {"filterType": "NOTIONAL", "minNotional": "5.00000000", "applyMinToMarket": True, "maxNotional": "1000000.00000000", "applyMaxToMarket": False},
                        ],
                    },
                ],
            },
            "/api/v3/myFilters": {
                "exchangeFilters": [{"filterType": "EXCHANGE_MAX_NUM_ORDERS", "maxNumOrders": 200}],
                "symbolFilters": [],
                "assetFilters": [],
            },
            "/api/v3/avgPrice": {"mins": 5, "price": "50000.00000000", "closeTime": 1780000000000},
            "/api/v3/allOrders": [
                {"symbol": "BTCUSDT", "side": "BUY", "type": "MARKET", "status": "FILLED", "orderId": 9001, "clientOrderId": "hushine-buy-1", "origQty": "0.00100000", "executedQty": "0.00100000", "cummulativeQuoteQty": "50.00000000"},
                {"symbol": "ETHUSDT", "side": "SELL", "type": "MARKET", "status": "FILLED", "orderId": 9002, "clientOrderId": "hushine-sell-1", "origQty": "0.01000000", "executedQty": "0.01000000", "cummulativeQuoteQty": "30.00000000"},
            ],
            "/api/v3/myTrades": [
                {"symbol": "BTCUSDT", "orderId": 9001, "id": 7001, "qty": "0.00100000", "price": "50000.00000000", "quoteQty": "50.00000000", "commission": "0.00000100", "commissionAsset": "BTC", "time": 1780000000100},
                {"symbol": "ETHUSDT", "orderId": 9002, "id": 7002, "qty": "0.01000000", "price": "3000.00000000", "quoteQty": "30.00000000", "commission": "0.03000000", "commissionAsset": "USDT", "time": 1780000000200},
            ],
        }
        if path not in routes:
            self.server.state.record(path, HTTPStatus.NOT_FOUND, credential_seen)
            self.write_json(HTTPStatus.NOT_FOUND, {"code": -1002, "msg": "unknown fixture endpoint"})
            return
        value = routes[path]
        if path == "/api/v3/myFilters":
            symbol = urllib.parse.parse_qs(parsed_path.query).get("symbol", [""])[0]
            if symbol not in ("BTCUSDT", "ETHUSDT"):
                self.server.state.record(path, HTTPStatus.BAD_REQUEST, credential_seen)
                self.write_json(HTTPStatus.BAD_REQUEST, {"code": -1102, "msg": "symbol is mandatory"})
                return
        if path in ("/api/v3/allOrders", "/api/v3/myTrades"):
            symbol = urllib.parse.parse_qs(parsed_path.query).get("symbol", [""])[0]
            value = [item for item in value if item["symbol"] == symbol]
        if scenario == "schema" and path == "/api/v3/allOrders":
            value = {"orders": value}
        self.server.state.record(path, HTTPStatus.OK, credential_seen)
        self.write_json(HTTPStatus.OK, value)

    def handle_websocket(self, path: str) -> None:
        key = self.headers.get("Sec-WebSocket-Key", "")
        if not key:
            self.server.state.subscription("", HTTPStatus.BAD_REQUEST)
            self.write_json(HTTPStatus.BAD_REQUEST, {"error": "missing WebSocket key"})
            return
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(HTTPStatus.SWITCHING_PROTOCOLS)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        request = json.loads(read_websocket_frame(self.rfile))
        method = str(request.get("method", ""))
        request_id = str(request.get("id", ""))
        if self.server.state.scenario == "subscription":
            response = {"id": request_id, "status": 401, "error": {"code": -2015, "msg": "subscription rejected"}}
            status = HTTPStatus.UNAUTHORIZED
        else:
            response = {"id": request_id, "status": 200, "result": {"subscriptionId": 12345}}
            status = HTTPStatus.OK
        self.server.state.subscription(method, status)
        self.connection.sendall(websocket_text_frame(json_bytes(response)))
        self.close_connection = True


class BinanceFixtureServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], state: FixtureState) -> None:
        self.state = state
        super().__init__(address, BinanceFixtureHandler)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--state-file", required=True, type=Path)
    parser.add_argument("--scenario", choices=("success", "subscription", "timeout", "429", "5xx", "schema", "permission"), default="success")
    args = parser.parse_args()
    args.state_file.parent.mkdir(parents=True, exist_ok=True)
    state = FixtureState(args.state_file, args.scenario)
    server = BinanceFixtureServer((args.host, args.port), state)
    state.ready(server.server_port)

    def stop(_signum: int, _frame: Any) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    server.serve_forever(poll_interval=0.05)
    server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
