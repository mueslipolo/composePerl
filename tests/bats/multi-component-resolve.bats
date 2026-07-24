#!/usr/bin/env bats

# Integration test for the multi-component resolve+gate flow
# (scripts/resolve-component.sh + scripts/bom-gate.pl), against REAL CPAN via
# Carton. Fixtures live in tests/multi-component/. See docs/multi-component.md.
#
# Needs `carton` + network (it actually resolves/installs tiny pure-Perl
# distributions), so — like generate-cpan-sbom.bats — it skips gracefully when
# Carton isn't present rather than being a hard dependency of the fast bats job.
# It belongs in a network-enabled CI job, not the offline unit layer.

FIXTURES="$BATS_TEST_DIRNAME/../multi-component"
RESOLVE="$BATS_TEST_DIRNAME/../../scripts/resolve-component.sh"

setup_file() {
  if ! command -v carton >/dev/null 2>&1; then return 0; fi
  # Resolve the common BOM once for the whole file.
  COMMON_DIR="${BATS_FILE_TMPDIR}/common"
  mkdir -p "$COMMON_DIR"
  cp "$FIXTURES/common/cpanfile" "$COMMON_DIR/cpanfile"
  ( cd "$COMMON_DIR" && carton install >/dev/null 2>&1 )
  export COMMON_DIR
}

setup() {
  if ! command -v carton >/dev/null 2>&1; then
    skip "carton not installed (cpanm Carton) — integration test needs it + network"
  fi
}

# resolve <component> — runs the harness, sets $out to its work dir.
resolve() {
  out="${BATS_TEST_TMPDIR}/$1"
  run "$RESOLVE" "$COMMON_DIR" "$FIXTURES/$1/cpanfile" "$out"
}

dists() { grep -E '^  [A-Za-z]' "$1" | sed -e 's/^  //'; }

@test "common BOM resolved to the expected pinned versions" {
  run dists "$COMMON_DIR/cpanfile.snapshot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Try-Tiny-0.30"* ]]      # pinned old on purpose
  [[ "$output" == *"Capture-Tiny-"* ]]
}

@test "alpha: reuse + new dep + diamond — delta is only the new distribution" {
  resolve alpha
  [ "$status" -eq 0 ]
  # Delta contains Test-Fatal (new)...
  grep -q '^Test-Fatal ' "$out/delta.txt"
  # ...and NOTHING that common already pins (Try-Tiny, Capture-Tiny excluded).
  ! grep -qE '^(Try-Tiny|Capture-Tiny) ' "$out/delta.txt"
  # Diamond: Test::Fatal depends on Try::Tiny, but the resolved snapshot kept
  # common's Try-Tiny-0.30 rather than re-pinning it.
  grep -q '^  Try-Tiny-0.30$' "$out/cpanfile.snapshot"
}

@test "alpha: no delta distribution is one that common already pins" {
  resolve alpha
  [ "$status" -eq 0 ]
  while read -r name _; do
    [ -n "$name" ] || continue
    run grep -qE "^  ${name}-" "$COMMON_DIR/cpanfile.snapshot"
    [ "$status" -ne 0 ] || { echo "delta dist $name is already in common"; false; }
  done < "$out/delta.txt"
}

@test "beta: reuses only shared libs — empty delta, exit 0" {
  resolve beta
  [ "$status" -eq 0 ]
  [ ! -s "$out/delta.txt" ]
}

@test "gamma: demands a newer shared lib than common pins — BOM conflict, exit 1" {
  resolve gamma
  [ "$status" -eq 1 ]
  [[ "$output" == *"BOM CONFLICT"* ]]
  [[ "$output" == *"Try-Tiny"* ]]
  # no delta file is left behind on conflict
  [ ! -f "$out/delta.txt" ]
}

@test "two-component independence: alpha's extra does not leak into beta's delta" {
  resolve alpha
  [ "$status" -eq 0 ]
  grep -q '^Test-Fatal ' "$out/delta.txt"
  resolve beta
  [ "$status" -eq 0 ]
  # beta must not have picked up alpha's Test-Fatal
  [ ! -s "$out/delta.txt" ] || ! grep -q '^Test-Fatal ' "$out/delta.txt"
}
