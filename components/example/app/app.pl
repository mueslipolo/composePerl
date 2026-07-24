#!/usr/bin/env perl
use strict;
use warnings;
use Mojolicious::Lite -signatures;   # provided by the shared common layer
use Capture::Tiny qw(capture);       # provided by the shared common layer
use Test::Fatal qw(exception);       # provided by this component's delta layer

get '/' => sub ($c) {
    $c->render(text => "example component OK: Capture::Tiny (common) + Test::Fatal (delta) both loaded\n");
};

app->start;
