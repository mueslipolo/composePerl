#!/usr/bin/env perl

# module-load-test.pl - Quick smoke test for Perl modules
#
# Purpose: Verifies that all modules in cpanfile can be loaded
# Usage:   Run via 'make test-dev' or 'make test-runtime'
# Config:  Uses test-config.conf to skip modules (skip_load = yes)
# Output:  Pass/Fail/Skip count and list of skipped modules with reasons

use strict;
use warnings;
use feature 'say';
use FindBin qw($RealBin);
use lib $RealBin;

use TestConfig;

# -------------------------------
# Config
# -------------------------------
my $cpanfile = '/tmp/cpanfile';
my $config_file = '/tmp/test-config.conf';

my $config = TestConfig->new($config_file);

# -------------------------------
# Collect modules
# -------------------------------
open my $fh, '<', $cpanfile or die "Can't open $cpanfile: $!";
my @modules = map { /requires\s+"([^"]+)"/ ? $1 : () } grep { !/^\s*#/ } <$fh>;
close $fh;

# -------------------------------
# Test modules
# -------------------------------
my (@ok, @fail, @skipped);

for my $m (@modules) {
    if ($config->should_skip_load($m)) {
        my $reason = $config->get_reason($m);
        push @skipped, { module => $m, reason => $reason };
        say "[SKIP] $m ($reason)";
        next;
    }

    eval "require $m";
    if ($@) {
        push @fail, $m;
        say "[FAIL] $m - $@";
    } else {
        push @ok, $m;
        say "[ OK ] $m";
    }
}

# -------------------------------
# Summary
# -------------------------------
say "";
say "Summary:";
say "  OK     : " . scalar(@ok);
say "  FAIL   : " . scalar(@fail);
say "  SKIPPED: " . scalar(@skipped);

if (@skipped) {
    say "";
    say "Skipped modules:";
    for my $skip (@skipped) {
        my $module = ref($skip) eq 'HASH' ? $skip->{module} : $skip;
        my $reason = ref($skip) eq 'HASH' ? $skip->{reason} : 'unknown';
        say sprintf("  - %-30s (%s)", $module, $reason);
    }
}

exit 1 if @fail;
