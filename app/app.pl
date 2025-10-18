#!/opt/perl/bin/perl
use strict;
use warnings;
use feature 'say';

# Demo application - verifies that dependencies are available
use Mojolicious;


say "Hello from Perl runtime!";
say "";
say "Environment:";
say "  Perl version: $^V";
say "  Mojolicious version: $Mojolicious::VERSION";
say "";
say "All dependencies loaded successfully.";
