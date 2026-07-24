#!/usr/bin/env perl
use strict;
use warnings;
use Mojolicious::Lite -signatures;   # provided by the shared common layer
use Try::Tiny;                       # provided by the shared common layer
use Path::Tiny qw(path);             # provided by this component's delta layer

get '/' => sub ($c) {
    try {
        my $tmp = path("/tmp/billing-component.txt");
        $tmp->spew("ok");
        die "readback mismatch\n" unless $tmp->slurp eq "ok";
        $c->render(text => "billing component OK: Try::Tiny (common) + Path::Tiny (delta) both loaded\n");
    } catch {
        $c->render(text => "billing component FAILED: $_\n", status => 500);
    };
};

app->start;
