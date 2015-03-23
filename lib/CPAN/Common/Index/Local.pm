package CPAN::Common::Index::Local;
use strict;
use warnings;

use parent 'CPAN::Common::Index';

sub new {
    my $class = shift;
    my $hash = @_ == 1 ? $_[0] : {@_};
    my $source = $hash->{source} or die;
    my $mirror = $hash->{mirror};
    $mirror =~ s{/?$}{/} if $mirror;
    bless {
        index => $class->_read_source($source),
        source => $source ,
        mirror => $mirror,
    }, $class;
}

sub _read_source {
    my ($class, $file) = @_;
    my %index;
    open my $fh, "<", $file or die "$file: $!";
    my $header = 1;
    while (my $line = <$fh>) {
        if ($line =~ /^\s+$/) {
            $header = 0;
            next;
        }
        next if $header;
        chomp $line;
        my ($module, $version, $dist, @other) = split /\s+/, $line;
        $index{$module} = +{
            version => $version eq 'undef' ? undef : $version,
            dist => $dist,
            other => \@other,
        };
    }
    \%index;
}

sub search_packages {
    my ($self, $args) = @_;
    return unless $self->{index};

    my $module = $args->{package} or die;
    my $try = $self->{index}{$module} or return;
    if (my $version = $args->{version}) {
        if ( !$try->{version} || $try->{version} < $version ) {
            return;
        }
    }
    my $uri;
    if ($self->{mirror}) {
        $uri = sprintf "%sauthors/id/%s", $self->{mirror}, $try->{dist};
    } else {
        $try->{dist} =~ s{^./../}{};
        $uri = sprintf "cpan://distfile/%s", $try->{dist};
    }
    +{
        package => $module,
        version => $try->{version},
        uri => $uri,
    };
}



1;
