#!/usr/bin/env bats

# Tests for `deps.sh bundle-common` — the container path that builds the shared
# common BOM bundle. Like deps.bats, podman is mocked (tests/bats/mocks/podman),
# so this asserts the orchestration (carton-runner built for the common cpanfile,
# bundle extracted into bundles/common/, build-info stamped) without a real
# build. The resolution/gate logic itself is covered by the real-CPAN
# integration tests (multi-component-*.bats).

MOCKS_DIR="$BATS_TEST_DIRNAME/mocks"
REAL_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/deps.sh"
REAL_CONTAINERFILE="$BATS_TEST_DIRNAME/../../Containerfile"
REAL_CONTAINERFILE_DEPS="$BATS_TEST_DIRNAME/../../Containerfile.deps"

setup() {
  export PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT_DIR/scripts" "$PROJECT_DIR/common" "$PROJECT_DIR/bundles"

  cp "$REAL_SCRIPT"             "$PROJECT_DIR/scripts/deps.sh"
  cp "$REAL_CONTAINERFILE"      "$PROJECT_DIR/Containerfile"
  cp "$REAL_CONTAINERFILE_DEPS" "$PROJECT_DIR/Containerfile.deps"

  # a non-empty resolved common snapshot (so the hash is stable and the
  # "already exists" fast path isn't taken on the first run)
  cat > "$PROJECT_DIR/common/cpanfile" <<'EOF'
requires 'Try::Tiny';
EOF
  cat > "$PROJECT_DIR/common/cpanfile.snapshot" <<'EOF'
# carton snapshot format: version 1.0
DISTRIBUTIONS
  Try-Tiny-0.31
    pathname: E/ET/ETHER/Try-Tiny-0.31.tar.gz
EOF

  export PATH="$MOCKS_DIR:$PATH"
  touch "$BATS_TEST_TMPDIR/podman.log"
  unset UBI_IMAGE IMAGE_NAME
  unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
}

run_script() { run "$PROJECT_DIR/scripts/deps.sh" "$@"; }

@test "bundle-common builds the carton-runner with CPANFILE_DIR=common" {
  run_script bundle-common
  [ "$status" -eq 0 ]
  grep -q -- "--build-arg CPANFILE_DIR=common" "$BATS_TEST_TMPDIR/podman.log" \
    || ( echo "FAIL: CPANFILE_DIR=common not passed"; cat "$BATS_TEST_TMPDIR/podman.log"; false )
}

@test "bundle-common extracts the bundle into bundles/common/ with a hashed name" {
  run_script bundle-common
  [ "$status" -eq 0 ]
  hash=$(sha256sum "$PROJECT_DIR/common/cpanfile.snapshot" | cut -c1-12)
  [ -f "$PROJECT_DIR/bundles/common/bundle-${hash}.tar.gz" ]
  # extracted via podman cp from /build/cpan-bundle.tar.gz
  grep -q ":/build/cpan-bundle.tar.gz" "$BATS_TEST_TMPDIR/podman.log"
}

@test "bundle-common creates the latest symlink and stamps build-info" {
  run_script bundle-common
  [ "$status" -eq 0 ]
  [ -L "$PROJECT_DIR/bundles/common/bundle-latest.tar.gz" ]
  [ -f "$PROJECT_DIR/bundles/common/bundle-latest.build-info" ]
  grep -q '^PERL_VERSION=' "$PROJECT_DIR/bundles/common/bundle-latest.build-info"
}

@test "bundle-common is idempotent: existing bundle is reused, no rebuild" {
  run_script bundle-common
  [ "$status" -eq 0 ]
  : > "$BATS_TEST_TMPDIR/podman.log"   # clear the log
  run_script bundle-common
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  # no carton-runner build on the reuse path
  ! grep -q "podman build" "$BATS_TEST_TMPDIR/podman.log"
}

@test "bundle-common fails clearly when the common snapshot is missing" {
  rm -f "$PROJECT_DIR/common/cpanfile.snapshot"
  run_script bundle-common
  [ "$status" -ne 0 ]
  [[ "$output" == *"cpanfile.snapshot not found"* ]]
}
