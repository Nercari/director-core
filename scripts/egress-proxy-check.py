#!/usr/bin/env python3
"""Behavior check for egress-proxy. Issue #31, under #27.

Prints every case and its verdict so the operator can watch the decisions
happen. It does not report that a suite passed.

What this proves, and what it deliberately does not:

  PROVES   the proxy allows the hostnames on its list, refuses every other
           CONNECT target, refuses a target whose name merely *contains* an
           allowed name, refuses a port it was not given, refuses anything that
           is not CONNECT, and passes bytes through untouched once it allows.
  DOES NOT the executor cannot go around it. That is a firewall property, not a
           proxy property, and no amount of testing this process can establish
           it. See docs/operator/egress-boundary.md.

It reaches no external network. Every allowed target here is a local socket, so
the check is the same on a machine with no internet as on one with it.
"""

from __future__ import annotations

import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROXY = ROOT / "scripts" / "egress-proxy.py"
ALLOWED_NAME = "allowed.test"
FAILURES: list[str] = []


def echo_server() -> tuple[int, threading.Thread]:
    """A local upstream, so an allowed CONNECT has something real to reach."""
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(8)
    port = listener.getsockname()[1]

    def serve() -> None:
        while True:
            try:
                conn, _ = listener.accept()
            except OSError:
                return
            with conn:
                while True:
                    data = conn.recv(4096)
                    if not data:
                        break
                    conn.sendall(data.upper())

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    return port, thread


def start_proxy(echo_port: int) -> tuple[subprocess.Popen, int]:
    process = subprocess.Popen(
        [
            sys.executable, str(PROXY),
            "--port", "0", "--print-port",
            "--allow", ALLOWED_NAME,
            # 127.0.0.1 stands in for the model API host: an allowed name whose
            # upstream actually answers, so the pass-through can be observed.
            "--allow", "127.0.0.1",
            "--allow-port", "443",
            "--allow-port", str(echo_port),
        ],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    line = process.stdout.readline().strip()
    if not line.isdigit():
        raise SystemExit(f"proxy did not report a port (got {line!r})")
    return process, int(line)


def speak(port: int, request: bytes, follow_up: bytes = b"") -> tuple[str, bytes]:
    """Send a raw request to the proxy; return its status line and any body."""
    with socket.create_connection(("127.0.0.1", port), 10) as sock:
        sock.settimeout(10)
        sock.sendall(request)
        try:
            head = sock.recv(4096)
        except socket.timeout:
            return "(no response)", b""
        status = head.split(b"\r\n", 1)[0].decode("latin-1", "replace")
        payload = b""
        if follow_up and b" 200 " in head:
            sock.sendall(follow_up)
            try:
                payload = sock.recv(4096)
            except socket.timeout:
                payload = b""
        return status, payload


def check(label: str, expected: str, port: int, request: bytes,
          follow_up: bytes = b"", expect_payload: bytes | None = None) -> None:
    status, payload = speak(port, request, follow_up)
    ok = expected in status
    if ok and expect_payload is not None:
        ok = payload == expect_payload
    first_line = request.split(b"\r\n")[0].decode("latin-1", "replace")
    print(f"=== {label}")
    print(f"  request : {first_line}")
    print(f"  status  : {status}   (expected to contain {expected!r})")
    if expect_payload is not None:
        print(f"  payload : {payload!r}   (expected {expect_payload!r})")
    print(f"  verdict : {'OK' if ok else 'WRONG'}\n")
    if not ok:
        FAILURES.append(label)


def connect(target: str) -> bytes:
    return f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n".encode()


def main() -> int:
    echo_port, _ = echo_server()
    process, port = start_proxy(echo_port)
    time.sleep(0.3)
    try:
        print("egress-proxy behavior check")
        print(f"allow list: {ALLOWED_NAME}, 127.0.0.1   allow ports: 443, {echo_port}\n")

        print("--- an allowed host is reachable, and bytes pass through untouched")
        check("allowed host, allowed port, tunnel carries data", "200", port,
              connect(f"127.0.0.1:{echo_port}"), b"ping", b"PING")

        print("--- every other CONNECT target is refused")
        check("the gate", "403", port, connect("github.com:443"))
        check("an unrelated host", "403", port, connect("example.com:443"))

        print("--- the allow list matches labels, never substrings")
        # The repository has already shipped one defect where an unanchored
        # match permitted what a literal comparison refused. Both directions of
        # that mistake are asserted here.
        check("allowed name as a suffix of another name", "403", port,
              connect(f"not{ALLOWED_NAME}:443"))
        check("allowed name as a prefix of a longer name", "403", port,
              connect(f"{ALLOWED_NAME}.evil.test:443"))
        check("a real subdomain of an allowed name is permitted by policy",
              # 502, not 403: policy allowed it and the upstream did not answer.
              # A proxy that reported the same code for both would make a network
              # outage indistinguishable from a policy refusal.
              "502", port, connect(f"sub.{ALLOWED_NAME}:443"))

        print("--- a port that was not granted is refused, on an allowed host")
        check("allowed host, ungranted port", "403", port, connect("127.0.0.1:22"))

        print("--- anything that is not CONNECT is refused")
        check("plain GET", "405", port,
              b"GET http://github.com/ HTTP/1.1\r\nHost: github.com\r\n\r\n")
        check("malformed target", "403", port, connect("no-port-here"))

        print("--- the case this check CANNOT decide")
        print("=== executor cannot bypass the proxy")
        print("  verdict : NOT TESTED HERE — a firewall property, not a proxy")
        print("            property, so this check can never decide it.")
        print("            DECIDED ELSEWHERE 2026-07-30, for TCP only:")
        print("            docs/evidence/egress-boundary-2026-07-30.md")
        print("            UDP/443 stays denied by rule and unmeasured.\n")
    finally:
        process.terminate()
        process.wait(timeout=10)

    if FAILURES:
        print(f"egress-proxy check FAILED: {len(FAILURES)} wrong verdict(s): "
              + ", ".join(FAILURES), file=sys.stderr)
        return 1
    print("egress-proxy check: every verdict as specified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
