#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
entrypoint=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")
test "$entrypoint" = '["/usr/bin/perl"]' || {
  printf 'unexpected entrypoint: %s\n' "$entrypoint" >&2
  exit 1
}

actual=$(docker run --rm "$image" -e 'print 6 * 7')
test "$actual" = 42

if docker run --rm "$image" -e 'my $value = ;' >/dev/null 2>&1; then
  printf '%s\n' 'invalid Perl script unexpectedly succeeded' >&2
  exit 1
fi

# CVE-2026-82560: a margin as wide as the output width must warn, not loop forever.
wrapped=$(docker run --rm --network none --memory 256m --memory-swap 256m "$image" -e '
  use strict; use warnings;
  use Pod::Text; use Pod::Text::Color; use Pod::Text::Overstrike;
  $SIG{ALRM} = sub { die "Pod::Text wide-margin check timed out\n" };
  alarm 20;
  my $pod = "=pod\n\n=over 72\n\nText that cannot wrap.\n\n=back\n\n=cut\n";
  for my $class (qw(Pod::Text Pod::Text::Color Pod::Text::Overstrike)) {
    my $out = q{};
    my $parser = $class->new(width => 76);
    $parser->output_string(\$out);
    $parser->parse_string_document($pod);
    die "$class: margin diagnostic missing\n" unless $out =~ /Margin is wider than the output width/;
    print "$class ok\n";
  }
' 2>&1) || {
  printf 'Pod::Text wide-margin check failed: %s\n' "$wrapped" >&2
  exit 1
}
test "$(printf '%s\n' "$wrapped" | wc -l)" -eq 3 || {
  printf 'unexpected Pod::Text wide-margin output: %s\n' "$wrapped" >&2
  exit 1
}

printf 'SMOKE PASS image=%s\n' "$image"
