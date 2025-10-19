# Test Suite Documentation

## Overview

This directory contains test configuration and scripts for validating Perl modules in the container images.

## Files

### Configuration

- **test-config.conf** - Module test configuration (skip rules, env vars, custom commands)
- **TestConfig.pm** - Perl module for parsing test-config.conf

### Test Scripts

- **module-load-test.pl** - Quick smoke test: loads each module to verify it's available
- **test-suite-runner.pl** - Full test: runs CPAN test suites for all modules

## test-config.conf Format

```ini
[ModuleName]
skip_load = yes|no          # Skip in quick smoke test
skip_test = yes|no          # Skip in full CPAN test suite
reason = text               # Why skipping (shows in reports)
env.VAR_NAME = value        # Set environment variable before testing
test_command = command      # Custom test command (overrides default)
```

### Examples

Skip a build-time dependency:
```ini
[Devel::CheckLib]
skip_load = yes
skip_test = yes
reason = Build-time only dependency
```

Set environment variables for a module:
```ini
[DBD::Oracle]
env.ORACLE_HOME = /opt/oracle/instantclient
env.LD_LIBRARY_PATH = /opt/oracle/instantclient
reason = Requires Oracle environment
```

Use custom test command:
```ini
[Problem::Module]
test_command = cpanm --test-only --force Problem::Module
reason = Some tests are flaky
```

## Usage

Tests are run via Makefile targets:

```bash
# Quick smoke tests (load modules only)
make test-dev
make test-runtime

# Full CPAN test suites (run all module tests)
make test-full-dev
make test-full-runtime

# Test a single module (useful for debugging)
make test-full-dev MODULE=DBI
make test-full-runtime MODULE=DBD::Oracle
```

### Single Module Testing

When debugging a specific module's test failures, you can run tests for just that module:

```bash
make test-full-dev MODULE=DBI
```

This will:
- Only test the specified module (DBI in this example)
- Run much faster than testing all modules
- Generate a report named with the module name (e.g., `dev-DBI-20250119-123456-summary.txt`)
- Create detail directory with individual log files for each failed module
- Exit with an error if the module name is not found in cpanfile

Module names must match exactly as they appear in the cpanfile (case-sensitive, including `::` for namespaced modules).

## Reports

Full test reports are saved to `test-reports/` with timestamps.

- **Summary reports**: Pass/fail/skip counts for all tested modules (single .txt file)
  - Example: `dev-20251019-090554-summary.txt`
- **Detail reports**: One file per failed module in a `*-details/` directory
  - Each failed module gets its own `.log` file (e.g., `DBD-mysql.log`)
  - Only failed tests generate detail files (passing tests don't)
  - Makes it easy to focus on specific failures
  - Example: `dev-20251019-090554-details/DBD-mysql.log`
