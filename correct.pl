# This scripts watches for text in the channel that matches patterns it knows
# about that need correcting.
#
# For example, you could have a pattern for a misspelled URL, which the script
# will then suggest a correction for.
#
# It does this by sending a message.
#
# TODO: Right now patterns and their corrections are hardcoded into the script.

use strict;
use warnings;

use Irssi ();

use vars qw($VERSION %IRSSI);
$VERSION = "20170930";
%IRSSI = (
	authors     => "Will Storey",
	contact     => "will\@summercat.com",
	name        => "correct",
	description => "Auto correct suggestions.",
	license     => "Public domain",
	url         => "https://github.com/horgh/irssi-scripts",
	changed     => $VERSION,
);

Irssi::signal_add('message public', 'sig_msg_pub');

sub sig_msg_pub {
	my ($server, $msg, $nick, $address, $target) = @_;
	if (!$server || !defined $msg || !defined $nick || length $nick == 0 ||
		!defined $address || length $address == 0 ||
		!defined $target || length $target == 0) {
		Irssi::print("sig_msg_pub: Invalid parameter");
		return;
	}

	$msg = lc $msg;

	if ($msg =~ /https:\/\/leviathan\.summercat\.com\/(\S+)/) {
		my $rest = $1;
		my $correction = "https://leviathan.summercat.com:4433/$rest";
		my $response = "$nick: Did you mean $correction ?";

		Irssi::signal_continue($server, $msg, $nick, $address, $target);
		$server->command("MSG $target $response");
	}
}
