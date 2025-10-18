# Perl Multi-Stage Container Build with Carton

Complete multi-stage Podman/Docker workflow for building Perl applications with reproducible, offline-capable dependency management using Carton.

## Key Features

- **Fully Offline Builds**: Once bundle is generated, builds work without internet access
- **Deterministic Dependencies**: Bundle hash based on `cpanfile.snapshot` ensures reproducibility
- **Version Traceability**: Images tagged with bundle hash for full dependency lineage
- **Minimal Runtime**: Production image contains no compilers, build tools, or Carton
- **Library Testing**: Validate module loading in built images

## Quick Start

### 1. Generate CPAN Bundle

```bash
make bundle
```

This computes a hash from `cpanfile.snapshot`, builds the carton-runner stage, generates a CPAN mirror bundle, and saves it as `bundles/bundle-<hash>.tar.gz`.

### 2. Build Images

```bash
make all       # Build both dev and runtime images
# or individually:
make dev       # Build development image only
make runtime   # Build runtime image only
```

Images are tagged as:
- `myapp:dev-<hash>` and `myapp:dev`
- `myapp:runtime-<hash>` and `myapp:runtime`

### 3. Test Libraries (Optional)

```bash
make test-dev      # Verify Perl modules load in dev image
make test-runtime  # Verify Perl modules load in runtime image
```

### 4. Run Application

```bash
podman run --rm myapp:dev       # Development image
podman run --rm myapp:runtime   # Production image
```

## Makefile Targets

```bash
make help        # Show available targets with descriptions
make status      # Check status of bundles and images
make bundle      # Generate CPAN bundle from cpanfile.snapshot
make dev         # Build development image (myapp:dev)
make runtime     # Build runtime image (myapp:runtime)
make all         # Generate bundle and build both images
make test-dev    # Test Perl library loading in dev image
make test-runtime # Test Perl library loading in runtime image
make clean       # Remove images (bundles are preserved)
```

### Checking Status

The `status` target provides a comprehensive view:

```bash
make status
```

Shows:
- Current cpanfile.snapshot hash
- Whether bundle exists for this snapshot
- Image status (dev/runtime) and version alignment
- Recommended commands to sync everything

## Architecture

This project implements a five-stage build process:

1. **perl-src**: Compiles Perl from source with thread support
2. **perl-buildbase**: Base image with compiled Perl and all build dependencies (gcc, make, *-devel packages)
3. **carton-runner**: Isolated stage that generates CPAN dependency bundles (Carton only exists here)
4. **perl-dev**: Development image with offline dependency installation and build tools
5. **runtime**: Minimal production image with only Perl and dependencies, no build tools

## Project Structure

```
.
├── Containerfile              # Multi-stage build definition
├── Makefile                   # Build automation
├── cpanfile                   # Perl dependencies
├── cpanfile.snapshot          # Locked dependency versions
├── app/
│   └── app.pl                 # Application code
├── artifacts/                 # Pre-downloaded build artifacts
│   ├── perl-5.28.1.tar.gz
│   ├── cpanm                  # cpanm fatpack
│   ├── cpm                    # cpm fatpack
│   └── instantclient-*.zip    # Oracle Instant Client
├── scripts/
│   ├── manage-perl-deps.sh    # Dependency management (bundle/update)
│   ├── build-images.sh        # Image build script
│   ├── check-status.sh        # Status checking
│   ├── test-image.sh          # Test library loading in images
│   └── perl-lib-test.pl       # Library test script
└── bundles/
    ├── .gitkeep
    ├── bundle-<hash>.tar.gz   # Generated bundles (gitignored)
    └── bundle-latest.tar.gz   # Symlink to latest bundle
```

## Daily Workflow

### Adding New Dependencies

1. Edit `cpanfile` to add new modules
2. Regenerate bundle: `make bundle`
3. Rebuild images: `make all`
4. Test: `make test-dev` or `make test-runtime`

The new bundle will have a different hash, ensuring full traceability.

### Updating Existing Dependencies

Use the `manage-perl-deps.sh` script:

```bash
# Update all dependencies to latest versions
./scripts/manage-perl-deps.sh update --all

# Update specific module to latest version
./scripts/manage-perl-deps.sh update --module DBI

# Update specific module to specific version
./scripts/manage-perl-deps.sh update --module DBI --version 1.643
```

After updating, regenerate the bundle:
```bash
make bundle
```

### Testing Library Installation

The test script (`perl-lib-test.pl`) validates that all modules from `cpanfile` can be loaded:

```bash
make test-dev      # Test dev image
make test-runtime  # Test runtime image
```

Test output shows:
- `[ OK ]` - Module loaded successfully
- `[FAIL]` - Module failed to load (with error details)
- `[SKIP]` - Module in blacklist (see scripts/perl-lib-test.pl:11-14)

The runtime image includes this test during build (Containerfile:155-157). The make targets allow re-testing after builds complete.

### Changing Perl Version

1. Download new Perl source tarball to `artifacts/`
2. Edit `Containerfile` and change: `ARG PERL_VERSION=5.38.2`
3. Rebuild: `make bundle && make all`

## Technical Details

### Bundle Management

- Bundles are content-addressed by hashing `cpanfile.snapshot`
- Cached bundles are reused if snapshot hasn't changed
- Bundle hash tags images for full dependency lineage tracing
- Bundles contain: `vendor/` directory, `cpanfile`, and `cpanfile.snapshot`

### Offline Installation

The dev stage uses `cpm` with a local file resolver:

```bash
cpm install --resolver 02packages,file:///build/vendor/cache
```

This ensures builds work completely offline once the bundle is generated.

### Runtime Image

- Based on `ubi9-minimal` for smallest footprint
- Includes only runtime system libraries (no gcc, make, etc.)
- Runs as non-root user `appuser` (UID 1001)
- Contains only Perl installation and application code

## Requirements

- Podman or Docker
- Bash 4+
- Basic UNIX utilities (sha256sum, tar, readlink)

## Troubleshooting

### Bundle not found

```
ERROR: Bundle not found at bundles/bundle-latest.tar.gz
```

**Solution**: Run `make bundle` first to generate the CPAN bundle.

### Build fails with missing dependencies

**Solution**: Ensure all XS module build dependencies are installed in the `perl-buildbase` stage (Containerfile:48-59).

### Test failures

```
[FAIL] Some::Module - Can't locate Some/Module.pm in @INC
```

**Causes**:
- Module failed to install during build
- Missing system library dependency
- Module requires compilation and dev image lacks build tools

**Solution**:
- Check build logs for installation errors
- Add missing system libraries to `perl-buildbase` or `runtime` stages
- For dev image: ensure bundle includes all dependencies

### Permission issues

**Cause**: Runtime image runs as non-root user `appuser` (UID 1001)

**Solution**: Ensure application files and directories have appropriate permissions, or adjust the USER directive in Containerfile:176

### Image doesn't exist when testing

```
ERROR: Image myapp:dev does not exist
```

**Solution**: Build the image first: `make dev` or `make runtime`

## Advanced Customization

### Change Base Images

Edit `FROM` directives in `Containerfile`:
- Line 10: perl-src base (currently ubi8-minimal)
- Line 42: perl-buildbase (currently ubi9)
- Line 136: runtime (currently ubi9-minimal)

### Adjust Build Dependencies

Modify the `dnf install` command in `perl-buildbase` stage (Containerfile:48-59) to add/remove build dependencies.

### Configure Perl Compilation

Edit `./Configure` flags in `perl-src` stage (Containerfile:30-33) for different Perl options:
- `-Dusethreads` - Enable thread support
- `-Duseshrplib` - Build shared Perl library
- `-Dprefix=/opt/perl` - Installation directory

### Customize Test Blacklist

Edit `scripts/perl-lib-test.pl` lines 11-14 to skip modules that shouldn't be tested:

```perl
my %blacklist = map { $_ => 1 } qw(
    Devel::CheckLib
    Mixin::Linewise
);
```

## License

This project structure is provided as-is for demonstration purposes.
