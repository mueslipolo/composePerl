#!/usr/bin/env bats

# Tests for scripts/fetch-artifacts.sh — the lockfile-based rewrite (hashes
# live in artifacts.sha256, trust-on-first-use, hard error on divergence).
# curl is mocked (see mocks/fetch-artifacts/curl); the script runs against an
# isolated project dir so its REPO_ROOT resolves there, not the real repo.

MOCKS_DIR="$BATS_TEST_DIRNAME/mocks/fetch-artifacts"
REAL_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/fetch-artifacts.sh"
REAL_CONTAINERFILE="$BATS_TEST_DIRNAME/../../Containerfile"

setup() {
  export PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT_DIR/scripts"
  cp "$REAL_SCRIPT" "$PROJECT_DIR/scripts/fetch-artifacts.sh"
  chmod +x "$PROJECT_DIR/scripts/fetch-artifacts.sh"
  cp "$REAL_CONTAINERFILE" "$PROJECT_DIR/Containerfile"

  export PATH="$MOCKS_DIR:$PATH"
  export FETCH_MOCK_ARTIFACTS_DIR="$PROJECT_DIR/artifacts"
  touch "$BATS_TEST_TMPDIR/curl.log"
  unset FETCH_MOCK_BAD_PAYLOAD FETCH_MOCK_METACPAN_SHA256 FETCH_MOCK_CHECKSUMS_BODY
  unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
  unset NEXUS_URL NEXUS_REPOSITORY NEXUS_USER NEXUS_PASSWORD
}

run_script() {
  run "$PROJECT_DIR/scripts/fetch-artifacts.sh"
}

run_script_mirror() {
  run "$PROJECT_DIR/scripts/fetch-artifacts.sh" --mirror
}

perl_version() {
  sed -n 's/^ARG PERL_VERSION=//p' "$PROJECT_DIR/Containerfile"
}

cpanm_version() {
  sed -n 's/^CPANM_VERSION="\(.*\)"$/\1/p' "$PROJECT_DIR/scripts/fetch-artifacts.sh"
}

cpm_version() {
  sed -n 's/^CPM_VERSION="\(.*\)"$/\1/p' "$PROJECT_DIR/scripts/fetch-artifacts.sh"
}

# ── First-run pinning ─────────────────────────────────────────────────────────

@test "first run creates artifacts.sha256 and pins all five artifacts" {
  run_script
  [ "$status" -eq 0 ]

  lockfile="$PROJECT_DIR/artifacts.sha256"
  [ -f "$lockfile" ]

  pv="$(perl_version)"
  grep -qF "perl-${pv}.tar.gz" "$lockfile"
  grep -qF "cpanm" "$lockfile"
  grep -qF "cpm" "$lockfile"
  grep -q "instantclient-basiclite" "$lockfile"
  grep -q "instantclient-sdk" "$lockfile"
  [ "$(grep -c '^[0-9a-f]\{64\}  ' "$lockfile")" -eq 5 ]
}

@test "first run pins the Perl tarball only after an independent (MetaCPAN) check succeeds" {
  run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"Looking up published sha256 for perl-"*"on MetaCPAN"* ]]
  [[ "$output" == *"cross-checked against MetaCPAN"* ]]
}

@test "first run TOFU-pins cpanm/cpm/Oracle artifacts with no independent source" {
  run_script
  [ "$status" -eq 0 ]
  # cpanm/cpm are cached under a version-suffixed filename (cpanm-<version>,
  # with a stable `cpanm` symlink alongside) — unlike the Perl tarball and
  # Oracle zips, whose filenames already encode their version, a bare
  # `cpanm` would never change name across a CPANM_VERSION bump, and the
  # script's download() skips fetching whenever the destination already
  # exists. Read the versions dynamically so this test doesn't need
  # updating every time CPANM_VERSION/CPM_VERSION bump.
  [[ "$output" == *"pinned:   cpanm-$(cpanm_version) (trust-on-first-use, no independent source)"* ]]
  [[ "$output" == *"pinned:   cpm-$(cpm_version) (trust-on-first-use, no independent source)"* ]]
  [ -L "$PROJECT_DIR/artifacts/cpanm" ]
  [ -L "$PROJECT_DIR/artifacts/cpm" ]
  [ "$(readlink "$PROJECT_DIR/artifacts/cpanm")" = "cpanm-$(cpanm_version)" ]
  [ "$(readlink "$PROJECT_DIR/artifacts/cpm")" = "cpm-$(cpm_version)" ]
}

@test "bumping CPANM_VERSION and re-running fetches the new version instead of reusing the old cache" {
  # Regression test: cpanm/cpm are the one artifact type whose filename
  # doesn't already encode its version, so a naive `download()` (skip if the
  # destination exists) would silently keep serving the old binary forever
  # after a version bump. The version-suffixed filename fixes this — this
  # test proves it empirically rather than by inspection.
  run_script
  [ "$status" -eq 0 ]
  old_version="$(cpanm_version)"
  [ -f "$PROJECT_DIR/artifacts/cpanm-${old_version}" ]

  sed -i "s/^CPANM_VERSION=\"${old_version}\"/CPANM_VERSION=\"9.9999\"/" \
    "$PROJECT_DIR/scripts/fetch-artifacts.sh"

  run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fetching cpanm-9.9999"* ]]
  [ -f "$PROJECT_DIR/artifacts/cpanm-9.9999" ]
  # Old version's file is untouched, not deleted — same "accumulate" pattern
  # bundles/ and versioned Perl tarballs already use elsewhere in this repo.
  [ -f "$PROJECT_DIR/artifacts/cpanm-${old_version}" ]
  # The stable name now points at the NEW version, not the old one.
  [ "$(readlink "$PROJECT_DIR/artifacts/cpanm")" = "cpanm-9.9999" ]
}

# ── Idempotence ────────────────────────────────────────────────────────────────

@test "second run re-verifies against the lockfile and makes no network calls" {
  run_script
  first_status=$status
  [ "$first_status" -eq 0 ]

  : > "$BATS_TEST_TMPDIR/curl.log"   # reset call log, then run again
  run_script
  second_status=$status
  second_output="$output"

  [ "$second_status" -eq 0 ]
  [[ "$second_output" == *"verified: cpanm"* ]]
  [[ "$second_output" != *"Fetching"* ]]
  [ ! -s "$BATS_TEST_TMPDIR/curl.log" ]
}

# ── Pinned-mismatch enforcement (the core new security property) ─────────────

@test "fails hard when an already-pinned artifact's on-disk content no longer matches" {
  run_script
  [ "$status" -eq 0 ]

  # Corrupt a file the lockfile already trusts, without touching the lockfile.
  echo "tampered" > "$PROJECT_DIR/artifacts/cpanm"

  run_script
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR: sha256 mismatch for cpanm"* ]]
  [[ "$output" == *"delete the cpanm"*"line from artifacts.sha256"* ]]
}

# ── Independent-source disagreement (tampered/wrong download) ────────────────

@test "refuses to pin the Perl tarball when its hash disagrees with MetaCPAN" {
  # Must be exactly 64 hex chars — the script's own regex requires it, and a
  # short/long literal would silently fall through to the wrong error path.
  export FETCH_MOCK_METACPAN_SHA256="$(printf 'f%.0s' $(seq 1 64))"
  run_script
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match its published checksum"* ]]
  [[ "$output" == *"Refusing to pin"* ]]
  # Must not have pinned a bad hash on the way down.
  ! grep -qF "perl-$(perl_version).tar.gz" "$PROJECT_DIR/artifacts.sha256"
}

@test "surfaces an error and does not pin when MetaCPAN and CHECKSUMS both fail" {
  export FETCH_MOCK_ARTIFACTS_DIR="/nonexistent"   # forces the mock's MetaCPAN branch to fail
  run_script
  [ "$status" -ne 0 ]
  [[ "$output" == *"MetaCPAN lookup failed"* ]]
  [[ "$output" == *"could not obtain sha256"* ]]
}

# ── Proxy normalization ────────────────────────────────────────────────────────

@test "reports configured proxy and reaches curl when https_proxy is set" {
  export https_proxy="http://proxy.corp.example:8080"
  run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"Proxy: https_proxy=http://proxy.corp.example:8080"* ]]
  # Confirms the env var reached the actual curl invocation, not just the
  # script's own echo.
  grep -q "https_proxy=http://proxy.corp.example:8080" "$BATS_TEST_TMPDIR/curl.log"
}

@test "reports no proxy configured when unset" {
  run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"No proxy configured"* ]]
}

@test "folds uppercase HTTPS_PROXY/NO_PROXY in when lowercase is unset" {
  export HTTPS_PROXY="http://proxy.corp.example:8080"
  export NO_PROXY="localhost,127.0.0.1"
  run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"https_proxy=http://proxy.corp.example:8080"* ]]
  grep -q "https_proxy=http://proxy.corp.example:8080 no_proxy=localhost,127.0.0.1" "$BATS_TEST_TMPDIR/curl.log"
}

# ── Network/TLS failure diagnostics ───────────────────────────────────────────

@test "shows a proxy/CA hint when a download fails with a curl network exit code" {
  export FETCH_MOCK_DOWNLOAD_EXIT_CODE=60   # SSL cert problem
  run_script
  [ "$status" -ne 0 ]
  [[ "$output" == *"Network/TLS error (exit 60)"* ]]
  [[ "$output" == *"http_proxy / https_proxy / no_proxy"* ]]
  [[ "$output" == *"docs/proxy.md"* ]]
}

@test "shows the hint for a connection-refused style failure too" {
  export FETCH_MOCK_DOWNLOAD_EXIT_CODE=7   # couldn't connect
  run_script
  [ "$status" -ne 0 ]
  [[ "$output" == *"Network/TLS error (exit 7)"* ]]
}

@test "does not show the proxy/CA hint for an unrelated failure (hash mismatch)" {
  run_script
  [ "$status" -eq 0 ]
  echo "tampered" > "$PROJECT_DIR/artifacts/cpanm"
  run_script
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR: sha256 mismatch for cpanm"* ]]
  [[ "$output" != *"Network/TLS error"* ]]
}

# ── Nexus fetch redirect ──────────────────────────────────────────────────────

@test "fetches from Nexus instead of the public internet when NEXUS_URL is set" {
  export NEXUS_URL="https://nexus.example.org"
  run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"NEXUS_URL set: fetching artifacts from Nexus"* ]]

  log="$BATS_TEST_TMPDIR/curl.log"
  pv="$(perl_version)"
  cv="$(cpanm_version)"

  grep -qF "https://nexus.example.org/repository/raw-hosted/composeperl/perl-${pv}.tar.gz" "$log"
  grep -qF "https://nexus.example.org/repository/raw-hosted/composeperl/cpanm-${cv}" "$log"
  ! grep -qF "www.cpan.org" "$log"
  ! grep -qF "raw.githubusercontent.com" "$log"
  ! grep -qF "download.oracle.com" "$log"
}

@test "NEXUS_REPOSITORY overrides the default 'raw-hosted' repo name" {
  export NEXUS_URL="https://nexus.example.org"
  export NEXUS_REPOSITORY="perl-mirror"
  run_script
  [ "$status" -eq 0 ]
  grep -qF "https://nexus.example.org/repository/perl-mirror/composeperl/" "$BATS_TEST_TMPDIR/curl.log"
}

# ── --mirror (fetch from the internet, upload into Nexus) ────────────────────

@test "--mirror uses public URLs even when NEXUS_URL is set, and uploads all 5 artifacts" {
  export NEXUS_URL="https://nexus.example.org"
  export NEXUS_USER="svc-mirror"
  export NEXUS_PASSWORD="secret"
  run_script_mirror
  [ "$status" -eq 0 ]

  log="$BATS_TEST_TMPDIR/curl.log"
  # Downloads still hit the real public sources...
  grep -qF "www.cpan.org" "$log"
  grep -qF "raw.githubusercontent.com" "$log"
  grep -qF "download.oracle.com" "$log"

  # ...and every artifact is then uploaded to Nexus.
  pv="$(perl_version)"
  cv="$(cpanm_version)"
  cmv="$(cpm_version)"
  [ "$(grep -c -- '--upload-file' "$log")" -eq 5 ]
  grep -qF -- "--upload-file $PROJECT_DIR/artifacts/perl-${pv}.tar.gz https://nexus.example.org/repository/raw-hosted/composeperl/perl-${pv}.tar.gz" "$log"
  grep -qF -- "--upload-file $PROJECT_DIR/artifacts/cpanm-${cv} https://nexus.example.org/repository/raw-hosted/composeperl/cpanm-${cv}" "$log"
  grep -qF -- "--upload-file $PROJECT_DIR/artifacts/cpm-${cmv} https://nexus.example.org/repository/raw-hosted/composeperl/cpm-${cmv}" "$log"

  # Credentials are routed through a curl config file, never as `-u` on the
  # command line. The uploads only succeed (status 0, 5x --upload-file above)
  # because the mock read a valid user:pass out of that --config file — so
  # pass-through is proven — while the secret must NOT appear in the logged argv.
  grep -qF -- "--config " "$log"
  ! grep -qF -- "-u svc-mirror:secret" "$log"
  ! grep -qF -- "secret" "$log"
}

@test "--mirror fails clearly when Nexus credentials are missing, before any upload" {
  export NEXUS_URL="https://nexus.example.org"
  run_script_mirror
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"NEXUS_URL, NEXUS_USER, and NEXUS_PASSWORD"* ]]
  [ ! -s "$BATS_TEST_TMPDIR/curl.log" ]
}

@test "--mirror fails clearly when NEXUS_URL is unset" {
  run_script_mirror
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"NEXUS_URL, NEXUS_USER, and NEXUS_PASSWORD"* ]]
}

@test "rejects an unrecognized argument" {
  run "$PROJECT_DIR/scripts/fetch-artifacts.sh" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}
