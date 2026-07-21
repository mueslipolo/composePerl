# Troubleshooting

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
- Add missing system libraries to the `dev` stage; if it's a shared runtime dependency, add it to `base` so `runtime` picks it up too
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
