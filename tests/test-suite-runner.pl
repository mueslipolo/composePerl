#!/usr/bin/env perl

# test-suite-runner.pl - Full CPAN test suite runner
#
# Purpose: Runs complete test suites for all modules using cpanm --test-only
# Usage:   test-suite-runner.pl [module-name]
#          Run via 'make test-full-dev' or 'make test-full-runtime'
#          Optional: specify module name to test only that module
# Config:  Uses test-config.conf for:
#          - skip_test: Skip module's test suite
#          - env.*: Set environment variables before testing
#          - test_command: Override default cpanm test command
# Output:  Summary to stdout, detailed failure logs to /tmp/test-details/*.log

use strict;
use warnings;
use feature 'say';
use FindBin qw($RealBin);
use lib $RealBin;

use TestConfig;

my $cpanfile = '/tmp/cpanfile';
my $config_file = '/tmp/test-config.conf';
my $detail_dir = '/tmp/test-details';

# Create detail directory
mkdir $detail_dir unless -d $detail_dir;

# Check if single module specified
my $single_module = $ARGV[0];

my $config = TestConfig->new($config_file);

# Parse cpanfile
open my $fh, '<', $cpanfile or die "Cannot open $cpanfile: $!";
my @modules = map { /requires\s+"([^"]+)"/ ? $1 : () } grep { !/^\s*#/ } <$fh>;
close $fh;

# Filter to single module if specified
if ($single_module) {
    my @found = grep { $_ eq $single_module } @modules;
    if (@found) {
        @modules = @found;
    } else {
        die "ERROR: Module '$single_module' not found in cpanfile\n";
    }
}

# Print header
say '=' x 70;
say 'PERL MODULE FULL TEST SUITE';
say 'Started: ' . scalar(localtime);
say '=' x 70;
say '';
say 'Found ' . scalar(@modules) . ' modules in cpanfile';

my @skip_test_modules = $config->get_all_skip_test();
say 'Skip test configured: ' . scalar(@skip_test_modules) . ' modules';
say '';

# Run tests for each module
my (@ok, @fail, @skipped);
my $total = scalar(@modules);

for my $i (0 .. $#modules) {
    my $module = $modules[$i];
    my $progress = sprintf('[%d/%d]', $i + 1, $total);

    # Check if we should skip this module's tests
    if ($config->should_skip_test($module)) {
        my $reason = $config->get_reason($module);
        push @skipped, { module => $module, reason => $reason };
        say "$progress [SKIP] $module ($reason)";
        next;
    }

    say "$progress [TEST] $module";

    # Get custom environment variables for this module
    my $env_vars = $config->get_env($module);
    my $env_string = '';
    if (keys %$env_vars) {
        my $env_info = join(', ', map { "$_=$env_vars->{$_}" } keys %$env_vars);
        $env_string = join(' ', map { "$_='$env_vars->{$_}'" } keys %$env_vars) . ' ';
        say "        Setting: $env_info";
    }

    # Get custom test command or use default
    my $test_cmd = $config->get_test_command($module);
    if ($test_cmd) {
        say "        Custom command: $test_cmd";
        $test_cmd = "${env_string}${test_cmd}";
    } else {
        $test_cmd = "${env_string}cpanm --test-only --verbose $module";
    }

    # Run the test
    my $output = `$test_cmd 2>&1`;
    my $exit_code = $? >> 8;

    # Categorize result
    if ($exit_code == 0 && $output =~ /All tests successful|Result: PASS|Successfully tested/) {
        push @ok, $module;
        say "$progress [ OK ] $module";
    } elsif ($output =~ /is up to date|already installed/) {
        push @skipped, { module => $module, reason => 'already tested/up to date' };
        say "$progress [SKIP] $module (already tested)";
    } else {
        # FAILURE - Log detailed output to separate file per module
        push @fail, $module;
        say "$progress [FAIL] $module (exit: $exit_code)";

        # Create separate detail file for this failed module
        my $module_safe = $module;
        $module_safe =~ s/::/-/g;  # Replace :: with - for filename
        my $module_detail_file = "$detail_dir/$module_safe.log";

        open my $module_fh, '>', $module_detail_file or die "Cannot open $module_detail_file: $!";

        # Write detailed failure information
        say $module_fh '=' x 70;
        say $module_fh "FAILED: $module";
        say $module_fh '=' x 70;
        say $module_fh "Exit code: $exit_code";

        if (keys %$env_vars) {
            say $module_fh "Environment: " . join(', ', map { "$_=$env_vars->{$_}" } keys %$env_vars);
        }

        if ($config->get_test_command($module)) {
            say $module_fh "Custom command: " . $config->get_test_command($module);
        } else {
            say $module_fh "Command: cpanm --test-only --verbose $module";
        }

        say $module_fh '';
        say $module_fh '-' x 70;
        say $module_fh 'Full test output:';
        say $module_fh '-' x 70;
        say $module_fh $output;
        say $module_fh '=' x 70;

        close $module_fh;

        # Show brief error context on stdout
        my @errors = grep { /FAIL|Error:|not ok|Failed test/ } split /\n/, $output;
        if (@errors) {
            my $end = $#errors < 2 ? $#errors : 2;
            say '        ' . $_ for @errors[0..$end];
        }
    }
}

# Print summary
say '';
say '=' x 70;
say 'TEST SUMMARY';
say '=' x 70;
say 'Finished: ' . scalar(localtime);
say '';
say sprintf('  PASSED : %3d / %d (%.1f%%)',
    scalar(@ok), $total,
    $total ? scalar(@ok)/$total*100 : 0);
say sprintf('  FAILED : %3d / %d (%.1f%%)',
    scalar(@fail), $total,
    $total ? scalar(@fail)/$total*100 : 0);
say sprintf('  SKIPPED: %3d / %d (%.1f%%)',
    scalar(@skipped), $total,
    $total ? scalar(@skipped)/$total*100 : 0);
say '';

# List failed modules
if (@fail) {
    say 'Failed modules:';
    for my $mod (@fail) {
        say "  - $mod";
    }
    say '';
}

# List skipped modules with reasons
if (@skipped) {
    say 'Skipped modules:';
    for my $skip (@skipped) {
        my $module = ref($skip) eq 'HASH' ? $skip->{module} : $skip;
        my $reason = ref($skip) eq 'HASH' ? $skip->{reason} : 'unknown';
        say sprintf('  - %-30s (%s)', $module, $reason);
    }
    say '';
}

say '=' x 70;

if (@fail) {
    say '';
    say "Detailed failure logs in: $detail_dir/";
    say "Files:";
    for my $mod (@fail) {
        my $mod_safe = $mod;
        $mod_safe =~ s/::/-/g;
        say "  - $mod_safe.log";
    }
}

# Exit with appropriate code
exit(scalar(@fail) > 0 ? 1 : 0);
