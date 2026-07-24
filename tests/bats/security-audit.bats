#!/usr/bin/env bats

# Tests for scripts/security-audit.sh's plumbing. Real CVE advisory data
# changes over time and isn't meaningfully mockable, so — same approach as
# generate-sbom.bats — this only tests the wrapper: clear errors when
# preconditions are missing, that $GITHUB_STEP_SUMMARY gets written to, and
# that the OS-package (trivy) half degrades to a clear skip note rather than
# failing when its own preconditions aren't met. No real trivy invocation
# here — this file stays in the fast, no-external-deps `bats` job's budget;
# real trivy runs are exercised by the `security-audit` CI job and by manual
# `make security-audit` runs against a real built image.
# Needs a real cpan-audit (cpanm --notest CPAN::Audit), which is NOT part of
# the fast `bats` CI job's footprint; skips gracefully if absent.

REAL_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/security-audit.sh"

setup() {
  if ! command -v cpan-audit >/dev/null 2>&1; then
    skip "cpan-audit not installed (cpanm --notest CPAN::Audit)"
  fi

  export PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT_DIR/scripts"
  cp "$REAL_SCRIPT" "$PROJECT_DIR/scripts/security-audit.sh"
  chmod +x "$PROJECT_DIR/scripts/security-audit.sh"

  # A real image tagged "myapp:runtime" may happen to exist on whatever host
  # runs this test (dev machine or CI runner) independent of this test run —
  # force a name that can never collide, so the OS-half "no image" skip path
  # is deterministic regardless of host state.
  export IMAGE_NAME="composeperl-bats-test-$$"
}

run_script() {
  run "$PROJECT_DIR/scripts/security-audit.sh" "$BATS_TEST_TMPDIR/out.json"
}

@test "fails clearly when cpanfile.snapshot is missing" {
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"cpanfile.snapshot"* ]]
}

@test "audits a real snapshot, writes JSON, and reports a known advisory" {
  cat > "$PROJECT_DIR/cpanfile.snapshot" <<'EOF'
# carton snapshot format: version 1.0
DISTRIBUTIONS
  Spreadsheet-ParseExcel-0.65
    pathname: D/DO/DOUGW/Spreadsheet-ParseExcel-0.65.tar.gz
    provides:
      Spreadsheet::ParseExcel 0.65
    requirements:
      perl 5.006
EOF
  run_script
  [ "$status" -ne 0 ]
  [ -f "$BATS_TEST_TMPDIR/out.json" ]
  [[ "$output" == *"Spreadsheet-ParseExcel"* ]]
  [[ "$output" == *"CVE-2023-7101"* ]]
}

@test "writes the report to GITHUB_STEP_SUMMARY when set" {
  cat > "$PROJECT_DIR/cpanfile.snapshot" <<'EOF'
# carton snapshot format: version 1.0
DISTRIBUTIONS
  Spreadsheet-ParseExcel-0.65
    pathname: D/DO/DOUGW/Spreadsheet-ParseExcel-0.65.tar.gz
    provides:
      Spreadsheet::ParseExcel 0.65
    requirements:
      perl 5.006
EOF
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run_script
  [ -f "$GITHUB_STEP_SUMMARY" ]
  grep -q "Spreadsheet-ParseExcel" "$GITHUB_STEP_SUMMARY"
}

@test "OS-package section is present but marked skipped when there's no runtime image" {
  cat > "$PROJECT_DIR/cpanfile.snapshot" <<'EOF'
# carton snapshot format: version 1.0
DISTRIBUTIONS
  Spreadsheet-ParseExcel-0.65
    pathname: D/DO/DOUGW/Spreadsheet-ParseExcel-0.65.tar.gz
    provides:
      Spreadsheet::ParseExcel 0.65
    requirements:
      perl 5.006
EOF
  run_script
  [[ "$output" == *"## OS packages"* ]]
  [[ "$output" == *"Skipped:"* ]]
  [[ "$output" == *"${IMAGE_NAME}:runtime"* || "$output" == *"trivy not installed"* ]]
}

@test "persists a Markdown report with both section headers" {
  cat > "$PROJECT_DIR/cpanfile.snapshot" <<'EOF'
# carton snapshot format: version 1.0
DISTRIBUTIONS
  Spreadsheet-ParseExcel-0.65
    pathname: D/DO/DOUGW/Spreadsheet-ParseExcel-0.65.tar.gz
    provides:
      Spreadsheet::ParseExcel 0.65
    requirements:
      perl 5.006
EOF
  run_script
  [ -f "$BATS_TEST_TMPDIR/out.md" ]
  grep -q "## CPAN / Perl-core" "$BATS_TEST_TMPDIR/out.md"
  grep -q "## OS packages" "$BATS_TEST_TMPDIR/out.md"
}
