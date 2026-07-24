#!/usr/bin/env perl
use strict;
use warnings;
use feature 'say';
use Capture::Tiny qw(capture);   # provided by the shared common layer
use Test::Fatal qw(exception);   # provided by this component's delta layer
say "example component OK: Capture::Tiny (common) + Test::Fatal (delta) both loaded";
