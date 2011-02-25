#
# Created 25/08/2010
# by Will Storey
#
# Requirements:
#  - LWP::UserAgent (libwww-perl)
#  - Crypt::SSLeay (https)
#  - HTML::Entities (decoding html characters)
#
# Settings:
#  /set urltitle_enabled_channels #channel1 #channel2 ...
#  Enables url fetching on these channels
#

use warnings;
use strict;
use Irssi;
use LWP::UserAgent;
use Crypt::SSLeay;
use HTML::Entities;

use vars qw($VERSION %IRSSI);
$VERSION = "20100825";
%IRSSI = (
	authors     => "Will Storey",
	contact     => "will\@summercat.com",
	name        => "urltitle",
	description => "Fetch urls and print their title",
	license     => "Public Domain",
	url         => "http://www.summercat.com",
	changed     => $VERSION
);

my $useragent = "Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.1.11) Gecko/20100721 Firefox/3.0.6";
my $ua = LWP::UserAgent->new('agent' => $useragent, max_size => 32768);

sub fetch_title {
	my ($url) = @_;

	my $page;
	my $response = $ua->get($url);
	if ($response->is_success) {
		print("Successfully fetched $url.");
		$page = $response->decoded_content();
	} else {
		print("Failure ($url): " . $response->code() . " " . $response->message());
		return "";
	}
	if ($page =~ /<title>(.*)<\/title>/si) {
		my $title = $1;
		# Remove trailing/beginning whitespace
		$title =~ s/^[\s\t]+//;
		$title =~ s/[\s\t]+$//;

		# remove tabs within..
		$title =~ s/[\t]+//g;

		$title =~ s/\s+/ /g;
		decode_entities($title);
		return $title;
	}
	return "";
}

sub sig_msg_pub {
	my ($server, $msg, $nick, $address, $target) = @_;

	# Check we have an enabled channel
	my $enabled_raw = Irssi::settings_get_str('urltitle_enabled_channels');
	my @enabled = split(/ /, $enabled_raw);
	return unless grep(/$target/, @enabled);

	my $url = "";
	if ($msg =~ /(http:\/\/\S+)/i) {
		$url = $1;
	} elsif ($msg =~ /(https:\/\/\S+)/i) {
		$url = $1;
	} elsif ($msg =~ /(www\.\S+)/i) {
		$url = "http://" . $1;
	} else {
		return;
	}
	#return unless $url =~ /https?:\/\/(www\.)?youtube\.com/i;
	#my $thr = threads->create(sub { do_fetch($url, $target, $server); } );
	#print($thr->join());
	do_fetch($url, $target, $server);
}

sub do_fetch {
	my ($url, $target, $server) = @_;

	my $title = fetch_title($url) if $url;
	return unless $title;

	$server->command("msg $target \002$title");
}

sub sig_msg_pub_own {
	my ($server, $msg, $target) = @_;
	sig_msg_pub($server, $msg, $server->{nick}, "", $target);
}

Irssi::settings_add_str('urltitle', 'urltitle_enabled_channels', '');
Irssi::signal_add('message public', 'sig_msg_pub');
Irssi::signal_add('message own_public', 'sig_msg_pub_own');
