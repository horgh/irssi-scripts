#
# Created 17/08/2010
# by horgh
#
# Print all public messages into a window named 'allwin' while
# keeping those messages also in their original location
#
# Credits:
#  - Main code is based on hilightwin.pl by Timo Sirainen & znx
#  - Color stuff is based on nickcolor.pl by Timo Sirainen, Ian Peters
#
# Setup:
#  /window new hide
#  <switch to the window
#  /window name allwin
#
# Settings:
#  /set allwin_ignore_channels #ignored1 #ignored2
#   Causes #ignored1 and #ignored2 messages to not be shown in allwin
#  /set allwin_msg_channel #channel
#   Messages entered into the allwin window will be sent to this channel
#   (Will find first channel named this)
#

use Irssi;
use vars qw($VERSION %IRSSI); 
use POSIX;

$VERSION = "20101218";
%IRSSI = (
	authors     => "horgh",
	contact     => "will\@summercat.com", 
	name        => "allwin",
	description => "Print public messages to window named \"allwin\"",
	license     => "Public Domain",
	url         => "http://summercat.com/",
	changed     => $VERSION
);

my $channel_length = 10;

Irssi::theme_register([
	# $0 = nick, $1 = chan, $2 = msg, $3 = timestamp
# This shows in format <nick:#chan> or the like
#	'allmsg', '$3{pubmsgnick $0 {msgchannel $1}}$2'
	'allmsg', '$3 $1 {pubmsgnick $0}$2',
	'allmsg_action', '$3 $1 {pubaction $0}$2'
]);

my %session_colours = {};
my @colours = qw/2 3 4 5 6 7 8 9 10 11 12 13/;

# total copy from nickcolor.pl
sub simple_hash {
	my ($string) = @_;
	chomp $string;
	my @chars = split //, $string;
	my $counter;

	foreach my $char (@chars) {
		$counter += ord $char;
	}
	$counter = $colours[$counter % 12];
	return $counter;
}

# Colour a channel and format to certain length
sub format_channel {
	my ($channel) = @_;
	# If already has a colour associated, use that
	$colour = $session_colours{$channel};
	if (!$colour) {
		$colour = simple_hash($channel);
		$session_colours{$channel} = $colour;
	}
	$colour = "0".$colour if ($colour < 10);
	$channel = sprintf("%-" . $channel_length . "." . $channel_length . "s", $channel);
	return chr(3) . $colour . $channel;
}

sub window_output {
	my ($format, $nick, $target, $msg) = @_;
	$target = lc($target);

	# Check if channel is set as ignored
	my $ignored_raw = Irssi::settings_get_str('allwin_ignore_channels');
	# make sure to lowercase the channels
	$ignored_raw = lc($ignored_raw);
	my @ignored = split(/ /, $ignored_raw);
	if (grep /$target/, @ignored) {
		return;
	}

	# Setup timestamp
	$timestamp = strftime(Irssi::settings_get_str('timestamp_format')." ", localtime);

	$target = format_channel($target);

	$window = Irssi::window_find_name('allwin');
	$window->printformat(MSGLEVEL_NEVER, $format, $nick, $target, $msg, $timestamp);
}

sub sig_msg_pub {
	my ($server, $msg, $nick, $address, $target) = @_;
	window_output('allmsg', $nick, $target, $msg);
}

sub sig_irc_action {
	my ($server, $msg, $nick, $address, $target) = @_;
	window_output('allmsg_action', $nick, $target, $msg);
}

sub sig_msg_pub_own {
	my ($server, $msg, $target) = @_;
	sig_msg_pub($server, $msg, $server->{nick}, "", $target);
}

sub sig_irc_own_action {
	my ($server, $msg, $target) = @_;
	sig_irc_action($server, $msg, $server->{nick}, "", $target);
}

sub sig_window_text {
	my ($cmd, $server, $witem) = @_;
	$win = Irssi::active_win();
	$name = $win->{name};
	# Window not named allwin
	return if $name ne "allwin";

	my $msg_channel = Irssi::settings_get_str('allwin_msg_channel');
	# Msg channel not set
	return if !$msg_channel;
	
	$chan = Irssi::channel_find($msg_channel);
	# Channel not found
	return if !$chan;
	$chan->{server}->command("msg $chan->{name} $cmd");
}

$window = Irssi::window_find_name('allwin');
Irssi::print("Create a window named 'allwin'") if (!$window);

Irssi::settings_add_str('allwin', 'allwin_ignore_channels', '');
Irssi::settings_add_str('allwin', 'allwin_msg_channel', '');

Irssi::signal_add('message public', 'sig_msg_pub');
Irssi::signal_add('message own_public', 'sig_msg_pub_own');
Irssi::signal_add('message irc own_action', 'sig_irc_own_action');
Irssi::signal_add('message irc action', 'sig_irc_action');
Irssi::signal_add('send text', 'sig_window_text');
