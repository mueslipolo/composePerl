#!/usr/bin/env bats

# Integration test for the layered install (scripts/install-component-layered.sh):
# a component installs its full closure, then prunes the files the shared
# `common` layer already provides, leaving a delta-only component lib that
# loads correctly stacked on common. See docs/multi-component.md ("Layered
# install"). Real CPAN via Carton + cpm; skips when either is absent.

FIXTURES="$BATS_TEST_DIRNAME/../multi-component"
RESOLVE="$BATS_TEST_DIRNAME/../../scripts/resolve-component.sh"
INSTALL="$BATS_TEST_DIRNAME/../../scripts/install-component-layered.sh"

setup_file() {
  command -v carton >/dev/null 2>&1 || return 0
  command -v cpm    >/dev/null 2>&1 || return 0
  # Resolve the common BOM, then install it into a shared common-lib once.
  COMMON_DIR="${BATS_FILE_TMPDIR}/common"
  COMMON_LIB="${BATS_FILE_TMPDIR}/common-lib"
  mkdir -p "$COMMON_DIR"
  cp "$FIXTURES/common/cpanfile" "$COMMON_DIR/cpanfile"
  ( cd "$COMMON_DIR" && carton install >/dev/null 2>&1 && carton bundle >/dev/null 2>&1 )
  cpm install -L "$COMMON_LIB" \
      --resolver "02packages,file://${COMMON_DIR}/vendor/cache" \
      --cpanfile "${COMMON_DIR}/cpanfile" >/dev/null 2>&1
  export COMMON_DIR COMMON_LIB
}

setup() {
  command -v carton >/dev/null 2>&1 || skip "carton not installed"
  command -v cpm    >/dev/null 2>&1 || skip "cpm not installed"
}

pms() { (cd "$1/lib/perl5" 2>/dev/null && find . -name '*.pm' | sort) || true; }

@test "common-lib holds the shared modules" {
  run pms "$COMMON_LIB"
  [[ "$output" == *"Try/Tiny.pm"* ]]
  [[ "$output" == *"Capture/Tiny.pm"* ]]
}

@test "alpha: component lib carries ONLY the delta after prune" {
  work="${BATS_TEST_TMPDIR}/work-alpha"; lib="${BATS_TEST_TMPDIR}/alpha-lib"
  run "$RESOLVE" "$COMMON_DIR" "$FIXTURES/alpha/cpanfile" "$work"
  [ "$status" -eq 0 ]
  run "$INSTALL" "$work" "$COMMON_LIB" "$lib"
  [ "$status" -eq 0 ]
  # delta module present...
  run pms "$lib"
  [[ "$output" == *"Test/Fatal.pm"* ]]
  # ...and common's modules pruned out (not duplicated in the component layer)
  [[ "$output" != *"Try/Tiny.pm"* ]]
  [[ "$output" != *"Capture/Tiny.pm"* ]]
}

@test "alpha: stacked PERL5LIB loads a common module AND a delta module" {
  work="${BATS_TEST_TMPDIR}/work-alpha2"; lib="${BATS_TEST_TMPDIR}/alpha-lib2"
  "$RESOLVE" "$COMMON_DIR" "$FIXTURES/alpha/cpanfile" "$work" >/dev/null
  "$INSTALL" "$work" "$COMMON_LIB" "$lib" >/dev/null
  run perl -I "$lib/lib/perl5" -I "$COMMON_LIB/lib/perl5" \
      -e 'use Try::Tiny; use Test::Fatal; print "ok"'
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  # And the delta module must NOT be loadable from common alone.
  run perl -I "$COMMON_LIB/lib/perl5" -e 'use Test::Fatal;'
  [ "$status" -ne 0 ]
}

@test "beta: empty delta -> component lib carries no modules of its own" {
  work="${BATS_TEST_TMPDIR}/work-beta"; lib="${BATS_TEST_TMPDIR}/beta-lib"
  "$RESOLVE" "$COMMON_DIR" "$FIXTURES/beta/cpanfile" "$work" >/dev/null
  run "$INSTALL" "$work" "$COMMON_LIB" "$lib"
  [ "$status" -eq 0 ]
  run pms "$lib"
  [ -z "$output" ]
}
