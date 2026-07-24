#!/usr/bin/env perl
# Verifies modules load from the post-update bundle.
# Asserts Try::Tiny was actually upgraded past the pinned 0.30 baseline.
use strict;
use warnings;
use version ();
use Try::Tiny;
use Moo;
use JSON::XS;
use DBD::SQLite;

# Compare as versions, not with the string operator `gt`. `gt` orders
# lexically, which is not version semantics — it diverges from numeric order
# for multi-segment/dotted versions (e.g. '0.9' gt '0.10' is true as strings
# but false as versions). version->parse is the correct, scheme-agnostic tool.
die "Try::Tiny version ($Try::Tiny::VERSION) is not newer than 0.30 — update was a no-op\n"
    unless version->parse($Try::Tiny::VERSION) > version->parse('0.30');

print "OK: Try::Tiny $Try::Tiny::VERSION (>0.30), Moo $Moo::VERSION, "
    . "JSON::XS $JSON::XS::VERSION, DBD::SQLite $DBD::SQLite::VERSION\n";
