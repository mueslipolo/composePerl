#!/usr/bin/env perl

use strict;
use warnings;
use feature 'say';

# -------------------------------
# Config
# -------------------------------
my $cpanfile = 'cpanfile';
my %blacklist = map { $_ => 1 } qw(
    Devel::CheckLib
    Mixin::Linewise
);

# -------------------------------
# Collect modules
# -------------------------------
open my $fh, '<', $cpanfile or die "Can't open $cpanfile: $!";
my @modules = map { /requires\s+"([^"]+)"/ ? $1 : () } grep { !/^\s*#/ && !/^Devel::/ } <$fh>;
close $fh;

# -------------------------------
# Test modules
# -------------------------------
my (@ok, @fail, @skipped);

for my $m (@modules) {
    if ($blacklist{$m}) {
        push @skipped, $m;
        say "[SKIP] $m";
        next;
    }

    eval "require $m";
    push @{ $@ ? \@fail : \@ok }, $m;
    say $@ ? "[FAIL] $m - $@" : "[ OK ] $m";
}

# -------------------------------
# Summary
# -------------------------------
say "\nSummary:";
say "  OK     : " . scalar(@ok);
say "  FAIL   : " . scalar(@fail);
say "  SKIPPED: " . scalar(@skipped);

exit 1 if @fail;
