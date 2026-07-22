#!/opt/perl/bin/perl
use strict;
use warnings;
use feature 'say';

# Demo application (placeholder — see README's "What this repo is for").
# Proves the offline CPAN bundle actually installed something into @INC,
# without assuming any specific module or framework — the real app that
# replaces this can use whatever it needs.

say "Hello from Perl runtime!";
say "";
say "Environment:";
say "  Perl version: $^V";
say "";

my ($bundle_lib) = grep { m{/opt/cpan-modules/lib} } @INC;
my @installed = $bundle_lib ? glob("$bundle_lib/*") : ();

if ($bundle_lib && -d $bundle_lib && @installed) {
    say "Bundle path in \@INC: $bundle_lib";
    say "Installed module directories found: " . scalar(@installed);
    say "";
    say "CPAN bundle loaded successfully.";
}
else {
    say "ERROR: offline CPAN bundle not found in \@INC (expected .../opt/cpan-modules/lib/perl5)";
    exit 1;
}
