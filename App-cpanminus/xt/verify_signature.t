use strict;
use lib ".";
use xt::Run;
use Test::More;

use File::Temp ();
use File::Which ();
use HTTP::Tinyish;

my $gpg = File::Which::which "gpg";

plan skip_all => 'need gpg' if !$gpg;

{
    # XXX As of 2021-11-29, Module::Signature does not bundle PAUSE2022.pub,
    # so we should import PAUSE2022 by ourselves
    my $url = "https://raw.githubusercontent.com/andk/cpanpm/master/PAUSE2022.pub";
    my $res = HTTP::Tinyish->new->get($url);
    die "$res->{status} $res->{reason}, $url\n" if !$res->{success};
    my $tempfile = File::Temp->new;
    $tempfile->print($res->{content});
    $tempfile->close;
    !system $gpg, "--quiet", "--import", $tempfile->filename or die;
    # XXX for some reasons, "gpg --import PAUSE.pub" takes some time. Wait it...
    for my $times (1..10) {
        my ($first, @other) = `gpg --list-keys PAUSE`;
        warn "!!!> $first";
        warn "!!!> $_" for @other;
        if ($first && $first =~ /2022-07-01/) { # 2022-07-01 is expiration date of PAUSE2022.pub
            last;
        }
        if ($times == 10) {
            die "TIMEOUT";
        }
        sleep 1;
    }

}

run "--reinstall", "--verify", "Module::Signature";
like last_build_log, qr/Verifying the SIGNATURE/;
like last_build_log, qr/Verified OK/;

done_testing;
