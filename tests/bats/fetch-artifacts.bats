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
}

run_script() {
  run "$PROJECT_DIR/scripts/fetch-artifacts.sh"
}

perl_version() {
  sed -n 's/^ARG PERL_VERSION=//p' "$PROJECT_DIR/Containerfile"
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
  [[ "$output" == *"pinned:   cpanm (trust-on-first-use, no independent source)"* ]]
  [[ "$output" == *"pinned:   cpm (trust-on-first-use, no independent source)"* ]]
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
