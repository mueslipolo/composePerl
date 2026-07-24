#!/usr/bin/env bats

# Tests for scripts/bom-gate.pl — the "common is a BOM" conflict gate.
# See docs/multi-component.md ("Dependency model") for what it enforces.

REAL_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/bom-gate.pl"

setup() {
  COMMON="$BATS_TEST_TMPDIR/common.snapshot"
  cat > "$COMMON" <<'EOF'
# carton snapshot format: version 1.0
DISTRIBUTIONS
  Try-Tiny-0.30
    pathname: E/ET/ETHER/Try-Tiny-0.30.tar.gz
    provides:
      Try::Tiny 0.30
    requirements:
      perl 5.006
  libwww-perl-6.72
    pathname: O/OA/OALDERS/libwww-perl-6.72.tar.gz
    provides:
      LWP 6.72
  JSON-XS-3.04
    pathname: M/ML/MLEHMANN/JSON-XS-3.04.tar.gz
    provides:
      JSON::XS 3.04
EOF
}

run_gate() {
  run perl "$REAL_SCRIPT" "$@"
}

@test "clean component: exit 0 and emits only the delta distributions" {
  cat > "$BATS_TEST_TMPDIR/comp.snapshot" <<'EOF'
# carton snapshot format: version 1.0
DISTRIBUTIONS
  Try-Tiny-0.30
    pathname: E/ET/ETHER/Try-Tiny-0.30.tar.gz
  JSON-XS-3.04
    pathname: M/ML/MLEHMANN/JSON-XS-3.04.tar.gz
  DBI-1.643
    pathname: T/TI/TIMB/DBI-1.643.tar.gz
EOF
  run_gate "$COMMON" "$BATS_TEST_TMPDIR/comp.snapshot"
  [ "$status" -eq 0 ]
  # DBI is the only dist common doesn't pin -> the only delta line.
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "DBI 1.643" ]
}

@test "conflict: exit 1 when a shared distribution is re-pinned to another version" {
  cat > "$BATS_TEST_TMPDIR/comp.snapshot" <<'EOF'
# carton snapshot format: version 1.0
DISTRIBUTIONS
  JSON-XS-4.03
    pathname: M/ML/MLEHMANN/JSON-XS-4.03.tar.gz
  DBI-1.643
    pathname: T/TI/TIMB/DBI-1.643.tar.gz
EOF
  run_gate "$COMMON" "$BATS_TEST_TMPDIR/comp.snapshot"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BOM CONFLICT"* ]]
  [[ "$output" == *"JSON-XS"* ]]
  [[ "$output" == *"common=3.04"* ]]
  [[ "$output" == *"component=4.03"* ]]
  # Machine-readable conflict line for tooling.
  [[ "$output" == *"CONFLICT JSON-XS 3.04 4.03"* ]]
}

@test "reusing a shared distribution at the SAME version is not a conflict" {
  cat > "$BATS_TEST_TMPDIR/comp.snapshot" <<'EOF'
# carton snapshot format: version 1.0
DISTRIBUTIONS
  Try-Tiny-0.30
    pathname: E/ET/ETHER/Try-Tiny-0.30.tar.gz
  JSON-XS-3.04
    pathname: M/ML/MLEHMANN/JSON-XS-3.04.tar.gz
EOF
  run_gate "$COMMON" "$BATS_TEST_TMPDIR/comp.snapshot"
  [ "$status" -eq 0 ]
  # No new dists -> empty delta, no output.
  [ -z "$output" ]
}

@test "multi-dash distribution names are parsed correctly (no false conflict)" {
  # libwww-perl is shared at the same version — must be seen as shared, not delta,
  # and its embedded dash must not confuse the name/version split.
  cat > "$BATS_TEST_TMPDIR/comp.snapshot" <<'EOF'
# carton snapshot format: version 1.0
DISTRIBUTIONS
  libwww-perl-6.72
    pathname: O/OA/OALDERS/libwww-perl-6.72.tar.gz
  Moo-2.005005
    pathname: H/HA/HAARG/Moo-2.005005.tar.gz
EOF
  run_gate "$COMMON" "$BATS_TEST_TMPDIR/comp.snapshot"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "Moo 2.005005" ]
}

@test "underscore/dev version strings are parsed" {
  cat > "$BATS_TEST_TMPDIR/comp.snapshot" <<'EOF'
# carton snapshot format: version 1.0
DISTRIBUTIONS
  Foo-Bar-1.23_01
    pathname: X/XX/XXX/Foo-Bar-1.23_01.tar.gz
EOF
  run_gate "$COMMON" "$BATS_TEST_TMPDIR/comp.snapshot"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Foo-Bar 1.23_01" ]
}

@test "multiple conflicts are all reported" {
  cat > "$BATS_TEST_TMPDIR/comp.snapshot" <<'EOF'
# carton snapshot format: version 1.0
DISTRIBUTIONS
  Try-Tiny-0.31
    pathname: E/ET/ETHER/Try-Tiny-0.31.tar.gz
  JSON-XS-4.03
    pathname: M/ML/MLEHMANN/JSON-XS-4.03.tar.gz
EOF
  run_gate "$COMMON" "$BATS_TEST_TMPDIR/comp.snapshot"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CONFLICT Try-Tiny 0.30 0.31"* ]]
  [[ "$output" == *"CONFLICT JSON-XS 3.04 4.03"* ]]
}

@test "usage error when not exactly two args" {
  run_gate "$COMMON"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "exits 2 on an unreadable snapshot" {
  run_gate "$COMMON" "$BATS_TEST_TMPDIR/does-not-exist.snapshot"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot read snapshot"* ]]
}
