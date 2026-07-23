#!/usr/bin/env bats

# Tests for scripts/vm-install-bundle.sh.
# perlbrew and cpm are mocked — real cpm behavior against a real bundle is
# exercised for real in the vm-deployment CI job, not here.

MOCKS_DIR="$BATS_TEST_DIRNAME/mocks/vm"
REAL_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/vm-install-bundle.sh"

setup() {
  export PERLBREW_ROOT="$BATS_TEST_TMPDIR/perlbrew-root"
  export PERLBREW_HOME="$BATS_TEST_TMPDIR/perlbrew-home"
  mkdir -p "$PERLBREW_ROOT/bin" "$PERLBREW_ROOT/etc"

  # perlbrew's real lib storage is governed by PERLBREW_HOME (default
  # ~/.perlbrew), a DIFFERENT variable from PERLBREW_ROOT — see
  # scripts/vm-install-bundle.sh's own comment on this. Simulate that here
  # so the test actually exercises the same PERL5LIB-derived path logic the
  # real script relies on, instead of leaking whatever PERL5LIB the test
  # runner's own ambient environment happens to have.
  cat > "$PERLBREW_ROOT/etc/bashrc" <<EOF
export PERL5LIB="${PERLBREW_HOME}/libs/\${PERLBREW_PERL}@\${PERLBREW_LIB}/lib/perl5"
EOF

  export PATH="$MOCKS_DIR:$PATH"
  touch "$BATS_TEST_TMPDIR/perlbrew.log" "$BATS_TEST_TMPDIR/cpm.log" "$BATS_TEST_TMPDIR/cpm-snapshot-check.log"
  unset MOCK_PERLBREW_LIB_LIST

  BUILD_INFO="$BATS_TEST_TMPDIR/bundle-abc123.build-info"
  echo "PERL_VERSION=5.28.1" > "$BUILD_INFO"

  # A real-shaped (if trivial) bundle tarball: cpanfile + cpanfile.snapshot
  # + vendor/cache, matching what `make bundle` actually produces.
  BUNDLE_SRC="$BATS_TEST_TMPDIR/bundle-src"
  mkdir -p "$BUNDLE_SRC/vendor/cache"
  echo 'requires "Try::Tiny";' > "$BUNDLE_SRC/cpanfile"
  echo "# snapshot" > "$BUNDLE_SRC/cpanfile.snapshot"
  BUNDLE_TARBALL="$BATS_TEST_TMPDIR/bundle-abc123.tar.gz"
  tar czf "$BUNDLE_TARBALL" -C "$BUNDLE_SRC" cpanfile cpanfile.snapshot vendor

  CPM_BIN="$BATS_TEST_TMPDIR/cpm-bin"
  cp "$MOCKS_DIR/cpm" "$CPM_BIN"
  chmod +x "$CPM_BIN"
}

run_script() {
  run "$REAL_SCRIPT" "$@"
}

@test "fails with usage message on wrong argument count" {
  run_script "$BUNDLE_TARBALL" "$BUILD_INFO"
  [ "$status" -eq 2 ]
}

@test "fails clearly when the bundle tarball doesn't exist" {
  run_script "$BATS_TEST_TMPDIR/no-such-bundle.tar.gz" "$BUILD_INFO" myapp "$CPM_BIN"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "creates the lib when it doesn't exist yet" {
  export MOCK_PERLBREW_LIB_LIST=""
  run_script "$BUNDLE_TARBALL" "$BUILD_INFO" myapp "$CPM_BIN"
  [ "$status" -eq 0 ]
  grep -qF "lib create perl-5.28.1@myapp" "$BATS_TEST_TMPDIR/perlbrew.log"
}

@test "does not recreate the lib when it already exists (idempotent)" {
  export MOCK_PERLBREW_LIB_LIST="perl-5.28.1@myapp"
  run_script "$BUNDLE_TARBALL" "$BUILD_INFO" myapp "$CPM_BIN"
  [ "$status" -eq 0 ]
  ! grep -qF "lib create" "$BATS_TEST_TMPDIR/perlbrew.log"
}

@test "uses the perl-prefixed lib path, not a bare version, for cpm -L" {
  export MOCK_PERLBREW_LIB_LIST="perl-5.28.1@myapp"
  run_script "$BUNDLE_TARBALL" "$BUILD_INFO" myapp "$CPM_BIN"
  [ "$status" -eq 0 ]
  grep -qF -- "-L $PERLBREW_HOME/libs/perl-5.28.1@myapp" "$BATS_TEST_TMPDIR/cpm.log"
}

@test "derives the lib path from PERL5LIB, not PERLBREW_ROOT" {
  # Regression guard: an earlier version of this script built the cpm -L
  # path from PERLBREW_ROOT and silently installed into a directory
  # perlbrew itself was not tracking (PERLBREW_ROOT != PERLBREW_HOME).
  export MOCK_PERLBREW_LIB_LIST="perl-5.28.1@myapp"
  run_script "$BUNDLE_TARBALL" "$BUILD_INFO" myapp "$CPM_BIN"
  [ "$status" -eq 0 ]
  ! grep -qF -- "-L $PERLBREW_ROOT/libs" "$BATS_TEST_TMPDIR/cpm.log"
}

@test "drops cpanfile.snapshot before invoking cpm" {
  export MOCK_PERLBREW_LIB_LIST="perl-5.28.1@myapp"
  run_script "$BUNDLE_TARBALL" "$BUILD_INFO" myapp "$CPM_BIN"
  [ "$status" -eq 0 ]
  grep -qF "SNAPSHOT_ABSENT" "$BATS_TEST_TMPDIR/cpm-snapshot-check.log"
}

@test "passes the offline 02packages resolver pointed at vendor/cache" {
  export MOCK_PERLBREW_LIB_LIST="perl-5.28.1@myapp"
  run_script "$BUNDLE_TARBALL" "$BUILD_INFO" myapp "$CPM_BIN"
  [ "$status" -eq 0 ]
  grep -qF -- "--resolver 02packages,file://" "$BATS_TEST_TMPDIR/cpm.log"
}
