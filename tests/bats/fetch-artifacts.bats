#!/usr/bin/env bats

# Tests for scripts/fetch-artifacts.sh.
# curl and sha256sum are mocked; the script is copied to an isolated project dir.

MOCKS_DIR="$BATS_TEST_DIRNAME/mocks"
REAL_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/fetch-artifacts.sh"

setup() {
  export PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT_DIR/scripts"
  cp "$REAL_SCRIPT" "$PROJECT_DIR/scripts/fetch-artifacts.sh"
  chmod +x "$PROJECT_DIR/scripts/fetch-artifacts.sh"

  export PATH="$MOCKS_DIR/fetch-artifacts:$PATH"

  # sha256s of the mock curl's deterministic per-destination payloads
  # (`printf 'mock-payload-for-%s\n' <filename>`). Overrides the real pinned
  # hashes so tests pass without hitting the network.
  export PERL_SHA256="8f720d25e7c1857824b1e0920a4d64a0e3d84f36f58c58fd35595b8634e21e93"
  export CPANM_SHA256="41c144a55d3001523caf77c4b963a10f44e605a25a28370b4cf470601713b3b1"
  export CPM_SHA256="710a019b085506d3616183d31dcccbc69b23f73e5562f32aac13cde42c5de87c"
  export ORACLE_BASICLITE_SHA256="237c89b32b7157542307ae9f9c15e607fff7d156e1aae91da51aa15865152c02"
  export ORACLE_SDK_SHA256="adaaa459198c6763ab07ec9391b6520ece64067823b1c3990da49f5a4e5bbe9c"
}

run_script() {
  run "$PROJECT_DIR/scripts/fetch-artifacts.sh" "$@"
}

# ── Argument handling ────────────────────────────────────────────────────────

@test "fetch-artifacts.sh rejects unknown arguments" {
  run_script --frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown argument"* ]]
}

@test "fetch-artifacts.sh --help prints usage without downloading" {
  run_script --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Populate artifacts/ with build inputs"* ]]
  [ ! -d "$PROJECT_DIR/artifacts" ]
}

# ── Idempotence ──────────────────────────────────────────────────────────────

@test "fetch-artifacts.sh is idempotent when artifacts already match hashes" {
  # Prime the artifacts dir with files whose sha256 matches whatever the
  # mock curl would produce, so the script sees "already present, skipping"
  # and never invokes curl.
  mkdir -p "$PROJECT_DIR/artifacts"

  # The mock writes a payload composed from the destination filename. We
  # precompute the expected sha256 for each artifact and prime the file.
  # Since the real script pins upstream SHA256s, we can't easily match them
  # from the mock — instead, we prove idempotence by asserting that on a
  # second run every fetch reports "skipping" for files the mock has
  # already produced. First run downloads (via mock), second run skips.

  run_script
  first_status=$status
  first_output=$output

  run_script
  second_status=$status
  second_output=$output

  [ "$first_status" -eq 0 ] || (echo "first run failed: $first_output"; false)
  [ "$second_status" -eq 0 ] || (echo "second run failed: $second_output"; false)

  # First run: at least one "Fetching" line. Second run: all "already present".
  [[ "$first_output" == *"Fetching"* ]]
  [[ "$second_output" != *"Fetching"* ]]
  [[ "$second_output" == *"already present"* ]]
}

# ── Hash mismatch failure ────────────────────────────────────────────────────

@test "fetch-artifacts.sh fails when download hash does not match pinned hash" {
  # Point the mock at a bad payload so the sha256 will not match the
  # pinned hash in the real script.
  export FETCH_MOCK_BAD_PAYLOAD=1

  run_script
  [ "$status" -ne 0 ]
  [[ "$output" == *"sha256 mismatch"* ]] || \
    [[ "$output" == *"sha256"* ]] || \
    (echo "expected sha256 error, got: $output"; false)
}

# ── Existing file with wrong hash triggers re-download ───────────────────────

@test "fetch-artifacts.sh re-downloads when existing file's hash is wrong" {
  mkdir -p "$PROJECT_DIR/artifacts"
  # Pre-populate with junk that will not match any pinned hash
  echo "junk-content" > "$PROJECT_DIR/artifacts/perl-5.42.2.tar.gz"

  run_script
  # Regardless of whether the mock's payload matches the real hash, the
  # script must detect the pre-existing hash mismatch and re-download.
  [[ "$output" == *"sha256 mismatch, re-downloading"* ]]
}
