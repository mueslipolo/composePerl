# Container-build test workspace

An isolated project skeleton for exercising the real production `Containerfile`
end-to-end in CI (and locally) without pulling in the full 700-module
production `cpanfile`.

## What this tests

The full build pipeline as it exists in production:

- `perl-src` stage — compiles Perl from source
- `base` stage — installs runtime libs, extracts Oracle Instant Client
- `dev` stage — installs build tools, extracts Oracle SDK, `cpm install` from bundle
- `runtime` stage — copies modules from `dev`, drops build tools, creates non-root user
- `Containerfile.deps` — `carton install` + `carton bundle` produces the vendor mirror
- `scripts/deps.sh` — bundle regeneration workflow
- `scripts/build-image.sh` — image build with bundle-hash labels

## What's here

| File                | Purpose                                                                                                                                                                                                                                                                                                                             |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cpanfile`          | ~11 modules, each covering a distinct build-mechanism case (see below)                                                                                                                                                                                                                                                              |
| `cpanfile.snapshot` | Not committed. `setup.sh` creates an empty placeholder; carton regenerates on first build                                                                                                                                                                                                                                           |
| `app/app.pl`        | Trivial hello-world app (satisfies the Containerfile's `COPY app/`)                                                                                                                                                                                                                                                                 |
| `test-load.pl`      | Verifies every module in cpanfile loads inside the built image                                                                                                                                                                                                                                                                      |
| `setup.sh`          | Assembles an isolated build workspace in `$(mktemp -d)`: symlinks `Containerfile`/`Containerfile.deps`/`Makefile`/`scripts/`/`lib-packages.conf`, stages `artifacts/` and `certs/` as real directories (podman's `COPY` can't follow a symlink out of the build context), copies the test-specific `cpanfile`/`app/`/`test-load.pl` |

## Module coverage rationale

Not a subset of production — each entry earns its slot by exercising something
none of the others do:

| Module             | Coverage                                                   |
| ------------------ | ---------------------------------------------------------- |
| `Try::Tiny`        | Pure Perl, zero deps — baseline smoke                      |
| `Moo`              | Pure Perl transitive dep graph (Role::Tiny, Sub::Quote)    |
| `JSON::XS`         | XS, no system lib — pure C against libperl                 |
| `Cpanel::JSON::XS` | XS variant, alternate CPAN path                            |
| `DBI`              | DBD family foundation                                      |
| `DBD::SQLite`      | XS + bundles its own SQLite (proves XS compile end-to-end) |
| `DBD::mysql`       | XS + `mariadb-connector-c-devel` linkage                   |
| `DBD::Pg`          | XS + `postgresql-devel` linkage                            |
| `XML::LibXML`      | XS + `libxml2-devel` linkage                               |
| `GD`               | XS + `libpng` + `libjpeg` + `freetype` + `gd`              |
| `DBD::Oracle`      | XS + Oracle SDK — proves the Oracle path works end-to-end  |

If a module is added, it must cover something none of the others do.

## Running it

Prerequisites: `podman` installed, `artifacts/` populated by
`scripts/fetch-artifacts.sh`.

```bash
scripts/fetch-artifacts.sh    # one-time; ~5 min on cold cache
make test-container-build     # ~10-15 min end to end
```

Under the hood:

```bash
WORKDIR="$(bash tests/container-build/setup.sh)"
cd "$WORKDIR"
make bundle          # builds carton-runner, resolves + downloads all modules
make all             # builds base, dev, runtime
make test-load-dev   # loads every cpanfile module inside myapp:dev
make test-load-runtime
```

## Why isolated workspace, not sed-swapping cpanfile

The workspace lives in `$(mktemp -d)` with symlinks to the real
`Containerfile`, `Makefile`, `scripts/`, and `artifacts/`, plus copies of
the test-specific `cpanfile` / `cpanfile.snapshot` / `app/`. This means:

- The real production `cpanfile` is never touched (no `git status` surprises)
- The build exercises the actual production `Containerfile`, not a copy
- Multiple test runs can share the workspace or use fresh ones

`make test-container-build` removes its `$(mktemp -d)` workspace and the
images it built (`base`/`dev-tools`/`carton-runner`/`dev`/`runtime`) when the
run succeeds. On failure it removes the images but leaves the workspace in
place — the failure message prints its path — so it's still there to inspect.
