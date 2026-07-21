# Perl Multi-Stage Container Build with Carton

Complete multi-stage Podman/Docker workflow for building Perl applications with reproducible, offline-capable dependency management using Carton.

## What this repo is for

Two jobs, sharing one bundle-generation engine:

1. **CPAN dependency management for the legacy VM fleet.** `cpanfile` + `cpanfile.snapshot` + `make bundle` produce a hash-pinned, offline CPAN mirror. That bundle is installed onto perlbrew-managed VMs — see [`docs/vm-deployment.md`](docs/vm-deployment.md) for the install procedure, version-compatibility gate, and rollback approach.
1. **The future containerized system**, covered by the rest of this document: the same bundle consumed by the `dev` stage below, running either as one container "as is" or eventually split into multiple components, each with its own cpanfile.

Everything from here down — the Containerfile stages, `make dev`/`make runtime`, the container test layers — is purpose 2. If you're deploying to a VM instead of a container, start with `docs/vm-deployment.md`; `make bundle` is the only target from this README you still need.

## Key Features

- **Offline CPAN installs**: once a bundle is generated, Perl module installation requires no internet access. Note: the OS-level package installs (`microdnf`) in the `perl-src`, `base`, and `dev` stages still require network access or a local package mirror unless those are also vendored.
- **Deterministic Dependencies**: Bundle hash based on `cpanfile.snapshot` ensures reproducibility
- **Version Traceability**: Images tagged with bundle hash for full dependency lineage
- **Minimal Runtime**: Production image contains no compilers, build tools, or Carton
- **Multi-RHEL targeting**: Build for any UBI version (8, 9, 10) via a single `UBI_IMAGE` build arg — UBI9 by default
- **Comprehensive Testing**: bats unit tests, end-to-end Carton→cpm integration tests, and container-level module smoke tests

## Quick Start

### 1. Check Status

```bash
make status
```

Shows current state of dependencies, bundles, and images with color-coded output.

### 2. Generate CPAN Bundle

```bash
make bundle
```

Computes a hash from `cpanfile.snapshot`, builds the `myapp:base` image and the `carton-runner` helper (from `Containerfile.deps`), generates a CPAN mirror bundle, and saves it as `bundles/bundle-<hash>.tar.gz`.

### 3. Build Images

```bash
make all       # Build both dev and runtime images
# or individually:
make dev       # Build development image only
make runtime   # Build runtime image only
```

Images are tagged with bundle hash labels:

- `myapp:dev-<hash>` and `myapp:dev`
- `myapp:runtime-<hash>` and `myapp:runtime`

To target a different RHEL/UBI version, see [`docs/architecture.md`](docs/architecture.md#targeting-different-rhelubi-versions):

```bash
make all UBI_IMAGE=registry.access.redhat.com/ubi8/ubi-minimal:8.10
```

### 4. Test Libraries

```bash
# Quick smoke test (verify all modules can be loaded)
make test-load-dev       # Test dev image
make test-load-runtime   # Test runtime image

# Full CPAN test suites (dev only - slow but thorough)
make test-full                    # Run all test suites
make test-full MODULE=DBI         # Test single module
```

**Note:**

- Full test suites only run on `dev` image (runtime lacks build tools)
- Module loading tests work on both dev and runtime

### 5. Run Application

```bash
podman run --rm myapp:dev       # Development image
podman run --rm myapp:runtime   # Production image
```

## Makefile Targets

```bash
make help                     # Show available targets with descriptions
make status                   # Check status of bundles and images
make fetch-artifacts          # Download perl, cpanm, cpm, and Oracle Instant Client into artifacts/
make base                     # Build the shared base stage (myapp:base)
make bundle                   # Generate CPAN bundle from cpanfile.snapshot
make update MODULE=name       # Update one module in cpanfile.snapshot
make update-all               # Update all modules in cpanfile.snapshot
make dev                      # Build development image (myapp:dev)
make runtime                  # Build runtime image (myapp:runtime)
make all                      # Generate bundle and build both images
make test-load-dev            # Quick: verify all modules load in dev image
make test-load-runtime        # Quick: verify all modules load in runtime image
make test-full                # Full: run CPAN test suites (parallel, all CPUs)
make test-full MODULE=name    # Full: run CPAN test suite for single module
make test-container-build     # End-to-end pipeline test against curated ~11-module cpanfile
make clean                    # Remove images (bundles are preserved)
```

All build targets accept an optional `UBI_IMAGE` variable to override the base OS:

```bash
make bundle UBI_IMAGE=registry.access.redhat.com/ubi8/ubi-minimal:8.10
make all    UBI_IMAGE=registry.access.redhat.com/ubi8/ubi-minimal:8.10
```

They also accept an optional `IMAGE_NAME` variable (default `myapp`) to override the image repository name — useful once purpose 2 splits into multiple components, each wanting its own image identity from the same build machinery:

```bash
make all IMAGE_NAME=billing-service
```

### Checking Status

The `status` target provides a comprehensive view with color-coded output:

```bash
make status
```

Shows:

- Current cpanfile.snapshot hash and git status
- Bundle existence and version alignment
- Image status with bundle hash labels
- Recommended commands to sync everything

## Common Workflows

### First-time setup

Populate `artifacts/` from public sources with:

```bash
make fetch-artifacts
```

This downloads (and hash-verifies) the pinned Perl source, `cpanm`, `cpm`, and Oracle Instant Client (basiclite + SDK). Idempotent — subsequent runs skip anything already present with the correct sha256. Oracle Instant Client is licensed for use but **not for redistribution** — do not publish images or artifacts containing it.

Then build:

```bash
make bundle    # Build base + carton-runner images, resolve all CPAN deps, create bundle
make all       # Build dev + runtime images from the bundle
make status    # Verify everything is aligned
```

### Add a new module

1. Add `requires 'Module::Name';` to `cpanfile`
1. Run `make bundle` — Carton resolves and locks the new module and its deps
1. Run `make all` to rebuild images
1. Quick test: `make test-load-dev`

The new bundle will have a different hash (the snapshot changed), ensuring full traceability.

### Update a single module to latest

Bumps one module's entry in `cpanfile.snapshot` to the latest version satisfying `cpanfile`, leaving all other locked versions unchanged:

```bash
make update MODULE=DBI    # (or: ./scripts/deps.sh update --module DBI)
make bundle               # Rebuild bundle from updated snapshot
make all                  # Rebuild images
```

`carton update MODULE` ignores the current snapshot entry for that module, goes to CPAN, and fetches the latest version satisfying `cpanfile`'s constraints (no constraint → absolute latest). Only that module's snapshot entry is rewritten; everything else stays locked.

### Update all modules to latest

```bash
make update-all    # (or: ./scripts/deps.sh update --all)
make bundle
make all
```

### Pin a module to a specific version

Carton doesn't support version pinning via CLI — edit `cpanfile` before updating:

```perl
requires 'DBI', '== 1.643';       # exact version
requires 'DBI', '>= 1.643';       # minimum version
requires 'DBI', '>= 1.640, < 2.0'; # version range
```

Then update the snapshot and rebuild:

```bash
./scripts/deps.sh update --module DBI
make bundle && make all
```

### Changing Perl Version

`cpanfile.snapshot` and `ARG PERL_VERSION` are a pair, not independent — see [`docs/architecture.md#changing-perl-version`](docs/architecture.md#changing-perl-version) for the full procedure (re-resolving the snapshot is the step it's easy to skip) and why the pairing matters.

### Debugging test failures

See [`docs/troubleshooting.md`](docs/troubleshooting.md) for build/test failure modes, or [`tests/README.md`](tests/README.md) for the full testing-system reference (per-module skip/env/custom-command config lives there).

## Testing

The repo has four testing layers (shell unit tests, an end-to-end Carton→cpm integration test, container module smoke tests, and a full container-build pipeline test) plus a `lint` CI job. Full reference, including the `tests/test-config.conf` format: [`tests/README.md`](tests/README.md).

```bash
bats tests/bats/       # fastest layer: shell-level unit tests, no containers, typically <10 seconds
```

## Architecture

Five-stage Containerfile build (`perl-src → base → dev-tools → dev`, with `runtime` branching from `base`), plus a separate `Containerfile.deps` for bundle regeneration that reuses the same `dev-tools` toolchain layer. Full stage-by-stage breakdown, both Mermaid diagrams, RHEL/UBI targeting, and the Perl-version-upgrade procedure: [`docs/architecture.md`](docs/architecture.md).

## Project Structure

```
.
├── Containerfile              # Main 5-stage build (perl-src → base → dev-tools → dev → runtime)
├── Containerfile.deps         # Bundle regeneration (invoked by make bundle/update)
├── Makefile                   # Build automation
├── cpanfile                   # Perl dependencies
├── cpanfile.snapshot          # Locked dependency versions
├── app/
│   └── app.pl                 # Application code (placeholder — see "What this repo is for")
├── artifacts/                 # Pre-downloaded build artifacts (gitignored)
│   ├── perl-5.28.1.tar.gz
│   ├── cpanm                  # cpanm fatpack
│   ├── cpm                    # cpm fatpack
│   └── instantclient-*.zip    # Oracle Instant Client
├── artifacts.sha256           # Hash lockfile for artifacts/ (see scripts/fetch-artifacts.sh)
├── docs/
│   ├── architecture.md        # Stage-by-stage breakdown, diagrams, RHEL/UBI targeting
│   ├── troubleshooting.md     # Build/test failure modes
│   └── vm-deployment.md       # Installing a bundle onto a perlbrew-managed legacy VM
├── scripts/                   # Build and management scripts
│   ├── deps.sh                # CPAN dependency manager (bundle + snapshot update)
│   ├── build-image.sh         # Container image builder
│   ├── status.sh              # Bundle and image status checker
│   ├── fetch-artifacts.sh     # Populates artifacts/ with hash-pinned downloads
│   ├── test-load-modules.sh   # Quick module smoke test runner
│   └── test-run-suites.sh     # Full CPAN test suite runner
├── tests/
│   ├── bats/                  # Shell-level unit tests (bats-core)
│   │   ├── mocks/              # Mock podman/curl that log invocations
│   │   ├── deps.bats
│   │   ├── build-image.bats
│   │   ├── status.bats
│   │   ├── fetch-artifacts.bats
│   │   ├── container-build-setup.bats
│   │   └── project-structure.bats
│   ├── integration/            # End-to-end Carton→cpm pipeline test
│   ├── container-build/        # Curated ~11-module end-to-end Containerfile build test
│   ├── test-config.conf        # Per-module container test configuration
│   ├── TestConfig.pm           # Configuration parser
│   ├── module-load-test.pl    # Container smoke test script
│   ├── test-suite-runner.pl   # Full CPAN test suite runner
│   └── README.md              # Test system documentation
├── .github/workflows/test.yml # CI: lint + bats + integration + container-build jobs
├── bundles/                    # Generated CPAN bundles (gitignored)
│   ├── bundle-<hash>.tar.gz
│   ├── bundle-<hash>.build-info  # PERL_VERSION + UBI_IMAGE this bundle was built against
│   └── bundle-latest.tar.gz / bundle-latest.build-info  # symlinks to the above
└── test-reports/               # Container test reports (gitignored)
```

## Requirements

- Podman or Docker
- Bash 4+
- Basic UNIX utilities (sha256sum, tar, readlink)

## Troubleshooting

Common failure modes (missing bundle, build fails with missing dependencies, test failures, permission issues, missing bundle-hash label) and their fixes: [`docs/troubleshooting.md`](docs/troubleshooting.md).

## License

This project structure is provided as-is for demonstration purposes.
