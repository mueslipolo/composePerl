#!/usr/bin/env perl

# generate-cpan-sbom.pl - CycloneDX SBOM for the CPAN half of the bundle
#
# Purpose: Emits one CycloneDX component per pinned CPAN distribution in a
#          cpanfile.snapshot, each with a `pkg:cpan/...` PURL (an officially
#          registered PURL type — see purl-spec's cpan-definition.json).
#          Covers the gap general-purpose SBOM tools (e.g. syft) leave: none
#          of them have a Perl/CPAN cataloger, so an image-level SBOM alone
#          silently omits every CPAN module. Combine this script's output
#          with an OS-package SBOM (e.g. `syft <image> -o cyclonedx-json`)
#          to get full coverage — same CycloneDX schema, so combining is
#          just concatenating "components" arrays.
# Usage:   generate-cpan-sbom.pl <cpanfile.snapshot> > cpan-sbom.json
# Needs:   Carton::Snapshot, CPAN::DistnameInfo (not core — install via
#          `cpanm Carton CPAN::DistnameInfo`, the same way the CI jobs that
#          need Carton already do)

use strict;
use warnings;
use feature 'say';
use JSON::PP ();
use Carton::Snapshot;
use CPAN::DistnameInfo;

my $snapshot_path = shift @ARGV
    or die "Usage: $0 <cpanfile.snapshot>\n";

my $snapshot = Carton::Snapshot->new(path => $snapshot_path);
$snapshot->load;

my @components;
for my $dist ($snapshot->distributions) {
    my $pathname = $dist->pathname;
    my $info = CPAN::DistnameInfo->new($pathname);

    my $name    = $info->dist;
    my $version = $info->version;
    my $cpanid  = $info->cpanid;

    unless (defined $name && length $name) {
        warn "WARNING: could not parse distribution name from pathname '$pathname' — skipping\n";
        next;
    }

    # Percent-encode the components spliced into the PURL: the spec reserves
    # characters like @ ? / and unusual dist/version strings (e.g. a version
    # such as '1.0+build') would otherwise produce a spec-invalid PURL that
    # strict consumers reject.
    my $purl = 'pkg:cpan/' . _purl_encode($name);
    $purl .= '@' . _purl_encode($version) if defined $version && length $version;
    $purl .= '?author=' . _purl_encode($cpanid) if defined $cpanid && length $cpanid;

    push @components, {
        type    => 'library',
        name    => $name,
        (defined $version && length $version ? (version => $version) : ()),
        purl    => $purl,
        externalReferences => [
            {
                type => 'distribution',
                url  => "https://cpan.metacpan.org/authors/id/$pathname",
            },
        ],
    };
}

my @sorted = sort { $a->{name} cmp $b->{name} } @components;

my $bom = {
    bomFormat   => 'CycloneDX',
    specVersion => '1.6',
    version     => 1,
    metadata    => {
        timestamp => _iso8601_now(),
        tools     => [
            { name => 'generate-cpan-sbom.pl', vendor => 'composePerl' },
        ],
    },
    components => \@sorted,
};

print JSON::PP->new->canonical->pretty->encode($bom);

sub _iso8601_now {
    my @t = gmtime;
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# Percent-encode everything outside the PURL "unreserved" set so reserved
# characters (@ ? / & = + …) in a dist name, version, or author can't corrupt
# the PURL structure.
sub _purl_encode {
    my ($s) = @_;
    $s =~ s/([^A-Za-z0-9._~-])/sprintf('%%%02X', ord $1)/ge;
    return $s;
}
