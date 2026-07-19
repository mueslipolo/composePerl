#!/usr/bin/env perl
use strict;
use warnings;
use Try::Tiny;
use Moo;
use JSON::XS;
use DBD::SQLite;
print "OK: Try::Tiny $Try::Tiny::VERSION, Moo $Moo::VERSION, "
    . "JSON::XS $JSON::XS::VERSION, DBD::SQLite $DBD::SQLite::VERSION\n";
