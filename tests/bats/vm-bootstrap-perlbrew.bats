#!/usr/bin/env bats

# Tests for scripts/vm-bootstrap-perlbrew.sh.
# perlbrew, curl, and update-ca-trust are mocked — real perlbrew/curl
# behavior against a real bundle is exercised for real in the vm-deployment
# CI job, not here.

MOCKS_DIR="$BATS_TEST_DIRNAME/mocks/vm"
REAL_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/vm-bootstrap-perlbrew.sh"

setup() {
  export PERLBREW_ROOT="$BATS_TEST_TMPDIR/perlbrew-root"
  mkdir -p "$PERLBREW_ROOT/bin"

  export PATH="$MOCKS_DIR:$PATH"
  touch "$BATS_TEST_TMPDIR/perlbrew.log" "$BATS_TEST_TMPDIR/curl.log" "$BATS_TEST_TMPDIR/update-ca-trust.log"
  unset VM_CA_CERT
  unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
  unset MOCK_PERLBREW_LIST
}

# perlbrew "already installed": stage the mock itself as the binary so the
# script's own -x check finds it and skips the curl bootstrap entirely.
stage_perlbrew_installed() {
  cp "$MOCKS_DIR/perlbrew" "$PERLBREW_ROOT/bin/perlbrew"
  chmod +x "$PERLBREW_ROOT/bin/perlbrew"
}

run_script() {
  run "$REAL_SCRIPT" "$@"
}

@test "fails with usage message when no perl version given" {
  run_script
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "installs perlbrew via curl when not already present" {
  run_script "5.28.1"
  [ "$status" -eq 0 ]
  grep -q "install.perlbrew.pl" "$BATS_TEST_TMPDIR/curl.log"
}

@test "skips curl bootstrap when perlbrew is already installed" {
  stage_perlbrew_installed
  export MOCK_PERLBREW_LIST="perl-5.28.1"
  run_script "5.28.1"
  [ "$status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/curl.log" ]
}

@test "skips perl install when the pinned version is already present" {
  stage_perlbrew_installed
  export MOCK_PERLBREW_LIST="perl-5.28.1"
  run_script "5.28.1"
  [ "$status" -eq 0 ]
  ! grep -q "^perlbrew.*install" "$BATS_TEST_TMPDIR/perlbrew.log"
}

@test "installs from a local tarball when given and perl is missing" {
  stage_perlbrew_installed
  export MOCK_PERLBREW_LIST=""
  local_tarball="$BATS_TEST_TMPDIR/perl-5.28.1.tar.gz"
  touch "$local_tarball"
  run_script "5.28.1" "$local_tarball"
  [ "$status" -eq 0 ]
  grep -qF -- "--notest install $local_tarball" "$BATS_TEST_TMPDIR/perlbrew.log"
}

@test "installs from network when no local tarball is given and perl is missing" {
  stage_perlbrew_installed
  export MOCK_PERLBREW_LIST=""
  run_script "5.28.1"
  [ "$status" -eq 0 ]
  grep -qF -- "--notest install 5.28.1" "$BATS_TEST_TMPDIR/perlbrew.log"
}

@test "installs a custom CA cert when VM_CA_CERT is set" {
  stage_perlbrew_installed
  export MOCK_PERLBREW_LIST="perl-5.28.1"
  cert="$BATS_TEST_TMPDIR/corp-ca.pem"
  echo "fake cert" > "$cert"
  export VM_CA_CERT="$cert"
  export VM_CA_TRUST_ANCHORS_DIR="$BATS_TEST_TMPDIR/ca-anchors"
  mkdir -p "$VM_CA_TRUST_ANCHORS_DIR"
  run_script "5.28.1"
  [ "$status" -eq 0 ]
  grep -q "update-ca-trust extract" "$BATS_TEST_TMPDIR/update-ca-trust.log"
  [ -f "$VM_CA_TRUST_ANCHORS_DIR/corp-ca.pem" ]
}

@test "skips CA install when VM_CA_CERT is unset" {
  stage_perlbrew_installed
  export MOCK_PERLBREW_LIST="perl-5.28.1"
  run_script "5.28.1"
  [ "$status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/update-ca-trust.log" ]
}

@test "fails clearly when VM_CA_CERT points to a missing file" {
  stage_perlbrew_installed
  export VM_CA_CERT="$BATS_TEST_TMPDIR/does-not-exist.pem"
  run_script "5.28.1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "folds uppercase HTTPS_PROXY into lowercase before the bootstrap curl call" {
  export HTTPS_PROXY="http://proxy.example:8080"
  run_script "5.28.1"
  [ "$status" -eq 0 ]
  grep -q "https_proxy=http://proxy.example:8080" "$BATS_TEST_TMPDIR/curl.log"
}

@test "reports no proxy configured when none is set" {
  run_script "5.28.1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No proxy configured"* ]]
}
