#!/usr/bin/env python3
import argparse
import select
import socket
import sys
import threading


def relay(left, right):
    sockets = [left, right]
    try:
        while True:
            readable, _, _ = select.select(sockets, [], [], 300)
            for source in readable:
                data = source.recv(65536)
                if not data:
                    return
                target = right if source is left else left
                target.sendall(data)
    finally:
        for item in sockets:
            try:
                item.close()
            except OSError:
                pass


def handle(client, target_host, target_port):
    try:
        upstream = socket.create_connection((target_host, target_port), timeout=10)
    except OSError as exc:
        print(f"upstream connect failed: {target_host}:{target_port}: {exc}", file=sys.stderr, flush=True)
        client.close()
        return

    relay(client, upstream)


def main():
    parser = argparse.ArgumentParser(description="TCP forwarder for local PostgreSQL access.")
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, default=15432)
    parser.add_argument("--target-host", default="192.168.88.10")
    parser.add_argument("--target-port", type=int, default=5432)
    args = parser.parse_args()

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.listen_host, args.listen_port))
    server.listen(128)

    print(
        f"forwarding {args.listen_host}:{args.listen_port} -> {args.target_host}:{args.target_port}",
        flush=True,
    )

    while True:
        client, _ = server.accept()
        thread = threading.Thread(
            target=handle,
            args=(client, args.target_host, args.target_port),
            daemon=True,
        )
        thread.start()


if __name__ == "__main__":
    main()
