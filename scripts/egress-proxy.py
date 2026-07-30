#!/usr/bin/env python3
"""egress-proxy — the only route out of the restricted account.

Issue #31, under #27. Blueprint §21.8, §21.9.

Allows CONNECT to an explicit list of hostnames and refuses every other target.
Nothing is allowed by IP address, and that is the entire point:

  * The gate and the model API sit behind shared CDN infrastructure. An address
    that reaches the model API can reach the gate, so permitting by address
    permits the gate. The recorded plan this replaces proposed exactly that.
  * Those addresses churn. One observed lookup returned eight rotating IPv4
    addresses in a shared range. An address allow list is an outage waiting for
    a DNS change.

Filtering on the CONNECT target sidesteps both. The client names the host it
wants before any bytes flow, and that name is what gets checked.

WHAT THIS IS NOT. A proxy is not a boundary. Setting proxy environment
variables only routes a *cooperative* process; an executor that ignores them
reaches the network directly. The firewall rule that denies outbound for the
account is what makes this proxy the only available path, and that rule is an
operator task — see docs/operator/egress-boundary.md. Until it is applied and
probed, this process is a filter that a client may opt out of, and the registry
must not describe it as a control.

TLS is not terminated. This forwards bytes after CONNECT, so certificate
validation stays end to end between the executor and the model API. It follows
that content inside the tunnel is not inspected: this stops the executor
reaching a forbidden *host*, not the executor placing repository content in a
prompt to a permitted one. That residual is stated in the registry, not omitted.

Usage:
    python scripts/egress-proxy.py [--port 8899] [--allow HOST]... [--log FILE]

Defaults come from DIRECTOR_MODEL_HOST when set, so the probe and the proxy
cannot disagree about which host is supposed to work.
"""

from __future__ import annotations

import argparse
import os
import select
import socket
import socketserver
import sys
import threading

DEFAULT_PORT = 8899
# Only the model API. The gate is absent on purpose and adding it would defeat
# the unit: the executor must not be able to push, open a pull request, or merge.
DEFAULT_ALLOW = [os.environ.get("DIRECTOR_MODEL_HOST", "generativelanguage.googleapis.com")]
CONNECT_TIMEOUT = 15
IDLE_TIMEOUT = 300


def host_allowed(host: str, allowed: set[str]) -> bool:
    """Exact match, or a subdomain of an allowed name.

    Matching is on labels, never on substrings. `notgoogleapis.com` must not
    match `googleapis.com`, and an attacker-registered
    `generativelanguage.googleapis.com.evil.test` must not match either. The
    repository has already shipped one defect where an unanchored match let
    through what a literal comparison would have refused; this is the same
    mistake's shape.
    """
    host = host.strip().rstrip(".").lower()
    if not host:
        return False
    for name in allowed:
        if host == name or host.endswith("." + name):
            return True
    return False


class Handler(socketserver.StreamRequestHandler):
    timeout = CONNECT_TIMEOUT

    def log(self, verdict: str, target: str, detail: str = "") -> None:
        line = f"{verdict:7s} {target}"
        if detail:
            line += f"  {detail}"
        print(line, file=self.server.logfile, flush=True)

    def refuse(self, target: str, reason: str, code: str = "403 Forbidden") -> None:
        self.log("DENY", target, reason)
        self.wfile.write(f"HTTP/1.1 {code}\r\nContent-Length: 0\r\n\r\n".encode())

    def handle(self) -> None:
        try:
            request = self.rfile.readline(65536).decode("latin-1").strip()
        except (OSError, UnicodeDecodeError):
            return
        if not request:
            return

        parts = request.split()
        # Only CONNECT. A plain GET through here would be a second, unfiltered
        # code path, and every path that can reach the network must be checked.
        if len(parts) < 3 or parts[0].upper() != "CONNECT":
            self.refuse(request[:120], "only CONNECT is served", "405 Method Not Allowed")
            return

        target = parts[1]
        host, _, port_text = target.rpartition(":")
        if not host or not port_text.isdigit():
            self.refuse(target, "malformed CONNECT target")
            return
        port = int(port_text)

        # Drain the request headers so the client is not left mid-request.
        while True:
            try:
                line = self.rfile.readline(65536)
            except OSError:
                return
            if not line or line in (b"\r\n", b"\n"):
                break

        if port not in self.server.allowed_ports:
            self.refuse(target, f"port {port} not permitted")
            return
        if not host_allowed(host, self.server.allowed_hosts):
            self.refuse(target, "host not on the allow list")
            return

        try:
            upstream = socket.create_connection((host, port), CONNECT_TIMEOUT)
        except OSError as error:
            # A refusal here is the upstream's, not this proxy's. Saying which
            # keeps a network failure from being read as a policy decision.
            self.log("UPSTREAM", target, f"connect failed: {error}")
            self.wfile.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            return

        self.log("ALLOW", target)
        self.wfile.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
        try:
            self.pump(self.connection, upstream)
        finally:
            upstream.close()

    @staticmethod
    def pump(client: socket.socket, upstream: socket.socket) -> None:
        """Forward bytes both ways until either side closes. No inspection."""
        sockets = [client, upstream]
        while True:
            try:
                readable, _, errored = select.select(sockets, [], sockets, IDLE_TIMEOUT)
            except (OSError, ValueError):
                return
            if errored or not readable:
                return
            for source in readable:
                target = upstream if source is client else client
                try:
                    chunk = source.recv(65536)
                except OSError:
                    return
                if not chunk:
                    return
                try:
                    target.sendall(chunk)
                except OSError:
                    return


class Proxy(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, allowed_hosts, allowed_ports, logfile):
        self.allowed_hosts = allowed_hosts
        self.allowed_ports = allowed_ports
        self.logfile = logfile
        super().__init__(address, Handler)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--allow", action="append", default=None, metavar="HOST")
    parser.add_argument("--allow-port", action="append", type=int, default=None)
    parser.add_argument("--log", default=None, help="append the decision log here")
    # Loopback only. Binding a wider interface would offer this hole to the
    # whole network, and the proxy exists to remove a hole.
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--print-port", action="store_true",
                        help="print the bound port and flush, for a caller that passed --port 0")
    args = parser.parse_args()

    allowed_hosts = {h.strip().rstrip(".").lower() for h in (args.allow or DEFAULT_ALLOW) if h.strip()}
    if not allowed_hosts:
        print("refusing to run with an empty allow list", file=sys.stderr)
        return 2
    allowed_ports = set(args.allow_port or [443])

    logfile = open(args.log, "a", encoding="utf-8") if args.log else sys.stderr

    with Proxy((args.bind, args.port), allowed_hosts, allowed_ports, logfile) as proxy:
        bound = proxy.server_address[1]
        print(f"egress-proxy listening on {args.bind}:{bound}", file=logfile, flush=True)
        print(f"allow hosts: {' '.join(sorted(allowed_hosts))}", file=logfile, flush=True)
        print(f"allow ports: {' '.join(str(p) for p in sorted(allowed_ports))}", file=logfile, flush=True)
        if args.print_port:
            print(bound, flush=True)
        thread = threading.Thread(target=proxy.serve_forever, daemon=True)
        thread.start()
        try:
            thread.join()
        except KeyboardInterrupt:
            proxy.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
