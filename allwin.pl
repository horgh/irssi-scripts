#
# 17/08/2010
# by horgh
#
# Print all public messages into a window named 'allwin' while
# keeping those messages also in their original location
#
# This code is based on hilightwin.pl by Timo Sirainen & znx
#
# Settings:
# /set allwin_ignore_channels #ignored1 #ignored2
# Causes #ignored1 and #ignored2 messages to not be shown in allwin
#

use Irssi;
use POSIX;
use vars qw($VERSION %IRSSI); 

$VERSION = "0.01";
%IRSSI = (
	authors     => "horgh",
	contact     => "will\@summercat.com", 
	name        => "allwin",
	description => "Print public messages to window named \"allwin\"",
	license     => "Public Domain",
	url         => "http://irssi.org/",
	changed     => "Tuesday August 17 2010"
);

Irssi::theme_register([
	'allmsg', '$3{pubmsgnick $0 {msgchannel $1}}$2'
]);

sub sig_msg_pub {
	my ($server, $msg, $nick, $address, $target) = @_;

	# Check if channel is set as ignored
	my $ignored_raw = Irssi::settings_get_str('allwin_ignore_channels');
	my @ignored = split(/ /, $ignored_raw);
	if (grep /$target/, @ignored) {
		return;
	}

	# Setup timestamp
	$timestamp = strftime(
		Irssi::settings_get_str('timestamp_format')." ", localtime);

	$window = Irssi::window_find_name('allwin');
	#$window->print($msg, MSGLEVEL_NEVER) if ($window);
	$window->printformat(MSGLEVEL_NEVER, 'allmsg', $nick, $target, $msg, $timestamp);
}

$window = Irssi::window_find_name('allwin');
Irssi::print("Create a window named 'allwin'") if (!$window);

Irssi::settings_add_str('allwin', 'allwin_ignore_channels', '');

Irssi::signal_add('message public', 'sig_msg_pub');
