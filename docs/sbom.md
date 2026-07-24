# SBOM (Software Bill of Materials)

## Why two generators, not one

General-purpose SBOM tools have no Perl/CPAN cataloger. Checked against
`syft`'s real source (its `syft/pkg/cataloger/` directory and the canonical
`Type` enum in `syft/pkg/type.go`): it covers `alpine`/`rpm`/`deb`, `npm`,
`python`, `gem`, `go-module`, `java`, `php`, `rust`, `dart`, and more — but
nothing CPAN-shaped. Confirmed empirically too: running `syft` against this
repo's real `runtime` image found 131 real RPM packages and zero CPAN/Perl
entries, out of ~700 pinned modules that are actually there. Running `syft`
alone would silently produce an SBOM that omits the interesting, non-obvious
part of the bundle.

`cpan` is nonetheless an officially registered [PURL type](https://github.com/package-url/purl-spec/blob/main/types/cpan-definition.json):
`pkg:cpan/DIST-NAME@version?author=CPANID`. So this repo generates the CPAN
half itself and combines it with `syft`'s OS-package half into one
CycloneDX document — same schema both halves, so combining is just
concatenating `components` arrays.

## What each half covers

- **OS packages** (the UBI base image + everything in `lib-packages.conf`):
  `syft <image> -o cyclonedx-json`. Already fully supported — no gap here.
- **CPAN modules**: `scripts/generate-cpan-sbom.pl cpanfile.snapshot`. Loads
  the snapshot via `Carton::Snapshot` (the same library Carton itself uses
  to read it) and, for each pinned distribution, turns its `pathname`
  (e.g. `E/ET/ETHER/Try-Tiny-0.30.tar.gz`) into a distribution name,
  version, and CPAN author ID via `CPAN::DistnameInfo` — a small, mature,
  purpose-built CPAN module for exactly this, rather than a hand-rolled
  regex reinventing distfile-name parsing. Needs `Carton` and
  `CPAN::DistnameInfo` installed (`cpanm Carton CPAN::DistnameInfo`) — not
  core, but the same throwaway install the `integration` CI job already
  does for Carton.

Distribution name, not module name: a `cpan` purl's name is the
distribution (`Try-Tiny`), not the module (`Try::Tiny`) — CPAN's classic
distinction, and load-bearing here since PURL names can't contain `::`.

## Regenerating locally

```bash
cpanm --notest Carton CPAN::DistnameInfo   # one-time, if not already installed
make runtime                                # if you haven't already
make sbom                                   # writes ./sbom.json
```

`make sbom` (`scripts/generate-sbom.sh`) does both halves and the merge in
one command: builds neither image nor bundle itself (run `make runtime`
first — it checks and tells you to if you haven't), checks `jq` and
`Carton::Snapshot`/`CPAN::DistnameInfo` are available with a clear error if
not, and validates the merged document (`bomFormat`, at least one
`pkg:cpan/` component, no malformed CPAN purls) before writing it out. Uses
a real `syft` binary if one's on `PATH`, otherwise falls back to running
the pinned `docker.io/anchore/syft` image via `podman` automatically —
verified both paths work.

## CI

The `sbom` job (`.github/workflows/test.yml`) runs the exact same
`scripts/generate-sbom.sh` against the curated test image (same fixture the
`container-build`/`vm-deployment` jobs use) on every push, and uploads the
result as a build artifact — no separate CI-only logic to drift out of sync
with the local path.
