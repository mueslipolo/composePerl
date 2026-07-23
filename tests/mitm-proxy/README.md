# Enterprise proxy + custom CA verification tooling

`mitm_proxy.py` is a throwaway TLS-inspecting (MITM) forward proxy used by
the `enterprise-proxy` and `vm-deployment` CI jobs to prove `VM_CA_CERT` /
`certs/` / `CURL_CA_BUNDLE` support actually works — not a mocked assertion.

A plain CONNECT-tunnel proxy (the kind `http_proxy`/`https_proxy` normally
point at) never touches the TLS bytes, so it can't prove custom CA trust
matters at all. This one actually terminates the client's TLS with a leaf
cert signed by a throwaway test CA, then opens a real TLS connection to the
genuine upstream host. A client that doesn't trust the test CA fails its
handshake against the leaf cert; a client with the CA installed succeeds and
real upstream content flows through — the same shape as a real corporate
TLS-inspecting proxy.

## Usage

```bash
# Generate a throwaway CA + leaf cert covering the hosts you'll intercept
tests/mitm-proxy/generate-test-ca.sh /tmp/test-ca install.perlbrew.pl raw.githubusercontent.com

# Start the proxy
python3 tests/mitm-proxy/mitm_proxy.py 8899 /tmp/test-ca/leaf.pem /tmp/test-ca/leaf.key &

# Point a client at it, trusting the CA
https_proxy=http://127.0.0.1:8899 curl --cacert /tmp/test-ca/test-ca.pem https://install.perlbrew.pl
```

Without `--cacert` (or the CA otherwise installed/trusted), the same
request fails with a TLS verification error — that's the point: it proves
the CA is load-bearing, not decorative.

## What uses this

- **`enterprise-proxy` CI job**: `scripts/fetch-artifacts.sh` (host-side
  curl) and the Containerfile's `perl-src` stage (`microdnf`, via
  `certs/` + `update-ca-trust`).
- **`vm-deployment` CI job**: `scripts/vm-bootstrap-perlbrew.sh` (perlbrew's
  own curl-based installer and Perl-source fetch, via `VM_CA_CERT`).

Each exercises both directions: a negative case (proxy set, CA *not*
trusted — must fail) and a positive case (CA trusted — must succeed and
real content must flow through), so the test can't pass by accident.

## Notes for future maintainers

- The relay is single-threaded per connection (`select()`-multiplexed), not
  two threads doing concurrent read/write on the same `SSLSocket` — that
  combination is not safe and was observed to hang intermittently (TLS 1.3
  post-handshake `NewSessionTicket` messages racing a writer thread on the
  same socket).
- ALPN is pinned to `http/1.1` on both legs. Without this, the upstream leg
  can silently negotiate HTTP/2 while the client leg assumes HTTP/1.1, and
  relaying raw bytes between two different wire protocols just hangs.
- Never commit generated certs/keys — regenerate them fresh per run.
