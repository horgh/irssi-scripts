#
# 03/12/2011
# by Will Storey
#
# Requirements:
#  - DBD::SQLite
#
# Alias ident@hosts to nicks to display
# This only replaces nicks in channels
#
# Database is stored in ~/.irssi/nickalias.db
#
# Commands:
#  /add_alias
#  /del_alias
#  /list_aliases
#

use warnings;
use strict;
use Irssi;
use DBI;

use vars qw($VERSION %IRSSI);
$VERSION = "20101225";
%IRSSI = (
	authors     => "Will Storey",
	contact     => "will\@summercat.com",
	name        => "nickalias",
	description => "Alias hosts to nicks",
	license     => "Public domain",
	url         => "http://www.summercat.com",
	changed     => $VERSION
);

my $db_filename = 'nickalias.db';

my $db_file = Irssi::get_irssi_dir . '/' . $db_filename;
my $dbh = DBI->connect("dbi:SQLite:dbname=$db_file", "", "")
  or die $DBI::errstr;

create_table();

# Check if our table exists and create if necessary
sub create_table {
	# Check if table exists
  my $sql = "SELECT name FROM sqlite_master"
          . " WHERE type = 'table' AND name = 'aliases'";
	my $res_href = $dbh->selectall_hashref($sql, 'name');
	if (!%$res_href) {
    $sql = "CREATE TABLE aliases ("
         . " id INTEGER PRIMARY KEY,"
         . " alias NOT NULL,"
         . " mask NOT NULL,"
         . " UNIQUE (mask)"
         . ")";
		$dbh->do($sql)
      or die $dbh->errstr;
	}
}

# Disconnect dbh
sub sig_irssi_quit {
	$dbh->disconnect;
}

# @return 1 if success, 0 if failure
#
# Add an alias to the database
sub add_alias {
  my ($mask, $alias) = @_;

  die unless $dbh and $dbh->ping;

  my $sql = "INSERT INTO aliases (alias, mask) VALUES(?, ?)";
  my $sth = $dbh->prepare($sql);
  if (!$sth) {
    Irssi::print("Failed to add alias: " . $dbh->errstr);
    return 0;
  }

  if (!$sth->execute(($alias, $mask))) {
    Irssi::print("Failed to add alias: " . $dbh->errstr);
    return 0;
  }

  if ($sth->rows != 1) {
    Irssi::print("Failed to add alias: no row inserted?");
    return 0;
  }
  return 1;
}

# Add an alias to the db
sub cmd_add_alias {
  # $data = params
  my ($data, $server, $witem) = @_;
  my ($nick, $alias) = split / /, $data;

  # Check correct arguments
  if (!$nick || !$alias) {
    Irssi::print("Usage: /add_alias <nick to alias> <alias to use>");
    return;
  }

  # Ensure we are in a channel or a query
  if ($witem->{type} ne "CHANNEL" && $witem->{type} ne "QUERY") {
    Irssi::print("You can only run this command in a channel or a query.");
    return;
  }

  # Get the mask of the nick we want to alias
  my $mask;
  # Channel. Find the nick on the channel and get its mask
  if ($witem->{type} eq "CHANNEL") {
    my $channel_object = $server->channel_find($witem->{name});
    my $nick_object = $channel_object->nick_find($nick);
    $mask = $nick_object->{host};

  # Query. Get the query's mask if 
  } else {
    # Make sure query matches the nick we want to alias, otherwise we
    # can't use its address!
    if ($witem->{name} ne $nick) {
      Irssi::print("Query's name does not match nick. Cannot find mask!");
      return;
    }
    $mask = $witem->{address};
  }

  # Make sure we got the mask...
  if (!$mask) {
    Irssi::print("Could not find mask for $nick. Make sure you run this in"
               . " a channel or query where $nick may be found!");
    Irssi::print("NOTE: to add from a query, your target must have messaged you.");
    return;
  }

  # Attempt to add the alias
  if (&add_alias($mask, $alias)) {
    Irssi::print("$nick ($mask) aliased to $alias");
  }
}

sub cmd_del_alias {
	my ($data, $server, $witem) = @_;

	my ($id) = split / /, $data;
	if (!$id) {
		Irssi::print("Usage: /del_alias <id>");
		return
	}

  die unless $dbh and $dbh->ping;

  my $sql = "DELETE FROM aliases WHERE id = ?";
  my $sth = $dbh->prepare($sql)
    or die $dbh->errstr;
  $sth->execute(($id))
    or die $sth->errstr;

  if ($sth->rows != 1) {
    Irssi::print("Failed to remove alias. Did you give a real id?");
    return;
  }
  Irssi::print("Alias deleted.");
}

sub cmd_list_aliases {
	my ($data, $server, $witem) = @_;

  die unless $dbh and $dbh->ping;

  # Get the aliases
  my $sql = "SELECT * FROM aliases ORDER BY id ASC";
  my $sth = $dbh->prepare($sql)
    or die $dbh->errstr;
  $sth->execute()
    or die $sth->errstr;

  my $rows_href = $sth->fetchall_hashref('id');
  die $sth->errstr if $sth->err;

	Irssi::print("Current aliases:");
  foreach my $id (keys(%$rows_href)) {
    Irssi::print("$id. $rows_href->{$id}->{mask} => $rows_href->{$id}->{alias}");
  }
}

# @return string alias if found, or undef
#
# Try to get alias for given mask
sub get_alias {
  my ($mask) = @_;

  die unless $dbh and $dbh->ping;

  my $sql = "SELECT * FROM aliases WHERE mask = ?";
  my $sth = $dbh->prepare($sql)
    or die $dbh->errstr;

  $sth->execute(($mask))
    or die $sth->errstr;

  my $rows_href = $sth->fetchall_hashref('id');
  # Fetchall_hashref sets $sth->err if error occurs
  die $sth->errstr if $sth->err;

  # Make sure we got one row
  return undef unless $rows_href and scalar(keys %$rows_href) == 1;

  # Get the alias
  my ($id) = keys(%$rows_href);
  return undef unless exists $rows_href->{$id}->{alias};
  return $rows_href->{$id}->{alias};
}

# Someone other than us said something. Maybe we need to change their nick
sub sig_msg_public {
  my ($server, $msg, $nick, $address, $target) = @_;

  # If mask matches, show alias and stop the signal, pass on with altered nick
  my $alias = &get_alias($address);
  return unless $alias;

  # We have an alias. Continue signal with alias as nick
  Irssi::signal_continue($server, $msg, $alias, $address, $target);
}

# Close dbh when quit
Irssi::signal_add('gui exit', 'sig_irssi_quit');
Irssi::signal_add('message public', 'sig_msg_public');

Irssi::command_bind('add_alias', 'cmd_add_alias');
Irssi::command_bind('del_alias', 'cmd_del_alias');
Irssi::command_bind('list_aliases', 'cmd_list_aliases');
