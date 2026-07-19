#!/usr/bin/env bats

# Smoke tests: verify expected files exist and scripts are executable.
# These run without containers or Oracle artifacts.

@test "Containerfile is present" {
  [[ -f "$BATS_TEST_DIRNAME/../../Containerfile" ]]
}

@test "cpanfile is present" {
  [[ -f "$BATS_TEST_DIRNAME/../../cpanfile" ]]
}

@test "Makefile is present" {
  [[ -f "$BATS_TEST_DIRNAME/../../Makefile" ]]
}

@test "build-image.sh is executable" {
  [[ -x "$BATS_TEST_DIRNAME/../../scripts/build-image.sh" ]]
}

@test "bundle-create.sh is executable" {
  [[ -x "$BATS_TEST_DIRNAME/../../scripts/bundle-create.sh" ]]
}

@test "test-load-modules.sh is executable" {
  [[ -x "$BATS_TEST_DIRNAME/../../scripts/test-load-modules.sh" ]]
}
