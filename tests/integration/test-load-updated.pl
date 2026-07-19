#!/usr/bin/env perl
# Verifies modules load from the post-update bundle.
# Asserts Try::Tiny was actually upgraded past the pinned 0.30 baseline.
use strict;
use warnings;
use Try::Tiny;
use Moo;
use JSON::XS;
use DBD::SQLite;

die "Try::Tiny version ($Try::Tiny::VERSION) is not newer than 0.30 — update was a no-op\n"
    unless $Try::Tiny::VERSION gt '0.30';

print "OK: Try::Tiny $Try::Tiny::VERSION (>0.30), Moo $Moo::VERSION, "
    . "JSON::XS $JSON::XS::VERSION, DBD::SQLite $DBD::SQLite::VERSION\n";
