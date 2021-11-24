use lib ".";
use xt::Run;
use Test::More;

my $local_lib = "$ENV{PERL_CPANM_HOME}/perl5";

run("-L", $local_lib, "Hash::MultiValue"); # EUMM
run("-L", $local_lib, "Sub::Uplevel");     # M::B

ok !-e "$local_lib/man", "man page is not generated with -L";

ok !glob("$local_lib/man/man3/Hash::MultiValue.*");
ok !glob("$local_lib/man/man3/Sub::Uplevel.*");

my ($out, $err, $exit) = run("-L", $local_lib, "--man-pages", "Hash::MultiValue");
use Data::Dumper;
warn Dumper [$out, $err, $exit];
diag last_build_log;
($out, $err, $exit) = run("-L", $local_lib, "--man-pages", "Sub::Uplevel");
warn Dumper [$out, $err, $exit];
diag last_build_log;

ok glob("$local_lib/man/man3/Hash::MultiValue.*");
ok glob("$local_lib/man/man3/Sub::Uplevel.*");

done_testing;



