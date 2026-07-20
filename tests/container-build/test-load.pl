#!/usr/bin/env perl
use strict;
use warnings;

# Loads every module in the container-build cpanfile.
# Optional args:
#   --expect-try-tiny-min=X.Y   assert Try::Tiny->VERSION >= X.Y (post-update check)
#   --expect-try-tiny-max=X.Y   assert Try::Tiny->VERSION <= X.Y (baseline pinned check)
# Exits 0 if all load and version constraints hold, non-zero otherwise.

my $expect_try_tiny_min;
my $expect_try_tiny_max;
for my $arg (@ARGV) {
    if ($arg =~ /^--expect-try-tiny-min=(.+)$/) { $expect_try_tiny_min = $1 }
    elsif ($arg =~ /^--expect-try-tiny-max=(.+)$/) { $expect_try_tiny_max = $1 }
    else { die "unknown arg: $arg" }
}

my @modules = qw(
    Try::Tiny
    Moo
    JSON::XS
    Cpanel::JSON::XS
    DBI
    DBD::SQLite
    DBD::mysql
    DBD::Pg
    XML::LibXML
    GD
    DBD::Oracle
);

my @failed;
my %versions;
for my $mod (@modules) {
    my $ok = eval "require $mod; 1";
    if ($ok) {
        my $ver = $mod->VERSION // 'unknown';
        $versions{$mod} = $ver;
        print "ok  $mod ($ver)\n";
    } else {
        my $err = $@ // 'unknown error';
        $err =~ s/\n.*//s;
        print "FAIL $mod: $err\n";
        push @failed, $mod;
    }
}

if (@failed) {
    print STDERR "\n", scalar(@failed), " module(s) failed to load: @failed\n";
    exit 1;
}

# Version-bound assertions
if (defined $expect_try_tiny_min) {
    require version;
    my $actual = version->parse($versions{'Try::Tiny'});
    my $want   = version->parse($expect_try_tiny_min);
    if ($actual < $want) {
        print STDERR "\nFAIL: Try::Tiny version $actual < expected >= $want\n";
        exit 2;
    }
    print "ok  Try::Tiny version $actual >= $want\n";
}
if (defined $expect_try_tiny_max) {
    require version;
    my $actual = version->parse($versions{'Try::Tiny'});
    my $want   = version->parse($expect_try_tiny_max);
    if ($actual > $want) {
        print STDERR "\nFAIL: Try::Tiny version $actual > expected <= $want\n";
        exit 2;
    }
    print "ok  Try::Tiny version $actual <= $want\n";
}

print "\nAll ", scalar(@modules), " modules loaded successfully.\n";
exit 0;
