#!/usr/bin/env bats

# Tests for scripts/generate-cpan-sbom.pl against a small synthetic
# cpanfile.snapshot fixture (not the real ~700-module one). Needs
# Carton::Snapshot + CPAN::DistnameInfo, which are NOT part of the fast
# `bats` CI job's footprint (they're the same throwaway install the
# `integration`/`sbom` jobs already do) — skips gracefully if absent rather
# than making them a hard dependency of the fast unit-test layer.

REAL_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/generate-cpan-sbom.pl"

setup() {
  if ! perl -MCarton::Snapshot -e1 2>/dev/null; then
    skip "Carton::Snapshot not installed (cpanm Carton CPAN::DistnameInfo)"
  fi
  if ! perl -MCPAN::DistnameInfo -e1 2>/dev/null; then
    skip "CPAN::DistnameInfo not installed (cpanm Carton CPAN::DistnameInfo)"
  fi

  SNAPSHOT="$BATS_TEST_TMPDIR/cpanfile.snapshot"
  cat > "$SNAPSHOT" <<'EOF'
# carton snapshot format: version 1.0
DISTRIBUTIONS
  Try-Tiny-0.30
    pathname: E/ET/ETHER/Try-Tiny-0.30.tar.gz
    provides:
      Try::Tiny 0.30
    requirements:
      perl 5.006
  DBD-Oracle-1.90
    pathname: Z/ZA/ZARQUON/DBD-Oracle-1.90.tar.gz
    provides:
      DBD::Oracle 1.90
    requirements:
      DBI 1.630
EOF
}

run_script() {
  run perl "$REAL_SCRIPT" "$SNAPSHOT"
}

@test "emits valid JSON with a CycloneDX header" {
  run_script
  [ "$status" -eq 0 ]
  # Parse and assert on values, not on the encoder's pretty-print spacing.
  echo "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["bomFormat"] == "CycloneDX", d["bomFormat"]
assert d["specVersion"] == "1.6", d["specVersion"]
'
}

@test "emits one component per distribution with a correct pkg:cpan purl" {
  run_script
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
purls = {c["purl"] for c in d["components"]}
assert len(d["components"]) == 2, len(d["components"])
assert "pkg:cpan/Try-Tiny@0.30?author=ETHER" in purls, purls
assert "pkg:cpan/DBD-Oracle@1.90?author=ZARQUON" in purls, purls
'
}

@test "uses the distribution name, not the module name (no :: in purl)" {
  run_script
  [ "$status" -eq 0 ]
  # Try::Tiny (module) must not leak into the purl as a bare module name —
  # only the distribution name Try-Tiny is a valid `cpan` purl name.
  echo "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
bad = [c["purl"] for c in d["components"] if "::" in c["purl"]]
assert not bad, bad
'
}

@test "fails with a usage message when no snapshot path is given" {
  run perl "$REAL_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}
