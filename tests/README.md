# Test Suite Documentation

This repo has four testing layers with different scope, speed, and infrastructure requirements, plus a separate `lint` CI job (hadolint + shellcheck) that isn't a test layer but gates the same push/PR.

## Layer 1 — Shell unit tests (`tests/bats/`)

**Runs in:** any shell, no containers, no Oracle artifacts, no internet
**Speed:** ~10 seconds
**Run with:** `bats tests/bats/`
**CI job:** `bats` (every push and PR)

Mocks `podman` with a logging stub (`tests/bats/mocks/podman`) that records every invocation to `$BATS_TEST_TMPDIR/podman.log` and returns plausible fake output. Tests assert on the exact command strings the scripts produce.

### Test files

| File                         | What it covers                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `deps.bats`                  | Arg parsing, `carton update` vs `carton install` correctness, `/build` workdir, bundle hash naming, existing-bundle skip, symlink creation, UBI_IMAGE/IMAGE_NAME passthrough, build-info stamping (PERL_VERSION + UBI_IMAGE), precondition checks                                                                                                                                                                                                                                  |
| `build-image.bats`           | Target routing (`dev`/`runtime`/`all`), `--build-arg UBI_IMAGE` passthrough, IMAGE_NAME tagging, hash extraction, missing-bundle guard                                                                                                                                                                                                                                                                                                                                             |
| `status.bats`                | All exit-code paths (missing snapshot, missing bundle, stale symlink, hash mismatch, images missing, all-OK), carton-runner present/absent, IMAGE_NAME override, no-git-repo safety                                                                                                                                                                                                                                                                                                |
| `fetch-artifacts.bats`       | Lockfile pinning (`artifacts.sha256`): first-run TOFU + independent MetaCPAN check for the Perl tarball, idempotent re-verification with no network calls, hard-fail on a pinned artifact's on-disk content diverging, hard-fail when an independent source disagrees, cpanm/cpm version-suffixed filename + stable symlink (a CPANM_VERSION/CPM_VERSION bump actually fetches the new version instead of silently reusing the old cache), proxy env var normalization/passthrough |
| `container-build-setup.bats` | `tests/container-build/setup.sh` creates `certs/`, `bundles/`, and the expected symlinks in the isolated workspace                                                                                                                                                                                                                                                                                                                                                                 |
| `project-structure.bats`     | Required files exist, scripts are executable                                                                                                                                                                                                                                                                                                                                                                                                                                       |

### Regression guards

Two tests exist specifically to catch regressions of past bugs:

- **`cmd_update --module uses carton update, not carton install`** — guards the fix for a silent no-op bug where `carton install MODULE` always exited 0 without updating the snapshot (it checked satisfiability rather than fetching latest).
- **`cmd_update exec runs in /build not /app`** and **`cmd_update cp pulls from /build/cpanfile.snapshot not /app`** — guard the fix for a path bug where `cmd_update` referenced `/app` (which only exists in `dev`/`runtime` stages) instead of `/build` (the `Containerfile.deps` WORKDIR).

A contract test (`deps.sh workdir matches Containerfile.deps WORKDIR`) dynamically extracts both paths at test time so future drift between `Containerfile.deps` and the script is caught automatically.

### Adding bats to your machine

```bash
git clone --depth 1 --branch v1.11.1 \
  https://github.com/bats-core/bats-core.git /tmp/bats-core
sudo /tmp/bats-core/install.sh /usr/local
bats tests/bats/
```

______________________________________________________________________

## Layer 2 — End-to-end pipeline integration test (`tests/integration/`)

**Runs in:** the CI runner (ubuntu-latest), no containers
**Speed:** ~3 minutes (real CPAN downloads + compilation)
**CI job:** `integration` (every push and PR)

Exercises the full `carton install → carton bundle → cpm install → module load` pipeline with real modules and real network access. Mirrors the production build pipeline steps exactly, including the `rm cpanfile.snapshot` before `cpm install` (the invariant documented in the Containerfile `dev` stage).

### Test modules

| Module        | Type                 | Why included                                                               |
| ------------- | -------------------- | -------------------------------------------------------------------------- |
| `Try::Tiny`   | Pure Perl, zero deps | Baseline smoke — if this fails, Carton itself is broken                    |
| `Moo`         | Pure Perl, dep graph | Exercises transitive dep resolution (Role::Tiny, Sub::Quote)               |
| `JSON::XS`    | XS, no system lib    | Tests C compilation without requiring any OS package                       |
| `DBD::SQLite` | XS + libsqlite3      | Tests system library detection and linking (representative of DBD::Oracle) |

### Pinned versions

`cpanfile.snapshot` pins:

- `Try::Tiny` at **0.30** (current: 0.32)
- `DBD::SQLite` at **1.74** (current: 1.78)

This ensures the `carton update` test is non-trivial: it must actually move Try::Tiny forward, and must leave DBD::SQLite at 1.74 (even though a newer version is available).

### CI job steps

1. Install cpanm, Carton, cpm via `cpanm -l ~/perl5`
1. `carton install` — downloads snapshot-pinned versions from CPAN
1. `carton bundle` — builds offline `vendor/cache` mirror
1. `tar czf /tmp/cpan-bundle.tar.gz` — creates bundle (mirrors `deps.sh`)
1. Extract to fresh dir, `rm cpanfile.snapshot`, `cpm install --resolver 02packages,file://vendor/cache` — offline install (mirrors the `dev` Containerfile stage)
1. Module load verification (`test-load.pl`)
1. `carton update Try::Tiny` with before/after assertions:
   - Try::Tiny snapshot pathname **must change** (non-trivial update)
   - DBD::SQLite and DBI pathnames **must not change** (scoped update)
1. Re-bundle + re-install from updated snapshot
1. Module load with version assertion (`test-load-updated.pl` checks `$Try::Tiny::VERSION gt '0.30'`)

### Running locally

Requires internet access and `libsqlite3-dev` (or equivalent):

```bash
cd tests/integration

# One-time: install Carton and cpm
curl -fsSL https://cpanmin.us | perl - -l ~/perl5 --notest Carton App::cpm
export PATH=~/perl5/bin:$PATH PERL5LIB=~/perl5/lib/perl5

# Run the pipeline
carton install
carton bundle
tar czf /tmp/cpan-bundle.tar.gz ./vendor cpanfile cpanfile.snapshot

mkdir -p /tmp/work /tmp/perl-install
tar xzf /tmp/cpan-bundle.tar.gz -C /tmp/work
rm /tmp/work/cpanfile.snapshot
cd /tmp/work && cpm install -L /tmp/perl-install \
  --resolver "02packages,file://$PWD/vendor/cache"

PERL5LIB=/tmp/perl-install/lib/perl5 perl /path/to/tests/integration/test-load.pl
```

### Updating the pinned snapshot

If you need to update the test snapshot (e.g., a pinned module's old tarball disappears from CPAN):

```bash
cd tests/integration
rm cpanfile.snapshot

# Run in a container with the right Perl and build tools, then copy out the snapshot
# (use perl:5.38-slim + libsqlite3-dev to match the CI runner)
```

______________________________________________________________________

## Layer 3 — Container module tests (`tests/` Perl scripts)

**Runs in:** inside built container images (`myapp:dev`)
**Speed:** smoke test ~5 sec; full suites ~5–10 min
**Requires:** `make dev` to have run first
**Run with:** `make test-load-dev`, `make test-full`

### Quick smoke test

Loads every module from `cpanfile` in the `dev` container and reports which ones fail:

```bash
make test-load-dev       # dev image
make test-load-runtime   # runtime image
```

Uses `tests/module-load-test.pl`. Only runs on `dev` (runtime lacks build tools needed for testing).

### Full CPAN test suites

Runs `cpanm --test-only --verbose` for each module inside the `dev` container:

```bash
make test-full                  # all modules, parallel, ~5–10 min
make test-full MODULE=DBI       # single module, always generates detail log
```

Reports saved to `test-reports/` (gitignored):

- **Summary**: pass/fail/skip counts per module
- **Detail logs**: full output for failed modules only (single-module run always generates one)

### Test configuration

Control per-module behaviour in `tests/test-config.conf`:

```ini
[ModuleName]
skip_load = yes|no          # skip in smoke test
skip_test = yes|no          # skip in full suites
reason = text               # shown in report
env.VAR_NAME = value        # set before testing
test_command = command      # override cpanm invocation
```

Examples:

```ini
[Devel::CheckLib]
skip_load = yes
skip_test = yes
reason = Build-time only dependency

[DBD::Oracle]
env.ORACLE_HOME = /opt/oracle/instantclient
env.LD_LIBRARY_PATH = /opt/oracle/instantclient
reason = Requires Oracle environment

[Problem::Module]
test_command = cpanm --test-only --force Problem::Module
reason = Flaky tests, module itself works
```

______________________________________________________________________

## Layer 4 — End-to-end container build (`tests/container-build/`)

**Runs in:** ubuntu-latest with podman installed
**Speed:** ~10-16 minutes (perl compile dominates; artifacts/ is cached across CI runs)
**Run with:** `make test-container-build`
**CI job:** `container-build` (every push and PR)

Builds the full production 5-stage `Containerfile` (perl-src → base → dev-tools → dev → runtime) plus `Containerfile.deps` against a curated ~11-module cpanfile chosen to exercise every real build-mechanism case (pure Perl, XS-no-syslib, XS-with-syslib for libsqlite3/mariadb-connector-c/libpq/libxml2/libpng+libjpeg+freetype+gd, DBI, DBD::Oracle). Not a subset of production — each module earns its slot by covering something the others don't.

`scripts/fetch-artifacts.sh` populates `artifacts/` with the pinned Perl source, cpanm fatpack, cpm fatpack, and Oracle Instant Client (basiclite + SDK) — all from public URLs with sha256 verification. Oracle is licensed for use but not redistribution.

`tests/container-build/setup.sh` assembles a `$(mktemp -d)` workspace with:

- symlinks to the real `Containerfile`, `Containerfile.deps`, `Makefile`, `scripts/`, `lib-packages.conf`
- `artifacts/` and `certs/` staged as **real** directories, not symlinks — podman's `COPY` instruction won't follow a symlink pointing outside the build context, which both `Containerfile` (`COPY certs/`, `COPY artifacts/...`) rely on
- copies of the test-specific `cpanfile`, `app/app.pl`, `test-load.pl`
- an empty `cpanfile.snapshot` placeholder (Carton regenerates it fresh inside `Containerfile.deps` on first `make bundle`)

The CI job then runs `make bundle && make all && make test-load-dev && make test-load-runtime` inside that workspace, followed by invariant checks (no build tools in runtime, non-root uid 1001, bundle-hash label matches snapshot hash). Nothing in the real project root is touched.

See `tests/container-build/README.md` for the per-module coverage rationale.

______________________________________________________________________

## CI overview

```
.github/workflows/test.yml
├── lint job             — hadolint (both Containerfiles) + shellcheck (scripts/*.sh)
├── bats job             — Layer 1, ~10 sec, no external deps
├── integration job      — Layer 2, ~3 min, host-side carton→cpm pipeline (4 modules)
└── container-build job  — Layer 4, ~10-16 min, full Containerfile build (11 modules, real Oracle)
```

Layer 3 (container tests against the full ~700-module production `cpanfile.snapshot`, not the curated Layer 4 subset) is not wired into public CI — it needs a corresponding production bundle. Run it locally (`make test-load-dev`, `make test-full`) against a real production build when validating one.
