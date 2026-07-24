# Troubleshooting

## Oracle Instant Client download 404s (or: I don't use Oracle)

```
==> Fetching instantclient-basiclite... 
curl: (22) The requested URL returned error: 404
```

**Cause**: Oracle delists older Instant Client releases, so the pinned version
eventually stops being downloadable. `make bundle`/`dev`/`runtime` all require
both Instant Client zips (`check-artifacts` in the `Makefile`), so this blocks
the whole build — including for people who don't use Oracle at all.

**Solution (delisting)**: Pick a currently-available version from Oracle's
[Instant Client download page](https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html)
and update `ORACLE_IC_VERSION` (and, if the path changed, `ORACLE_IC_SUBDIR`)
near the top of `scripts/fetch-artifacts.sh`, then re-run `make fetch-artifacts`.
The first fetch of a new version is trust-on-first-use — it gets pinned into
`artifacts.sha256` and verified on every run thereafter.

**If you don't use Oracle**: there is currently no opt-out — the Containerfile
`base`/`dev-tools` stages and `check-artifacts` assume Oracle is present.
Making Oracle optional (`WITH_ORACLE`, default off) is tracked as future work;
until then, you must supply both zips to build. If you're only exercising the
fast unit layer, `make test` needs neither Oracle nor a build.

## Bundle not found

```
[MISSING] Bundle missing: bundle-<hash>.tar.gz
```

**Solution**: Run `make bundle` first to generate the CPAN bundle.

## Build fails with missing dependencies

**Solution**: Add the missing `-devel` package to the `dev-tools` stage in `Containerfile`. Because `Containerfile.deps` also `FROM`s `dev-tools`, the fix applies to both the image build and the bundle-regeneration path automatically.

## Test failures

```
[FAIL] Some::Module - Can't locate Some/Module.pm in @INC
```

**Causes**:

- Module failed to install during build
- Missing system library dependency
- Module requires compilation and dev image lacks build tools

**Solution**:

- Check build logs for installation errors
- Add missing system libraries to `lib-packages.conf`: devel packages (column 2) apply to the `dev-tools` stage; if it's a shared runtime dependency, add it to column 1 so `base` — and therefore `runtime` — picks it up too
- For dev image: ensure bundle includes all dependencies
- Check `test-reports/*-latest-detail.txt` for full error output
- Debugging a failing `make test-full` run specifically: check the summary for the failed module list, review `test-reports/full-TIMESTAMP-details/` (only failed tests are logged there), re-run just that module with `make test-full MODULE=FailedModule`, and configure known-problematic modules in `tests/test-config.conf` (`skip_test`, `env.*`, `test_command` — see `tests/README.md` for the full format)

## Permission issues

**Cause**: Runtime image runs as non-root user `appuser` (UID 1001)

**Solution**: Ensure application files and directories have appropriate permissions, or adjust the USER directive in Containerfile

## Image doesn't exist when testing

```
ERROR: Image myapp:dev does not exist
```

**Solution**: Build the image first: `make dev` or `make runtime`

## Image has no bundle hash label

```
[WARNING] myapp:dev (no bundle hash label)
```

**Cause**: Image was built before bundle hash labels were added

**Solution**: Rebuild the image: `make dev` or `make runtime`
