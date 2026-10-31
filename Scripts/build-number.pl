#!/usr/bin/perl
use strict;
use warnings;
use Fcntl          qw(:flock);
use File::Basename qw(dirname);
use File::Temp     qw(tempfile);

exit 0 if ( $ENV{ACTION} // '' ) =~ /^(?:clean|analyze|indexbuild)$/;

# Increment the build number only for builds
exit 0 if ( $ENV{CODEXBAR_AUTO_INCREMENT_BUILD_NUMBER} // 'YES' ) eq 'NO';

@ARGV == 1
  or die "error: Usage: build-number.pl BuildNumber.xcconfig\n";
my ($config_path) = @ARGV;

# Keep the lock at a stable path so increments stay serialized across atomic replacements
open my $lock, '>>', "$config_path.lock"
  or die "error: Cannot open build number lock: $!\n";
flock $lock, LOCK_EX
  or die "error: Cannot lock build number: $!\n";

open my $config, '<', $config_path
  or die "error: Cannot read $config_path: $!\n";
my $mode     = ( stat $config )[2] & 0777;
my $contents = do {
    local $/;
    <$config>;
  }
  // '';
close $config
  or die "error: Cannot close $config_path: $!\n";

my @definitions = $contents =~ /^[ \t]*CURRENT_PROJECT_VERSION\b[^\r\n]*/mg;
@definitions == 1
  or die "error: Expected one CURRENT_PROJECT_VERSION in $config_path\n";

my $next_build;
my $replacements = $contents =~ s{
    ^([\t ]*CURRENT_PROJECT_VERSION[\t ]*=[\t ]*)
    ([1-9][0-9]*)
    ([\t ]*(?:;[\t ]*)?(?://[^\r\n]*)?\r?)$
}{
    $next_build = $2 + 1;
    "$1$next_build$3"
}mex;
$replacements == 1
  or die
  "error: CURRENT_PROJECT_VERSION must be a positive integer in $config_path\n";

my ( $temporary, $temporary_path ) = tempfile(
    '.BuildNumber.xcconfig.XXXXXX',
    DIR    => dirname($config_path),
    UNLINK => 1
);
chmod $mode, $temporary_path
  or die "error: Cannot preserve version configuration permissions: $!\n";
print {$temporary} $contents
  or die "error: Cannot write version configuration: $!\n";
close $temporary
  or die "error: Cannot close version configuration: $!\n";
rename $temporary_path, $config_path
  or die "error: Cannot replace $config_path: $!\n";

print "note: CURRENT_PROJECT_VERSION = $next_build\n";
