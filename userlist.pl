#
# 2010-10-10
# by Will Storey
#
# Requirements:
#  - DBD::SQLite
#
# Add users by mask to auto op in given channels / networks
#
# Database is stored in ~/.irssi/userlist.db
#
# Commands:
#  /add_op
#  /del_op
#  /list_ops
#

use warnings;
use strict;
use Irssi;
use DBI;

use vars qw($VERSION %IRSSI);
$VERSION = "20101010";
%IRSSI = (
	authors     => "Will Storey",
	contact     => "will\@summercat.com",
	name        => "userlist",
	description => "Maintain a userlist for auto opping",
	license     => "Public domain",
	url         => "http://www.summercat.com",
	changed     => $VERSION
);

my $dbfile = Irssi::get_irssi_dir . '/userlist.db';
my $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile", "", "") or die $DBI::errstr;
create_table();

my $sth_add_op = $dbh->prepare("INSERT INTO ops VALUES(NULL, ?, ?, ?)");
my $sth_del_op = $dbh->prepare("DELETE FROM ops WHERE id = ?");
my $sth_list_ops = $dbh->prepare("SELECT * FROM ops ORDER BY id ASC");
my $sth_get = $dbh->prepare("SELECT * FROM ops WHERE network = ? AND channel = ?");

sub create_table {
	# Check if table exists
	my $res = $dbh->selectall_arrayref("SELECT name FROM sqlite_master WHERE type='table' AND name='ops'");
	if (!@$res) {
		my $rv = $dbh->do("CREATE TABLE ops (id INTEGER PRIMARY KEY, network, channel, mask)");
	}
}

sub sig_irssi_quit {
	$dbh->disconnect;
}

sub cmd_add_op {
	# $data = params
	my ($data, $server, $witem) = @_;
	my ($network, $channel, $mask) = split / /, $data;
	if (!$network || !$channel || !$mask) {
		Irssi::print("Usage: /add_op <network> <#channel> <nick!ident\@mask>");
		return;
	}
	my $rv = $sth_add_op->execute($network, $channel, $mask);
	Irssi::print("Added auto op for '$mask' on $channel \@ $network.");
}

sub cmd_del_op {
	my ($data, $server, $witem) = @_;
	my ($id) = split / /, $data;
	if (!$id) {
		Irssi::print("Usage: /del_op <id>");
		return
	}

	my $rv = $sth_del_op->execute($id);
	if ($rv > 0) {
		Irssi::print("Successfully deleted op #$id.");
	} else {
		Irssi::print("Error deleting op record. Is the id correct?");
	}
}

sub cmd_list_ops {
	my ($data, $server, $witem) = @_;

	Irssi::print("Current ops:");
	my $rv = $sth_list_ops->execute();
	while (my $row = $sth_list_ops->fetchrow_hashref()) {
		Irssi::print("$row->{id}. $row->{mask} on $row->{channel} @ $row->{network}");
	}
}

sub sig_msg_join {
	my ($server, $channel, $nick, $address) = @_;

	# Check if we are opped
	my $own_nick = $server->{nick};
	my $channel_object = $server->channel_find($channel);
	my $nick_object = $channel_object->nick_find($own_nick);
	if (!$nick_object->{op}) {
		return;
	}

	my $rv = $sth_get->execute($server->{tag}, $channel);
	while (my $row = $sth_get->fetchrow_hashref()) {
		if ($server->mask_match_address($row->{mask}, $nick, $address)) {
			Irssi::print("Auto opping $nick in $channel @ $server->{tag}.");
			$server->command("mode $channel +o $nick");
		}
	}
}

Irssi::signal_add('gui exit', 'sig_irssi_quit');
Irssi::signal_add('message join', 'sig_msg_join');

Irssi::command_bind('add_op', 'cmd_add_op');
Irssi::command_bind('del_op', 'cmd_del_op');
Irssi::command_bind('list_ops', 'cmd_list_ops');
