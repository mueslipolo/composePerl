#!/usr/bin/env bats

# Tests for scripts/bundle-component.sh — resolving + gating + bundling a
# component against the shared common BOM. Real Carton; skips when absent.
# Runs in BATS_TEST_TMPDIR (tmpfs) so the bundle-latest symlink works.
# Fixtures: tests/multi-component/{common,alpha,beta,gamma}.

FIXTURES="$BATS_TEST_DIRNAME/../multi-component"
SCRIPT="$BATS_TEST_DIRNAME/../../scripts/bundle-component.sh"

setup_file() {
  command -v carton >/dev/null 2>&1 || return 0
  COMMON_DIR="${BATS_FILE_TMPDIR}/common"
  mkdir -p "$COMMON_DIR"
  cp "$FIXTURES/common/cpanfile" "$COMMON_DIR/cpanfile"
  ( cd "$COMMON_DIR" && carton install >/dev/null 2>&1 )
  export COMMON_DIR
}

setup() {
  command -v carton >/dev/null 2>&1 || skip "carton not installed (cpanm Carton)"
  BDIR="${BATS_TEST_TMPDIR}/bundles"
}

@test "alpha: produces a component bundle with delta.txt inside" {
  run "$SCRIPT" "$COMMON_DIR" "$FIXTURES/alpha" "$BDIR"
  [ "$status" -eq 0 ]
  [ -L "$BDIR/alpha/bundle-latest.tar.gz" ]
  [ -f "$BDIR/alpha/bundle-latest.build-info" ]
  # the bundle carries cpanfile, resolved snapshot, vendor cache, and delta.txt
  run tar tzf "$BDIR/alpha/bundle-latest.tar.gz"
  [[ "$output" == *"cpanfile"* ]]
  [[ "$output" == *"cpanfile.snapshot"* ]]
  [[ "$output" == *"vendor/cache/"* ]]
  [[ "$output" == *"delta.txt"* ]]
}

@test "alpha: delta.txt lists the new dist and excludes common's" {
  "$SCRIPT" "$COMMON_DIR" "$FIXTURES/alpha" "$BDIR" >/dev/null
  d="${BATS_TEST_TMPDIR}/extract"; mkdir -p "$d"
  tar xzf "$BDIR/alpha/bundle-latest.tar.gz" -C "$d" delta.txt
  grep -q '^Test-Fatal ' "$d/delta.txt"
  ! grep -qE '^(Try-Tiny|Capture-Tiny) ' "$d/delta.txt"
}

@test "beta: empty delta still produces a valid bundle" {
  run "$SCRIPT" "$COMMON_DIR" "$FIXTURES/beta" "$BDIR"
  [ "$status" -eq 0 ]
  [ -f "$BDIR/beta/bundle-latest.tar.gz" ]
  d="${BATS_TEST_TMPDIR}/beta-extract"; mkdir -p "$d"
  tar xzf "$BDIR/beta/bundle-latest.tar.gz" -C "$d" delta.txt
  [ ! -s "$d/delta.txt" ]
}

@test "gamma: BOM conflict fails the bundle build, no bundle written" {
  run "$SCRIPT" "$COMMON_DIR" "$FIXTURES/gamma" "$BDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"conflict"* ]] || [[ "$output" == *"CONFLICT"* ]]
  [ ! -e "$BDIR/gamma/bundle-latest.tar.gz" ]
}

@test "requires both common-dir and component-dir" {
  run "$SCRIPT" "$COMMON_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}
