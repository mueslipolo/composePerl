#!/usr/bin/env bats

# Tests for scripts/vm-check-compat.sh.
# perlbrew and rpm are mocked so the gate's pass/fail logic can be exercised
# without a real perlbrew install or a real RHEL host.

MOCKS_DIR="$BATS_TEST_DIRNAME/mocks/vm"
REAL_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/vm-check-compat.sh"

setup() {
  export PERLBREW_ROOT="$BATS_TEST_TMPDIR/perlbrew-root"
  mkdir -p "$PERLBREW_ROOT/bin"

  export PATH="$MOCKS_DIR:$PATH"
  touch "$BATS_TEST_TMPDIR/perlbrew.log" "$BATS_TEST_TMPDIR/rpm.log"
  unset MOCK_PERLBREW_LIST MOCK_RPM_RHEL

  BUILD_INFO="$BATS_TEST_TMPDIR/bundle-abc123.build-info"
}

write_build_info() {
  {
    echo "PERL_VERSION=${1:-5.28.1}"
    if [ -n "${2:-}" ]; then
      echo "UBI_IMAGE=${2}"
    fi
  } > "$BUILD_INFO"
}

run_script() {
  run "$REAL_SCRIPT" "$@"
}

@test "fails with usage message when no build-info file given" {
  run_script
  [ "$status" -eq 2 ]
}

@test "fails clearly when the build-info file doesn't exist" {
  run_script "$BATS_TEST_TMPDIR/does-not-exist.build-info"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "fails when the pinned perl version isn't installed" {
  write_build_info "5.28.1" "registry.access.redhat.com/ubi9/ubi-minimal:9.6"
  export MOCK_PERLBREW_LIST=""
  run_script "$BUILD_INFO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "passes when perl version and RHEL major both match" {
  write_build_info "5.28.1" "registry.access.redhat.com/ubi9/ubi-minimal:9.6"
  export MOCK_PERLBREW_LIST="perl-5.28.1"
  export MOCK_RPM_RHEL="9"
  run_script "$BUILD_INFO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"compatibility gate passed"* ]]
}

@test "fails when RHEL major doesn't match" {
  write_build_info "5.28.1" "registry.access.redhat.com/ubi9/ubi-minimal:9.6"
  export MOCK_PERLBREW_LIST="perl-5.28.1"
  export MOCK_RPM_RHEL="8"
  run_script "$BUILD_INFO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"RHEL 9"* ]]
  [[ "$output" == *"RHEL 8"* ]]
}

@test "skips the OS check and still passes when UBI_IMAGE is absent" {
  write_build_info "5.28.1" ""
  export MOCK_PERLBREW_LIST="perl-5.28.1"
  run_script "$BUILD_INFO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"compatibility gate passed"* ]]
}

@test "skips the OS check with a warning when rpm is unavailable" {
  write_build_info "5.28.1" "registry.access.redhat.com/ubi9/ubi-minimal:9.6"
  export MOCK_PERLBREW_LIST="perl-5.28.1"

  # Isolated mock dir with everything except rpm, so this test doesn't
  # mutate the shared mocks/vm directory other test files also rely on.
  no_rpm_mocks="$BATS_TEST_TMPDIR/mocks-no-rpm"
  mkdir -p "$no_rpm_mocks"
  for f in "$MOCKS_DIR"/*; do
    [ "$(basename "$f")" = "rpm" ] && continue
    ln -s "$f" "$no_rpm_mocks/$(basename "$f")"
  done
  PATH="$no_rpm_mocks:$(echo "$PATH" | sed "s#$MOCKS_DIR:##")"

  run_script "$BUILD_INFO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
}
