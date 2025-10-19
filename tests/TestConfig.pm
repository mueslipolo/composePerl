package TestConfig;

# TestConfig.pm - Configuration parser for test-config.conf
#
# Purpose: Parses INI-style configuration file for module test settings
# Methods: should_skip_load(), should_skip_test(), get_reason(),
#          get_env(), get_test_command()
# Format:  See tests/README.md for configuration file format

use strict;
use warnings;

sub new {
    my ($class, $config_file) = @_;

    my $self = {
        config_file => $config_file,
        modules => {},
    };

    bless $self, $class;
    $self->_parse() if -f $config_file;

    return $self;
}

sub _parse {
    my ($self) = @_;

    open my $fh, '<', $self->{config_file}
        or die "Cannot open $self->{config_file}: $!";

    my $current_module;

    while (<$fh>) {
        chomp;
        s/^\s+|\s+$//g;  # Trim whitespace

        # Skip empty lines and comments
        next if /^$/ || /^#/;

        # Module section header: [ModuleName]
        if (/^\[(.+)\]$/) {
            $current_module = $1;
            $self->{modules}{$current_module} = {
                skip_load => 0,
                skip_test => 0,
                reason => '',
                env => {},
                test_command => '',
            };
            next;
        }

        # Configuration directives
        next unless $current_module;

        if (/^skip_load\s*=\s*(.+)$/) {
            $self->{modules}{$current_module}{skip_load} = ($1 =~ /^(yes|true|1)$/i) ? 1 : 0;
        }
        elsif (/^skip_test\s*=\s*(.+)$/) {
            $self->{modules}{$current_module}{skip_test} = ($1 =~ /^(yes|true|1)$/i) ? 1 : 0;
        }
        elsif (/^reason\s*=\s*(.+)$/) {
            $self->{modules}{$current_module}{reason} = $1;
        }
        elsif (/^env\.(\w+)\s*=\s*(.+)$/) {
            $self->{modules}{$current_module}{env}{$1} = $2;
        }
        elsif (/^test_command\s*=\s*(.+)$/) {
            $self->{modules}{$current_module}{test_command} = $1;
        }
    }

    close $fh;
}

sub should_skip_load {
    my ($self, $module) = @_;
    return 0 unless exists $self->{modules}{$module};
    return $self->{modules}{$module}{skip_load};
}

sub should_skip_test {
    my ($self, $module) = @_;
    return 0 unless exists $self->{modules}{$module};
    return $self->{modules}{$module}{skip_test};
}

sub get_reason {
    my ($self, $module) = @_;
    return '' unless exists $self->{modules}{$module};
    return $self->{modules}{$module}{reason} || 'skipped';
}

sub get_env {
    my ($self, $module) = @_;
    return {} unless exists $self->{modules}{$module};
    return $self->{modules}{$module}{env};
}

sub get_test_command {
    my ($self, $module) = @_;
    return '' unless exists $self->{modules}{$module};
    return $self->{modules}{$module}{test_command};
}

sub get_all_skip_load {
    my ($self) = @_;
    return grep { $self->{modules}{$_}{skip_load} } keys %{$self->{modules}};
}

sub get_all_skip_test {
    my ($self) = @_;
    return grep { $self->{modules}{$_}{skip_test} } keys %{$self->{modules}};
}

1;
