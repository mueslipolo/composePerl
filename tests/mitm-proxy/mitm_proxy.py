#!/usr/bin/env python3
"""Throwaway TLS-inspecting (MITM) forward proxy for verifying enterprise
proxy + custom CA support for real.

A plain CONNECT-tunnel proxy never touches the TLS bytes, so it can't prove
CA trust actually matters — this one does real TLS interception: it
terminates the client's TLS using a leaf cert signed by a throwaway test CA
(see generate-test-ca.sh), opens a REAL TLS connection to the actual
upstream host (verifying its real cert normally), and relays plaintext
between the two independently-encrypted legs. A client that doesn't trust
the test CA fails its handshake against this proxy's leaf cert; a client
with the CA installed succeeds and the real upstream content flows through
— the same shape as a real corporate TLS-inspecting proxy.

Used by the enterprise-proxy CI job to validate scripts/fetch-artifacts.sh,
the Containerfile's microdnf installs, and scripts/vm-bootstrap-perlbrew.sh
against a real interception scenario, not just a mocked one.

Usage: mitm_proxy.py <port> <leaf_cert> <leaf_key>
"""
import select
import socket
import ssl
import sys
import threading

def relay(a, b):
    # Single-threaded, select()-multiplexed relay between two already-
    # established TLS sockets. Deliberately NOT two threads doing concurrent
    # read+write on the same SSLSocket — that's not safe (observed as an
    # intermittent hang: TLS 1.3 post-handshake NewSessionTicket messages
    # racing against a writer thread on the same socket) — only one recv/
    # sendall executes at a time here, select() just picks which side has
    # data ready next.
    sockets = [a, b]
    try:
        while sockets:
            readable, _, exceptional = select.select(sockets, [], sockets, 30)
            if exceptional or not readable:
                break
            done = False
            for src in readable:
                dst = b if src is a else a
                # Drain fully: SSLSocket may have more decrypted bytes
                # buffered than select() knows about from the raw fd alone.
                while True:
                    try:
                        data = src.recv(65536)
                    except OSError:
                        data = b""
                    if not data:
                        done = True
                        break
                    try:
                        dst.sendall(data)
                    except OSError:
                        done = True
                        break
                    if not (hasattr(src, "pending") and src.pending()):
                        break
                if done:
                    break
            if done:
                break
    except OSError:
        pass

def handle(client_sock, leaf_cert, leaf_key):
    tls_client = None
    tls_upstream = None
    try:
        client_sock.settimeout(20)
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = client_sock.recv(4096)
            if not chunk:
                return
            request += chunk
        line = request.split(b"\r\n", 1)[0].decode()
        method, target, _ = line.split(" ")
        if method != "CONNECT":
            client_sock.sendall(b"HTTP/1.1 501 Not Implemented\r\n\r\n")
            return
        host, port = target.split(":")
        port = int(port)
        print(f"[mitm-proxy] CONNECT {host}:{port}", flush=True)
        client_sock.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")

        # Terminate the client's TLS with our CA-signed leaf cert. Pin ALPN to
        # http/1.1 on both legs — otherwise the upstream leg can silently
        # negotiate h2 while the client leg assumes http/1.1, and relaying
        # raw bytes between two different wire protocols just hangs.
        server_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server_ctx.load_cert_chain(certfile=leaf_cert, keyfile=leaf_key)
        server_ctx.set_alpn_protocols(["http/1.1"])
        tls_client = server_ctx.wrap_socket(client_sock, server_side=True)
        tls_client.settimeout(20)
        print(f"[mitm-proxy] TLS established with client for {host}", flush=True)

        # Real TLS connection to the actual upstream, verifying its real cert.
        upstream_raw = socket.create_connection((host, port), timeout=15)
        client_ctx = ssl.create_default_context()
        client_ctx.set_alpn_protocols(["http/1.1"])
        tls_upstream = client_ctx.wrap_socket(upstream_raw, server_hostname=host)
        tls_upstream.settimeout(20)
        print(f"[mitm-proxy] TLS established with upstream {host}", flush=True)

        relay(tls_client, tls_upstream)
        print(f"[mitm-proxy] done {host}:{port}", flush=True)
    except Exception as e:
        print(f"[mitm-proxy] ERROR: {e}", flush=True)
    finally:
        for s in (tls_client, tls_upstream, client_sock):
            try:
                if s is not None:
                    s.close()
            except OSError:
                pass

def main():
    if len(sys.argv) != 4:
        print("Usage: mitm_proxy.py <port> <leaf_cert> <leaf_key>", file=sys.stderr)
        sys.exit(2)
    port = int(sys.argv[1])
    leaf_cert = sys.argv[2]
    leaf_key = sys.argv[3]

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(20)
    print(f"[mitm-proxy] listening on 0.0.0.0:{port}", flush=True)
    while True:
        client_sock, _ = srv.accept()
        threading.Thread(target=handle, args=(client_sock, leaf_cert, leaf_key)).start()

if __name__ == "__main__":
    main()
