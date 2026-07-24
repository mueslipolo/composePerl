#!/usr/bin/env bats

# Tests for scripts/bundle-common.sh — resolving + bundling the shared common
# set. Real Carton; skips when absent. Runs in BATS_TEST_TMPDIR (tmpfs) because
# the bundle-latest symlink needs a filesystem that permits symlinks.

SCRIPT="$BATS_TEST_DIRNAME/../../scripts/bundle-common.sh"
COMMON_FIXTURE="$BATS_TEST_DIRNAME/../../common/cpanfile"

setup() {
  command -v carton >/dev/null 2>&1 || skip "carton not installed (cpanm Carton)"
  CDIR="$BATS_TEST_TMPDIR/common"; BDIR="$BATS_TEST_TMPDIR/bundles"
  mkdir -p "$CDIR"
  cp "$COMMON_FIXTURE" "$CDIR/cpanfile"
}

@test "produces a hashed common bundle, build-info, and latest symlink" {
  run "$SCRIPT" "$CDIR" "$BDIR"
  [ "$status" -eq 0 ]
  # a content-addressed bundle exists
  run bash -c "ls '$BDIR/common/'bundle-*.tar.gz"
  [ "$status" -eq 0 ]
  # latest symlink resolves to it
  [ -L "$BDIR/common/bundle-latest.tar.gz" ]
  [ -f "$BDIR/common/bundle-latest.tar.gz" ]
  # build-info records the Perl version read from the Containerfile
  grep -q '^PERL_VERSION=' "$BDIR/common/bundle-latest.build-info"
}

@test "the common bundle carries cpanfile, snapshot, and vendor cache" {
  "$SCRIPT" "$CDIR" "$BDIR" >/dev/null
  run tar tzf "$BDIR/common/bundle-latest.tar.gz"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cpanfile"* ]]
  [[ "$output" == *"cpanfile.snapshot"* ]]
  [[ "$output" == *"vendor/cache/"* ]]
}

@test "the resolved common snapshot pins the expected distributions" {
  "$SCRIPT" "$CDIR" "$BDIR" >/dev/null
  run grep -E '^  [A-Za-z]' "$CDIR/cpanfile.snapshot"
  [[ "$output" == *"Try-Tiny-"* ]]
  [[ "$output" == *"Capture-Tiny-"* ]]
}
