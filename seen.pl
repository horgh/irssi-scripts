#
# 2010-09-06
# by Will Storey
#
# Requirements:
#  - DBD::SQLite
#  - Date::Calc
#
# This script watches for events on all channels and networks
# and stores data regarding when users were last seen

# Database is stored in ~/.irssi/seen.db
#
# Data information:
#  - Data recorded: joins, parts, quits, kicks, nicks
#  - One unique record for each server/nick/uhost combination
#  - Server field corresponds to the server tag
#
# Settings:
#  /set seen_trigger_channels #chan1 #chan2 ..
#  List of channels where !seen/.seen works
#
#  /set seen_untracked_channels #chan1 #chan2 ..
#  List of channels where joins/parts/kicks are not tracked.
#  Quits and nicks are currently always tracked.
#

use warnings;
use strict;
use Irssi;
use DBI;
use Date::Calc qw(:all);
use POSIX;
use File::stat;

use vars qw($VERSION %IRSSI);
$VERSION = "20100906";
%IRSSI = (
	authors     => "Will Storey",
	contact     => "will\@summercat.com",
	name        => "seen",
	description => "Collect seen data on all channels into an sqlite database",
	license     => "Public domain",
	url         => "http://www.summercat.com",
	changed     => $VERSION
);

my $dbfile = Irssi::get_irssi_dir . '/seen.db';
my $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile", "", "") or die $DBI::errstr;
create_table();

my $sth_del = $dbh->prepare("DELETE FROM seen WHERE server = ? AND nick = ? AND uhost = ?");
my $sth_add = $dbh->prepare("INSERT INTO seen VALUES(?, ?, ?, ?, ?)");
my $sth_search_nick = $dbh->prepare("SELECT * FROM seen WHERE server = ? AND nick LIKE ? ORDER BY time DESC LIMIT 1");
my $sth_search_host = $dbh->prepare("SELECT * FROM seen WHERE server = ? AND uhost LIKE ? ORDER BY time DESC LIMIT 1");

sub create_table {
	# Check if table exists
	my $res = $dbh->selectall_arrayref("SELECT name FROM sqlite_master WHERE type='table' AND name='seen'");
	if (!@$res) {
		my $rv = $dbh->do("CREATE TABLE seen (server, nick, uhost, time, desc, PRIMARY KEY(server, nick, uhost))");
	}
}

sub sig_irssi_quit {
	$dbh->disconnect;
}

sub print_stats_usage {
	my ($server, $target) = @_;
	$server->command("msg $target Usage: !seen [-nick | -host] <pattern>");
	my $res = $dbh->selectall_arrayref("SELECT COUNT(*) AS count FROM seen");
	my $count = $res->[0][0];
	my $filesize = stat($dbfile)->size / 1024;
	$server->command("msg $target $count seen records using $filesize KB.");
}

# Own !seen/.seen
sub sig_msg_own_pub {
	my ($server, $msg, $target) = @_;
	sig_msg_pub($server, $msg, "", "", $target);
}

# Handle !seen/.seen
sub sig_msg_pub {
	my ($server, $msg, $nick, $address, $target) = @_;
	# Only trigger in enabled channels
	return if !chan_in_settings_str("seen_trigger_channels", $target);

	my ($flags, $pattern) = $msg =~ /^[!\.]seen (-\S+)? ?(\S+)/i;
	if (!$pattern) {
		print_stats_usage($server, $target) if $msg =~ /^[!\.]seen$/;
		return;
	}

	my $sth;
	if (!$flags || $flags eq "-nick") {
		$sth = $sth_search_nick;
	} elsif ($flags eq "-host") {
		$sth = $sth_search_host;
	} else {
		$server->command("msg $target Flag must be -nick or -host.");
		return;
	}

	$pattern =~ s/\*/%/g;
	my $rv = $sth->execute($server->{tag}, $pattern);
	my $row = $sth->fetchrow_hashref;
	if (!$row) {
		$server->command("msg $target No match found.");
	} else {
		# Search in channel for matched nick
		my $channel = $server->channel_find($target);
		my $found_nick = $channel->nick_find($row->{nick});
		if ($found_nick) {
			$server->command("msg $target Matched $row->{nick} who is in the channel already!");
			return;
		}
		my $time = strftime "%c", localtime($row->{time});
		my $time_since = time_since($row->{time});
		$server->command("msg $target $row->{nick} ($row->{uhost}) was last seen $row->{desc} on $time ($time_since).");
	}
}

# Check if given channel is in the settings string
sub chan_in_settings_str {
	my ($settings_str, $channel) = @_;
	my $raw_settings_str = Irssi::settings_get_str($settings_str);
	my @settings = split / /, $raw_settings_str;
	return grep /$channel/, @settings;
}

# Take a unixtime and return time since string
sub time_since {
	my ($prev_time) = @_;
	my ($p_y, $p_m, $p_d, $p_h, $p_min, $p_s, $p_doy, $p_dow, $p_dst) = Localtime($prev_time);
	my ($y, $m, $d, $h, $min, $s, $doy, $dow, $dst) = Localtime();
	# deltas
	my ($d_d, $d_h, $d_min, $d_s) = Delta_DHMS($p_y, $p_m, $p_d, $p_h, $p_min, $p_s, $y, $m, $d, $h, $min, $s);

	my $str = "";
	if ($d_d) {
		if ($d_d > 1) {
			$str .= "$d_d days ";
		} else {
			$str .= "$d_d day ";
		}
	}
	if ($d_h) {
		if ($d_h > 1) {
			$str .= "$d_h hours ";
		} else {
			$str .= "$d_h hour ";
		}
	}
	if ($d_min) {
		if ($d_min > 1) {
			$str .= "$d_min minutes ";
		} else {
			$str .= "$d_min minute ";
		}
	}
	if ($d_s > 1 || $d_s == 0) {
		$str .= "$d_s seconds ";
	} else {
		$str .= "$d_s second ";
	}
	return $str . "ago";
}

sub insert_record {
	my ($server, $nick, $uhost, $time, $desc, $channel) = @_;
	# first delete any old data for user, then add new
	my $rv_d = $sth_del->execute($server, $nick, $uhost);
	my $rv_i = $sth_add->execute($server, $nick, $uhost, $time, $desc);
}

# Begin events that trigger seen updates

sub sig_join {
	my ($server, $channel, $nick, $address) = @_;
	return if chan_in_settings_str("seen_untracked_channels", $channel);
	insert_record($server->{tag}, $nick, $address, time(), "joining");
}

sub sig_part {
	my ($server, $channel, $nick, $address, $reason) = @_;
	return if chan_in_settings_str("seen_untracked_channels", $channel);
	insert_record($server->{tag}, $nick, $address, time(), "parting ($reason)");
}

sub sig_quit {
	my ($server, $nick, $address, $reason) = @_;
	insert_record($server->{tag}, $nick, $address, time(), "quitting ($reason)");
}

sub sig_kick {
	my ($server, $channel, $nick, $kicker, $address, $reason) = @_;
	return if chan_in_settings_str("seen_untracked_channels", $channel);
	insert_record($server->{tag}, $nick, $address, time(), "getting kicked ($reason)");
}

sub sig_nick {
	my ($server, $newnick, $oldnick, $address) = @_;
	insert_record($server->{tag}, $oldnick, $address, time(), "changing nick to $newnick");
	insert_record($server->{tag}, $newnick, $address, time(), "changing nick from $oldnick");
}

Irssi::signal_add('message join', 'sig_join');
Irssi::signal_add('message part', 'sig_part');
Irssi::signal_add('message quit', 'sig_quit');
Irssi::signal_add('message kick', 'sig_kick');
Irssi::signal_add('message nick', 'sig_nick');

Irssi::signal_add('message public', 'sig_msg_pub');
Irssi::signal_add('message own_public', 'sig_msg_own_pub');
# Close DB when Irssi exiting. Is this right?
Irssi::signal_add('gui exit', 'sig_irssi_quit');

Irssi::settings_add_str('seen', 'seen_trigger_channels', '');
Irssi::settings_add_str('seen', 'seen_untracked_channels', '');
