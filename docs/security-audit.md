# Security advisory audit (CPAN/Perl-core + OS packages)

`scripts/security-audit.sh` combines two scanners into one human-readable
report, because the earlier CPAN-only version didn't cover what the SBOM
(`docs/sbom.md`) actually inventories — OS packages as well as CPAN
modules.

## What it checks

- **CPAN / Perl-core** (mandatory — hard error if unavailable):
  `cpan-audit deps . --perl` (the
  [`CPAN::Audit`](https://metacpan.org/pod/CPAN::Audit) distribution, the
  CPAN-native equivalent of `npm audit`) against `cpanfile.snapshot`,
  matching every pinned distribution against the
  [`cpan-security-advisory`](https://github.com/briandfoy/cpan-security-advisory)
  database. The `--perl` flag also includes advisories against modules
  shipped with Perl core (e.g. `Storable`, `Encode`, `Archive::Tar`).

  Run for real against this repo's actual `cpanfile.snapshot` (~700
  modules): 112 real advisories matched across 57 distributions, including
  concrete, currently-unaddressed findings — e.g. `Spreadsheet-ParseExcel`
  pinned at `0.65` is vulnerable to CVE-2023-7101 (arbitrary code execution
  via a crafted Number format string), fixed in `0.66`.

- **OS packages** (best-effort locally, always-on in CI): `trivy` against
  the built `${IMAGE_NAME:-myapp}:runtime` image — matches this project's
  own `docker.md` convention ("scan with trivy before pushing") rather
  than introducing an unrelated tool. Needs `podman save` to get the image
  into a tarball first (`trivy image --input`), the same approach
  `generate-sbom.sh` already uses for `syft` — avoids the podman-socket
  permission issue that direct socket access hit earlier.

  Run for real against this repo's built runtime image: 27 real
  HIGH-severity advisories across the RHEL9 base + `lib-packages.conf`
  packages (e.g. `curl-minimal`, `gnutls`, `libarchive`).

## Two different severity policies, deliberately

- **CPAN half fails on *any* match.** CPANSA advisory records carry a
  `severity` field, but it's mostly unset: of the 112 advisories found
  against this repo's real pins, 94 have `severity: null`. Filtering on
  severity would silently hide most findings, so this half doesn't try.
- **OS half fails only on `HIGH`/`CRITICAL`** (`trivy --severity HIGH,CRITICAL --exit-code 1`). Unlike CPANSA, trivy's severity data is
  reliable, and a full UBI9 + dev-tools RPM set carries a much higher
  advisory volume — gating by severity keeps this actionable instead of
  permanently red.

These aren't the same policy applied inconsistently — they're each suited
to how reliable and how voluminous their own data source is.

## Best-effort locally, mandatory in CI

The CPAN half needs nothing but `cpanfile.snapshot` — no image, no
container runtime — and always runs. The OS half needs a built runtime
image and `trivy` on `PATH`; if either is missing, the script prints a
one-line skip note ("Skipped: myapp:runtime not found — run `make runtime` first" / "Skipped: trivy not installed") instead of failing, so
a bare local checkout can still run `make security-audit` and get useful
CPAN/Perl-core results immediately. CI always has both, so the scheduled
job's report is always complete.

## Output

- `security-audit.json` — raw combined output, `{"cpan": ..., "os": ...}`.
- A report with `## CPAN / Perl-core` and `## OS packages` sections,
  printed to stdout and appended to `$GITHUB_STEP_SUMMARY` when set. Not
  written to disk as a separate file — a persisted copy turned out not to
  be worth the extra artifact.

## Running locally

```bash
cpanm --notest CPAN::Audit    # one-time, if not already installed
make security-audit           # CPAN/Perl-core half only, always works

# For full coverage (OS half too):
make runtime                  # build the image to scan
# install trivy: https://github.com/aquasecurity/trivy/releases
make security-audit           # now scans both halves
```

Non-zero exit means at least one advisory matched (CPAN: any severity; OS:
HIGH/CRITICAL only). `trivy` fetches its vulnerability DB over the network
on every run (~100MB) and picks up `http_proxy`/`https_proxy` from the
environment automatically, same as every other network-touching tool in
this repo (`docs/proxy.md`) — no script changes needed for that.

## CI

The `security-audit` job (`.github/workflows/test.yml`) runs on a weekly
schedule (`cron: '0 6 * * 1'`, Monday 06:00 UTC) and via manual
`workflow_dispatch` — not on every push/PR, since advisory data changes on
its own timeline, not this repo's commit history. It runs the CPAN half
against the **real** `cpanfile.snapshot`, builds the same curated test
image the `sbom`/`container-build` jobs use for the OS half (its OS
packages are identical to production — only the bundled CPAN cpanfile
differs), and uploads `security-audit.json` as a build artifact.
