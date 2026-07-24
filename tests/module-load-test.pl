#!/usr/bin/env perl

# module-load-test.pl - Quick smoke test for Perl modules
#
# Purpose: Verifies that all modules in cpanfile can be loaded
# Usage:   Run via 'make test-load-dev' or 'make test-load-runtime'
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
my @modules = TestConfig->parse_cpanfile_modules($cpanfile);

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

    # Validate the name and require by path in a block eval, rather than a
    # string eval that would compile-and-run whatever is in $m. Module names
    # come from /tmp/cpanfile, but a string eval on them is needless exposure.
    unless ($m =~ /\A[\w:]+\z/) {
        push @fail, $m;
        say "[FAIL] $m - rejected: not a valid module name";
        next;
    }
    (my $path = $m) =~ s{::}{/}g;
    $path .= '.pm';
    my $loaded = eval { require $path; 1 };
    if (!$loaded) {
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
        say sprintf("  - %-30s (%s)", $skip->{module}, $skip->{reason});
    }
}

exit 1 if @fail;
