#!/usr/bin/env perl

# test-single-module.pl - Worker script test execution
#
# Purpose: Tests a single module and writes result to temp file
# Usage:   test-single-module.pl <module-name>
# Output:  Writes status to /tmp/test-result-$$.txt
#          Writes detailed log to /tmp/test-details/<module-safe>.log

use strict;
use warnings;
use feature 'say';
use FindBin qw($RealBin);
use lib $RealBin;

use TestConfig;

# Get module name from command line
my $module = $ARGV[0] or die "Usage: $0 <module-name>\n";

my $config_file = '/tmp/test-config.conf';
my $detail_dir = '/tmp/test-details';
my $result_file = "/tmp/test-result-$$.txt";

# Create detail directory if needed
mkdir $detail_dir unless -d $detail_dir;

my $config = TestConfig->new($config_file);

# Get custom environment variables for this module
my $env_vars = $config->get_env($module);
my $env_string = '';
if (keys %$env_vars) {
    $env_string = join(' ', map { "$_='$env_vars->{$_}'" } keys %$env_vars) . ' ';
}

# Get custom test command or use default
my $test_cmd = $config->get_test_command($module);
if ($test_cmd) {
    $test_cmd = "${env_string}${test_cmd}";
} else {
    $test_cmd = "${env_string}cpanm --test-only --verbose $module";
}

# Run the test
my $output = `$test_cmd 2>&1`;
my $exit_code = $? >> 8;

# Determine status
my $status;
if ($exit_code == 0 && $output =~ /All tests successful|Result: PASS|Successfully tested/) {
    $status = 'PASS';
} elsif ($output =~ /is up to date|already installed/) {
    $status = 'SKIP';
} else {
    $status = 'FAIL';
}

# Write result to temp file for parent process
open my $rfh, '>', $result_file or die "Cannot open $result_file: $!";
say $rfh $status;
close $rfh;

# Write detailed log
my $module_safe = $module;
$module_safe =~ s/::/-/g;
my $log_file = "$detail_dir/$module_safe.log";

open my $lfh, '>', $log_file or die "Cannot open $log_file: $!";

say $lfh '=' x 70;
say $lfh "$status: $module";
say $lfh '=' x 70;
say $lfh "Exit code: $exit_code";

if (keys %$env_vars) {
    say $lfh "Environment: " . join(', ', map { "$_=$env_vars->{$_}" } keys %$env_vars);
}

if ($config->get_test_command($module)) {
    say $lfh "Custom command: " . $config->get_test_command($module);
} else {
    say $lfh "Command: cpanm --test-only --verbose $module";
}

say $lfh '';
say $lfh '-' x 70;
say $lfh 'Full test output:';
say $lfh '-' x 70;
say $lfh $output;
say $lfh '=' x 70;

close $lfh;

# Exit with appropriate code
exit($status eq 'PASS' || $status eq 'SKIP' ? 0 : 1);
