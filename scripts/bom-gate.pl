#!/usr/bin/env perl

# bom-gate.pl - the "common is a BOM" conflict gate for the multi-component model
#
# Purpose: Enforce the rule from docs/multi-component.md that `common` is
#          authoritative for every distribution it pins: a component may ADD
#          new distributions, but may NOT pin a *different* version of one that
#          common already pins. Carton resolves and bundles, but it will
#          silently move a shared pin if a component demands a higher version;
#          this gate re-checks the resolved component snapshot against common's
#          and fails hard if any shared distribution's version diverged.
#
# Usage:   bom-gate.pl <common.snapshot> <component.snapshot>
#
# Exit:    0  no conflict. Prints the component's DELTA (distributions it adds
#             that common doesn't have) to stdout, one "Name version" per line.
#          1  conflict: at least one shared distribution is pinned to different
#             versions in common vs. the component. Prints the conflicts to
#             stderr with remediation, and lists them on stdout for tooling.
#          2  usage / unreadable input.
#
# Distribution identity is parsed from each cpanfile.snapshot DISTRIBUTIONS
# entry header (e.g. "Try-Tiny-0.30"). This mirrors the parsing already done in
# scripts/generate-cpan-sbom.pl and tests/TestConfig.pm. The name/version split
# here is a self-contained regex (no non-core deps, so the gate can run in a
# minimal CI image); production hardening could swap in CPAN::DistnameInfo,
# which Carton already pulls in, for the handful of exotic version strings the
# regex doesn't cover.

use strict;
use warnings;
use feature 'say';

if (@ARGV != 2) {
    say STDERR "Usage: $0 <common.snapshot> <component.snapshot>";
    exit 2;
}
my ($common_path, $component_path) = @ARGV;

my $common    = parse_snapshot($common_path);
my $component = parse_snapshot($component_path);

# Conflicts: distributions present in BOTH, pinned to different versions.
my @conflicts;
for my $dist (sort keys %$component) {
    next unless exists $common->{$dist};
    push @conflicts, $dist if $common->{$dist} ne $component->{$dist};
}

# Delta: distributions the component adds that common doesn't pin at all.
my @delta = sort grep { !exists $common->{$_} } keys %$component;

if (@conflicts) {
    say STDERR "BOM CONFLICT: component overrides distribution(s) that 'common' pins.";
    say STDERR "'common' is authoritative — a component may add libs, not re-pin shared ones.";
    say STDERR "";
    for my $dist (@conflicts) {
        say STDERR sprintf("  %-30s common=%-12s component=%s",
            $dist, $common->{$dist}, $component->{$dist});
    }
    say STDERR "";
    say STDERR "Fix each by either:";
    say STDERR "  - bumping it in common/cpanfile (accept it changes for ALL components), or";
    say STDERR "  - removing it from common/cpanfile so each component pins its own.";
    # Also emit machine-readable conflict lines on stdout for calling tooling.
    say "CONFLICT $_ $common->{$_} $component->{$_}" for @conflicts;
    exit 1;
}

# No conflict: report the delta the component bundle should vendor.
say "$_ $component->{$_}" for @delta;
exit 0;

# ---------------------------------------------------------------------------

# Parse a cpanfile.snapshot into { distribution-name => version }.
#
# Carton's snapshot format lists one distribution per DISTRIBUTIONS entry,
# indented exactly two spaces, as "<Dist-Name>-<version>"; its sub-fields
# (pathname:, provides:, requirements:) are indented deeper, so a two-space
# indent unambiguously selects distribution headers.
sub parse_snapshot {
    my ($path) = @_;
    open my $fh, '<', $path or do {
        say STDERR "ERROR: cannot read snapshot '$path': $!";
        exit 2;
    };
    my %dist;
    my $in_distributions = 0;
    while (my $line = <$fh>) {
        chomp $line;
        if ($line =~ /^DISTRIBUTIONS\s*$/) { $in_distributions = 1; next; }
        next unless $in_distributions;
        # A distribution header is exactly two leading spaces + non-space.
        # Deeper-indented (4+ space) sub-fields are skipped; a non-indented
        # line would end the DISTRIBUTIONS section.
        if ($line =~ /^(\S)/) { $in_distributions = 0; next; }
        next unless $line =~ /^  (\S.*?)\s*$/;
        my $distfile = $1;
        my ($name, $version) = parse_distname($distfile);
        next unless defined $name;
        $dist{$name} = $version;
    }
    close $fh;
    return \%dist;
}

# Split "Dist-Name-Version" into (name, version). The version is the trailing
# hyphen-separated run that starts with an optional 'v' then a digit, e.g.
# Try-Tiny-0.30 -> ("Try-Tiny","0.30"), libwww-perl-6.72 -> ("libwww-perl","6.72"),
# Foo-Bar-1.23_01 -> ("Foo-Bar","1.23_01"). Returns () if it doesn't look like
# a versioned distname.
sub parse_distname {
    my ($s) = @_;
    if ($s =~ /^(.*?)-(v?[0-9][0-9A-Za-z._]*)$/) {
        return ($1, $2);
    }
    return ();
}
