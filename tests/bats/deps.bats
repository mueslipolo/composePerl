#!/usr/bin/env bats

# Tests for scripts/deps.sh.
# All tests run without real containers — podman is mocked via tests/bats/mocks/podman.
# The script is copied into an isolated temp project dir so its PROJECT_ROOT resolves
# to that dir, keeping test side-effects away from the real repo.

MOCKS_DIR="$BATS_TEST_DIRNAME/mocks"
REAL_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/deps.sh"
REAL_CONTAINERFILE="$BATS_TEST_DIRNAME/../../Containerfile"
REAL_CONTAINERFILE_DEPS="$BATS_TEST_DIRNAME/../../Containerfile.deps"

setup() {
  export PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT_DIR/scripts" "$PROJECT_DIR/bundles"

  cp "$REAL_SCRIPT"           "$PROJECT_DIR/scripts/deps.sh"
  cp "$REAL_CONTAINERFILE"    "$PROJECT_DIR/Containerfile"
  cp "$REAL_CONTAINERFILE_DEPS" "$PROJECT_DIR/Containerfile.deps"

  echo "requires 'DBI';" > "$PROJECT_DIR/cpanfile"
  echo "# snapshot"      > "$PROJECT_DIR/cpanfile.snapshot"

  export PATH="$MOCKS_DIR:$PATH"
  touch "$BATS_TEST_TMPDIR/podman.log"
  unset UBI_IMAGE
  unset IMAGE_NAME
  unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
}

run_script() {
  run "$PROJECT_DIR/scripts/deps.sh" "$@"
}

# ── Regression: MR1 bug ────────────────────────────────────────────────────────

@test "cmd_update --module uses carton update, not carton install (MR1 regression)" {
  run_script update --module DBI
  [ "$status" -eq 0 ]
  grep -q "carton update DBI" "$BATS_TEST_TMPDIR/podman.log" \
    || ( echo "FAIL: 'carton update DBI' not found in podman.log"; cat "$BATS_TEST_TMPDIR/podman.log"; false )
  if grep -q "carton install DBI" "$BATS_TEST_TMPDIR/podman.log"; then
    echo "REGRESSION (MR1): cmd_update --module used 'carton install' instead of 'carton update'"
    false
  fi
}

# ── Regression: MR2 bug (exec) ────────────────────────────────────────────────

@test "cmd_update exec runs in /build not /app (MR2 regression)" {
  run_script update --module DBI
  [ "$status" -eq 0 ]
  grep -q "cd /build" "$BATS_TEST_TMPDIR/podman.log" \
    || ( echo "FAIL: 'cd /build' not found in podman.log"; cat "$BATS_TEST_TMPDIR/podman.log"; false )
  if grep -q "cd /app" "$BATS_TEST_TMPDIR/podman.log"; then
    echo "REGRESSION (MR2): cmd_update exec used 'cd /app' instead of 'cd /build'"
    false
  fi
}

# ── Regression: MR2 bug (cp) ──────────────────────────────────────────────────

@test "cmd_update cp pulls from /build/cpanfile.snapshot not /app (MR2 regression)" {
  run_script update --module DBI
  [ "$status" -eq 0 ]
  grep -q ":/build/cpanfile.snapshot" "$BATS_TEST_TMPDIR/podman.log" \
    || ( echo "FAIL: ':/build/cpanfile.snapshot' not found in podman.log"; cat "$BATS_TEST_TMPDIR/podman.log"; false )
  if grep -q ":/app/cpanfile.snapshot" "$BATS_TEST_TMPDIR/podman.log"; then
    echo "REGRESSION (MR2): cmd_update cp used ':/app/cpanfile.snapshot'"
    false
  fi
}

# ── Contract: Containerfile WORKDIR vs script path ────────────────────────────

@test "deps.sh workdir matches Containerfile.deps WORKDIR" {
  cf_workdir=$(awk '/^WORKDIR/{print $2; exit}' "$REAL_CONTAINERFILE_DEPS")
  script_path=$(grep -oE "cd /[a-zA-Z0-9_-]+" "$REAL_SCRIPT" | head -1 | sed 's/cd //')

  [ -n "$cf_workdir" ] \
    || ( echo "FAIL: Could not extract WORKDIR from Containerfile.deps"; false )
  [ -n "$script_path" ] \
    || ( echo "FAIL: Could not extract 'cd /...' path from deps.sh"; false )
  [ "$cf_workdir" = "$script_path" ] \
    || ( echo "DRIFT: Containerfile.deps WORKDIR='$cf_workdir' != deps.sh cd path='$script_path'"; false )
}

# ── Argument parsing ──────────────────────────────────────────────────────────

@test "cmd_update --all succeeds and uses carton update with no module" {
  run_script update --all
  [ "$status" -eq 0 ]
  grep -q "carton update" "$BATS_TEST_TMPDIR/podman.log"
  ! grep -q "carton update DBI" "$BATS_TEST_TMPDIR/podman.log"
}

@test "cmd_update --module MODULE succeeds" {
  run_script update --module DBI
  [ "$status" -eq 0 ]
}

@test "cmd_update --module accepts multiple modules and updates only those" {
  run_script update --module DBI Try::Tiny JSON::XS
  [ "$status" -eq 0 ]
  grep -q "carton update DBI Try::Tiny JSON::XS" "$BATS_TEST_TMPDIR/podman.log"
}

@test "cmd_update with --all and --module together fails" {
  run_script update --all --module DBI
  [ "$status" -ne 0 ]
}

@test "cmd_update with no flags fails" {
  run_script update
  [ "$status" -ne 0 ]
}

@test "unknown top-level command fails" {
  run_script frobnicate
  [ "$status" -ne 0 ]
}

# ── Precondition checks ───────────────────────────────────────────────────────

@test "cmd_update fails before any podman call when cpanfile is missing" {
  rm "$PROJECT_DIR/cpanfile"
  run_script update --module DBI
  [ "$status" -ne 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/podman.log" ]
}

@test "cmd_bundle fails before any podman call when cpanfile.snapshot is missing" {
  rm "$PROJECT_DIR/cpanfile.snapshot"
  run_script bundle
  [ "$status" -ne 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/podman.log" ]
}

# ── Bundle hash ───────────────────────────────────────────────────────────────

@test "cmd_bundle names bundle with cpanfile.snapshot hash" {
  printf "deterministic-content\n" > "$PROJECT_DIR/cpanfile.snapshot"
  expected_hash=$(sha256sum "$PROJECT_DIR/cpanfile.snapshot" | cut -c1-12)

  run_script bundle
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_DIR/bundles/bundle-${expected_hash}.tar.gz" ]
}

# ── Existing-bundle skip ──────────────────────────────────────────────────────

@test "cmd_bundle skips podman build when bundle already exists" {
  printf "deterministic-content\n" > "$PROJECT_DIR/cpanfile.snapshot"
  expected_hash=$(sha256sum "$PROJECT_DIR/cpanfile.snapshot" | cut -c1-12)
  touch "$PROJECT_DIR/bundles/bundle-${expected_hash}.tar.gz"

  run_script bundle
  [ "$status" -eq 0 ]
  ! grep -q "^podman build" "$BATS_TEST_TMPDIR/podman.log"
}

# ── Symlink ───────────────────────────────────────────────────────────────────

@test "cmd_bundle creates bundle-latest symlink pointing to new bundle" {
  printf "deterministic-content\n" > "$PROJECT_DIR/cpanfile.snapshot"
  expected_hash=$(sha256sum "$PROJECT_DIR/cpanfile.snapshot" | cut -c1-12)

  run_script bundle
  [ "$status" -eq 0 ]
  [ -L "$PROJECT_DIR/bundles/bundle-latest.tar.gz" ]
  link_target=$(readlink "$PROJECT_DIR/bundles/bundle-latest.tar.gz")
  [ "$link_target" = "bundle-${expected_hash}.tar.gz" ]
}

# ── UBI_IMAGE override ────────────────────────────────────────────────────────

@test "build_carton_runner passes --build-arg UBI_IMAGE when UBI_IMAGE is set" {
  export UBI_IMAGE="registry.access.redhat.com/ubi8/ubi-minimal:8.10"
  run_script update --module DBI
  [ "$status" -eq 0 ]
  grep -q -- "--build-arg UBI_IMAGE=registry.access.redhat.com/ubi8/ubi-minimal:8.10" \
    "$BATS_TEST_TMPDIR/podman.log"
}

@test "build_carton_runner omits --build-arg UBI_IMAGE when UBI_IMAGE is not set" {
  run_script update --module DBI
  [ "$status" -eq 0 ]
  ! grep -q -- "--build-arg UBI_IMAGE" "$BATS_TEST_TMPDIR/podman.log"
}

# ── Build-info stamp (Perl version + OS pairing) ──────────────────────────────

@test "cmd_bundle stamps build-info with PERL_VERSION and UBI_IMAGE from Containerfile" {
  printf "deterministic-content\n" > "$PROJECT_DIR/cpanfile.snapshot"
  expected_hash=$(sha256sum "$PROJECT_DIR/cpanfile.snapshot" | cut -c1-12)
  expected_perl=$(sed -n 's/^ARG PERL_VERSION=//p' "$PROJECT_DIR/Containerfile")
  expected_ubi=$(sed -n 's/^ARG UBI_IMAGE=//p' "$PROJECT_DIR/Containerfile")

  run_script bundle
  [ "$status" -eq 0 ]

  build_info="$PROJECT_DIR/bundles/bundle-${expected_hash}.build-info"
  [ -f "$build_info" ]
  grep -qF "PERL_VERSION=${expected_perl}" "$build_info"
  grep -qF "UBI_IMAGE=${expected_ubi}" "$build_info"
}

@test "cmd_bundle creates bundle-latest.build-info symlink pointing to new build-info" {
  printf "deterministic-content\n" > "$PROJECT_DIR/cpanfile.snapshot"
  expected_hash=$(sha256sum "$PROJECT_DIR/cpanfile.snapshot" | cut -c1-12)

  run_script bundle
  [ "$status" -eq 0 ]
  [ -L "$PROJECT_DIR/bundles/bundle-latest.build-info" ]
  link_target=$(readlink "$PROJECT_DIR/bundles/bundle-latest.build-info")
  [ "$link_target" = "bundle-${expected_hash}.build-info" ]
}

@test "cmd_bundle backfills build-info when bundle already exists but stamp is missing" {
  printf "deterministic-content\n" > "$PROJECT_DIR/cpanfile.snapshot"
  expected_hash=$(sha256sum "$PROJECT_DIR/cpanfile.snapshot" | cut -c1-12)
  touch "$PROJECT_DIR/bundles/bundle-${expected_hash}.tar.gz"

  run_script bundle
  [ "$status" -eq 0 ]
  # Skip path never rebuilds the bundle itself, but must still backfill the stamp.
  [ -f "$PROJECT_DIR/bundles/bundle-${expected_hash}.build-info" ]
  ! grep -q "^podman build" "$BATS_TEST_TMPDIR/podman.log"
}

@test "cmd_bundle stamps the overridden UBI_IMAGE, not the Containerfile default" {
  printf "deterministic-content\n" > "$PROJECT_DIR/cpanfile.snapshot"
  expected_hash=$(sha256sum "$PROJECT_DIR/cpanfile.snapshot" | cut -c1-12)
  export UBI_IMAGE="registry.access.redhat.com/ubi8/ubi-minimal:8.10"

  run_script bundle
  [ "$status" -eq 0 ]
  grep -qF "UBI_IMAGE=registry.access.redhat.com/ubi8/ubi-minimal:8.10" \
    "$PROJECT_DIR/bundles/bundle-${expected_hash}.build-info"
}

# ── IMAGE_NAME override ───────────────────────────────────────────────────────

@test "build_carton_runner tags dev-tools/carton-runner as myapp:* by default" {
  run_script update --module DBI
  [ "$status" -eq 0 ]
  grep -q -- "-t myapp:dev-tools" "$BATS_TEST_TMPDIR/podman.log"
  grep -q -- "-t myapp:carton-runner" "$BATS_TEST_TMPDIR/podman.log"
}

@test "build_carton_runner tags dev-tools/carton-runner under IMAGE_NAME when set" {
  export IMAGE_NAME="billing-service"
  run_script update --module DBI
  [ "$status" -eq 0 ]
  grep -q -- "-t billing-service:dev-tools" "$BATS_TEST_TMPDIR/podman.log"
  grep -q -- "-t billing-service:carton-runner" "$BATS_TEST_TMPDIR/podman.log"
  grep -q -- "--build-arg BASE_IMAGE_NAME=billing-service" "$BATS_TEST_TMPDIR/podman.log"
  ! grep -q -- "myapp" "$BATS_TEST_TMPDIR/podman.log"
}

# ── Proxy passthrough ──────────────────────────────────────────────────────────

@test "build_carton_runner passes --build-arg http_proxy/https_proxy/no_proxy when set" {
  export http_proxy="http://proxy.corp.example:8080"
  export https_proxy="http://proxy.corp.example:8080"
  export no_proxy="localhost,127.0.0.1"
  run_script update --module DBI
  [ "$status" -eq 0 ]
  grep -q -- "--build-arg http_proxy=http://proxy.corp.example:8080" "$BATS_TEST_TMPDIR/podman.log"
  grep -q -- "--build-arg https_proxy=http://proxy.corp.example:8080" "$BATS_TEST_TMPDIR/podman.log"
  grep -q -- "--build-arg no_proxy=localhost,127.0.0.1" "$BATS_TEST_TMPDIR/podman.log"
}

@test "build_carton_runner omits proxy --build-args when unset" {
  run_script update --module DBI
  [ "$status" -eq 0 ]
  ! grep -q -- "--build-arg http_proxy" "$BATS_TEST_TMPDIR/podman.log"
  ! grep -q -- "--build-arg https_proxy" "$BATS_TEST_TMPDIR/podman.log"
  ! grep -q -- "--build-arg no_proxy" "$BATS_TEST_TMPDIR/podman.log"
}

@test "build_carton_runner folds uppercase HTTPS_PROXY in when lowercase is unset" {
  export HTTPS_PROXY="http://proxy.corp.example:8080"
  run_script update --module DBI
  [ "$status" -eq 0 ]
  grep -q -- "--build-arg https_proxy=http://proxy.corp.example:8080" "$BATS_TEST_TMPDIR/podman.log"
}
