#!/usr/bin/env perl
#
# 29/1/2012
# will@summercat.com
#
# verify a signature of a plaintext string with a number of public keys
# if one verifies, exit code 0
#
# for use with bot.pl. this is because attempting to verify with a key
# which does not match generates an SSL warning/error. this causes Irssi
# to disconnect SSL connections for some reason...
#

use warnings;
use strict;
use Crypt::OpenSSL::RSA ();
use MIME::Base64 ();

# read data from stdin
# format should be pubkeys separated by new line
# then last two lines should be plaintext and the signature
my @lines = <>;

# we actually would need more lines than this, but at minimum...
if (scalar(@lines) < 4) {
  die "bot_verify: invalid line count";
}

my @pubkeys = ();
my $s = '';
foreach (@lines) {
  if (/^\s*$/) {
    push(@pubkeys, $s);
    $s = '';
    next;
  }
  $s .= $_;
}
my $plaintext = $lines[-2];
my $signature_b64 = $lines[-1];
chomp $plaintext;
chomp $signature_b64;
#print "bot_verify: plaintext is $plaintext\n";
#print "bot_verify: signature in b64 is $signature_b64\n";
# decode it from base64
my $signature = MIME::Base64::decode_base64($signature_b64);
die "bot_verify: could not decode signature" unless $signature;

foreach my $pubkey (@pubkeys) {
  my $rsa = Crypt::OpenSSL::RSA->new_public_key($pubkey);
  exit 0 if $rsa->verify($plaintext, $signature);
}
#print "bot_verify: no match\n";
exit 1;
