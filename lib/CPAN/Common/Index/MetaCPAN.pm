package CPAN::Common::Index::MetaCPAN;
use 5.008001;
use strict;
use warnings;

use CPAN::DistnameInfo;
use CPAN::Meta::Requirements;
use HTTP::Tiny;
use JSON::PP ();
use version;

our $VERSION = "0.01";

use parent 'CPAN::Common::Index';
use Class::Tiny qw(ua json metacpan_uri);

sub BUILD {
    my $self = shift;
    $self->ua( HTTP::Tiny->new );
    $self->json( JSON::PP->new );
    $self->metacpan_uri( 'http://api.metacpan.org/v0' );
    return;
}

sub with_version_range {
    my($self, $version) = @_;
    defined($version) && $version =~ /[<>=]/;
}

sub maturity_filter {
    my ($self, $module, $version, $allow_dev) = @_;

    my @filters;

    # TODO: dev release should be enabled per dist
    if (!$self->with_version_range($version) or $allow_dev) {
        # backpan'ed dev release are considered "cancelled"
        push @filters, { not => { term => { status => 'backpan' } } };
    }

    unless ($allow_dev or ($version || "") =~ /==/) {
        push @filters, { term => { maturity => 'released' } };
    }

    return @filters;
}

sub version_to_query {
    my($self, $module, $version) = @_;

    my $requirements = CPAN::Meta::Requirements->new;
    $requirements->add_string_requirement($module, $version || '0');

    my $req = $requirements->requirements_for_module($module);

    if ($req =~ s/^==\s*//) {
        return {
            term => { 'module.version' => $req },
        };
    } elsif ($req !~ /\s/) {
        return {
            range => { 'module.version_numified' => { 'gte' => $self->numify_ver_metacpan($req) } },
        };
    } else {
        my %ops = qw(< lt <= lte > gt >= gte);
        my(%range, @exclusion);
        my @requirements = split /,\s*/, $req;
        for my $r (@requirements) {
            if ($r =~ s/^([<>]=?)\s*//) {
                $range{$ops{$1}} = $self->numify_ver_metacpan($r);
            } elsif ($r =~ s/\!=\s*//) {
                push @exclusion, $self->numify_ver_metacpan($r);
            }
        }

        my @filters= (
            { range => { 'module.version_numified' => \%range } },
        );

        if (@exclusion) {
            push @filters, {
                not => { or => [ map { +{ term => { 'module.version_numified' => $self->numify_ver_metacpan($_) } } } @exclusion ] },
            };
        }

        return @filters;
    }
}

sub numify_ver_metacpan {
    my($self, $ver) = @_;
    $ver =~ s/_//g;
    version->new($ver)->numify;
}

sub by_version {
    my %s = qw( latest 3  cpan 2  backpan 1 );
    $b->{_score} <=> $a->{_score} ||                             # version: higher version that satisfies the query
    $s{ $b->{fields}{status} } <=> $s{ $a->{fields}{status} };   # prefer non-BackPAN dist
}

sub by_first_come {
    $a->{fields}{date} cmp $b->{fields}{date};                   # first one wins, if all are in BackPAN/CPAN
}

sub by_date {
    $b->{fields}{date} cmp $a->{fields}{date};                   # prefer new uploads, when searching for dev
}

sub find_best_match {
    my($self, $match, $allow_dev) = @_;
    return unless $match && @{$match->{hits}{hits} || []};
    my @hits = $allow_dev
        ? sort { by_version || by_date } @{$match->{hits}{hits}}
        : sort { by_version || by_first_come } @{$match->{hits}{hits}};
    $hits[0]->{fields};
}

sub search_packages {
    my ($self, $args) = @_;
    # moduel VS package
    my $module = $args->{package} or die "missing package";
    die "CPAN::Common::Index::MetaCPAN does not support callback package query"
        if ref $module eq "CODE";
    my $version = $args->{version};
    die "CPAN::Common::Index::MetaCPAN does not support callback version query"
        if ref $version eq "CODE";

    my $allow_dev = $args->{allow_dev};
    $self->search_metacpan( $module, $version, $allow_dev );
}

sub search_metacpan {
    my($self, $module, $version, $allow_dev) = @_;

    my @filter = $self->maturity_filter($module, $version, $allow_dev);
    my $query = { filtered => {
        (@filter ? (filter => { and => \@filter }) : ()),
        query => { nested => {
            score_mode => 'max',
            path => 'module',
            query => { custom_score => {
                metacpan_script => "score_version_numified",
                query => { constant_score => {
                    filter => { and => [
                        { term => { 'module.authorized' => JSON::PP::true() } },
                        { term => { 'module.indexed' => JSON::PP::true() } },
                        { term => { 'module.name' => $module } },
                        $self->version_to_query($module, $version),
                    ] }
                } },
            } },
        } },
    } };

    my $metacpan_uri = $self->metacpan_uri;
    my $module_uri = "$metacpan_uri/file/_search?source=";
    $module_uri .= $self->json->encode({
        query => $query,
        fields => [ 'date', 'release', 'author', 'module', 'status' ],
    });

    my($release, $author, $module_version);

    my $meta_res = $self->ua->get($module_uri);
    return unless $meta_res->{success};
    my $module_meta = eval { $self->json->decode($meta_res->{content}) };
    my $match = $self->find_best_match($module_meta, $allow_dev);
    if ($match) {
        $release = $match->{release};
        $author = $match->{author};
        my $module_matched = (grep { $_->{name} eq $module } @{$match->{module}})[0];
        $module_version = $module_matched->{version};
    }

    return unless $release;

    my $dist_uri = "$metacpan_uri/release/_search?source=";
    $dist_uri .= $self->json->encode({
        filter => { and => [
            { term => { 'release.name' => $release } },
            { term => { 'release.author' => $author } },
        ]},
        fields => [ 'download_url', 'stat', 'status' ],
    });

    my $dist_res = $self->ua->get($dist_uri);
    return unless $dist_res->{success};
    my $dist_meta = eval { $self->json->decode($dist_res->{content}) };

    if ($dist_meta) {
        $dist_meta = $dist_meta->{hits}{hits}[0]{fields};
    }
    if ($dist_meta && $dist_meta->{download_url}) {
        (my $distfile = $dist_meta->{download_url}) =~ s!.+/authors/id/!!;
        my $mirror;
        if ($dist_meta->{status} eq 'backpan') {
            $mirror = 'http://backpan.perl.org';
        } elsif ($dist_meta->{stat}{mtime} > time()-24*60*60) {
            $mirror = 'http://cpan.metacpan.org';
        }
        return $self->cpan_module($module, $distfile, $module_version, $mirror);
    }

    return;
}

sub cpan_module {
    my($self, $module, $dist, $version, $mirror) = @_;

    $dist =~ s!^([A-Z]{2})!substr($1,0,1)."/".substr($1,0,2)."/".$1!e;

    my $d = CPAN::DistnameInfo->new($dist);

    my $id = $d->cpanid;
    my $fn = substr($id, 0, 1) . "/" . substr($id, 0, 2) . "/" . $id . "/" . $d->filename;
    my $uri = $mirror
            ? "$mirror/authors/id/$fn"
            : "cpan://distfile/$id/" . $d->filename;

    return {
        package => $module,
        version => $version,
        uri => $uri,
    };
}

1;
__END__

=encoding utf-8

=head1 NAME

CPAN::Common::Index::MetaCPAN - searching CPAN modules by MetaCPAN API

=head1 SYNOPSIS

    use CPAN::Common::Index::MetaCPAN;
    my $index = CPAN::Common::Index::MetaCPAN->new;

    my $result = $index->search_packages({
        package => 'Plack',
        version => '>= 1.0000, <= 1.3000',
    });

    use Data::Dumper;
    print Dumper $result;
    # {
    #   package => "Plack",
    #   uri => "cpan://distfile/MIYAGAWA/Plack-1.0030.tar.gz",
    #   version => "1.0030",
    # }

=head1 DESCRIPTION

CPAN::Common::Index::MetaCPAN search CPAN modules
by MetaCPAN API.

=head1 ORIGINAL LICENSE

Almost all code are copied from L<App::cpanminus>.
Its copyright and license are:

    Copyright 2010- Tatsuhiko Miyagawa
    This software is licensed under the same terms as Perl.

See L<https://github.com/miyagawa/cpanminus|https://github.com/miyagawa/cpanminus>
for details.

