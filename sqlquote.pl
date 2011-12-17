#
# 17/12/2011
# will@summercat.com
#
# Interact with a database of quotes using DBI
#
# PostgreSQL schema:
# CREATE TABLE quote (
#  id SERIAL,
#  create_time TIMESTAMP DEFAULT current_timestamp,
#  quote VARCHAR NOT NULL,
#  UNIQUE (quote),
#  PRIMARY KEY (id)
# );
#

use warnings;
use strict;
use DBI ();
use Irssi;

# Config

#my $DB_HOST = 'localhost';
my $DB_HOST = 'beast';
my $DB_NAME = 'quote';
my $DB_USER = 'quote';
my $DB_PASS = 'quote';

my $dsn = "dbi:Pg:dbname=$DB_NAME;host=$DB_HOST";

# Done config

use vars qw($VERSION %IRSSI);
$VERSION = "20111217";
%IRSSI = (
	authors     => "Will Storey",
	contact     => "will\@summercat.com",
	name        => "sqlquote",
	description => "Quote SQL database interaction",
	license     => "Public domain",
	url         => "http://www.summercat.com",
	changed     => $VERSION
);

# Global database handle
my $dbh;
# Random quote cache: id -> quote
my $random_quotes;
# Search quote cache: str -> id -> quote
my $search_quotes;

# @param string $msg
#
# @return void
sub log {
  my ($msg) = @_;
  Irssi::print($msg);
}

# @return mixed DBI handle or undef
sub get_dbh {
  if (!$dbh) {
    $dbh = DBI->connect($dsn, $DB_USER, $DB_PASS);
    if (!$dbh) {
      return undef;
    }
  }
  return $dbh;
}

# @param string $sql         SQL to execute
# @param aref $paramsAref    Params given to the prepared statement
#
# @return mixed DBI statement handle object, or 0 if failure
#
# Executes a query and returns the sth
# Lowest level DB interaction
sub db_query {
  my ($sql, $paramsAref) = @_;

  my $dbh = &get_dbh;
  if (!$dbh || !$dbh->ping) {
    &log("db_query: failure getting dbh");
    return 0;
  }

  my $sth = $dbh->prepare($sql);
  if (!$sth) {
    &log("db_query: failure preparing sql: $sql : " . $dbh->errstr);
    return 0;
  }

  if (!$sth->execute(@$paramsAref)) {
    &log("db_query: failure executing sql: $sql : " . $sth->errstr);
    return 0;
  }
  return $sth;
}

# @param string $sql             SQL to execute
#                                Should be adequate for prepare()
# @param array ref $paramsAref   Parameters to use
#
# @return mixed int 0 if failure, or hash reference if success
#
# Execute and return rows from a SELECT query
sub db_select {
  my ($sql, $paramsAref) = @_;

  my $sth = &db_query($sql, $paramsAref);
  if (!$sth) {
    &log("db_select: failure executing query");
    return 0;
  }

  # id = key field
  my $href = $sth->fetchall_hashref('id');

  # Check if successfully fetched href
  # Fetchall_hashref will have set dbh->err if so
  my $dbh = &get_dbh;
  if (!$dbh || $dbh->err) {
    &log("db_select: Failure fetching results of SQL: $sql " . $dbh->errstr);
    return 0;
  }
  return $href;
}

# @param string $sql
# @param aref $paramsAref
#
# @return int -1 if failure, number of rows affected if success
#
# Perform a data changing query, such as UPDATE, DELETE, INSERT
sub db_manipulate {
  my ($sql, $paramsAref) = @_;

  my $sth = &db_query($sql, $paramsAref);
  if (!$sth) {
    &log("db_manipulate: failure executing query");
    return -1;
  }
  return $sth->rows;
}

# @param server $server
# @param string $target
#
# @param string $msg
#
# @return void
sub msg {
  my ($server, $target, $msg) = @_;
  $server->command("MSG $target $msg");
}

# @param server $server
# @param string $target
#
# @return void
#
# Get database stats
sub quote_stats {
  my ($server, $target) = @_;

  my $sql = "SELECT COUNT(1) AS id FROM quote";
  my @params = ();
  my $href = &db_select($sql, \@params);
  return unless $href;
  my $count = (keys %$href)[0];
  &msg($server, $target, "There are $count quotes in the database.");
  return;
}

# @param server $server
# @param string $target
# @param int $id          Quote id
# @param string $quote    Quote content
# @param string $left     Number of quotes left of this search
# @param string $search   Search string
#
# @return void
sub spew_quote {
  my ($server, $target, $id, $quote, $left, $search) = @_;

  my $header = "Quote #\002$id\002";
  $header .= " ($left left)" if $left;
  $header .= ": *$search*" if $search;
  &msg($server, $target, $header);

  foreach my $line (split /\n|\r|\n\r|\r\n/, $quote) {
    chomp $line;
    next if $line =~ /^\s*$/;
    &msg($server, $target, " $line");
  }
  return;
}

# @param server $server
# @param string $target
#
# @return void
#
# Get latest quote
sub quote_latest {
  my ($server, $target) = @_;

  my $sql = "SELECT * FROM quote ORDER BY id DESC LIMIT 1";
  my @params = ();
  my $href = &db_select($sql, \@params);
  return unless $href;

  my $id = (keys %$href)[0];
  return unless $id;

  my $quote = $href->{$id}->{quote};
  &spew_quote($server, $target, $id, $quote);
  return;
}

# @param server $server
# @param string $target
#
# @return void
#
# Get a random quote
sub quote_random {
  my ($server, $target) = @_;

  if (!$random_quotes || !%$random_quotes) {
    Irssi::print("quote_random: Fetching new random quotes.");
    my $sql = "SELECT * FROM quote ORDER BY random() LIMIT 20";
    my @params = ();
    my $href = &db_select($sql, \@params);
    return unless $href;
    $random_quotes = $href;
  }
  my $id = (keys %$random_quotes)[0];
  my $quote = $random_quotes->{$id}->{quote};
  delete $random_quotes->{$id};
  &spew_quote($server, $target, $id, $quote);
  return;
}

# @param server $server
# @param string $target
# @param int $id         Quote id to fetch
#
# @return void
sub quote_id {
  my ($server, $target, $id) = @_;

  my $sql = "SELECT * FROM quote WHERE id = ?";
  my @params = ($id);
  my $href = &db_select($sql, \@params);
  if (!$href || !%$href || !defined($href->{$id})) {
    &msg($server, $target, "No quote with id $id found.");
    return;
  }

  my $quote = $href->{$id}->{quote};
  &spew_quote($server, $target, $id, $quote);
  return;
}

# @param server $server
# @param string $target
# @param string $search   Search string
#
# @return void
sub quote_search {
  my ($server, $target, $string) = @_;

  my $sql_string = "%$string%";
  $sql_string =~ s/\*/%/g;

  if (!$search_quotes || !defined($search_quotes->{$string})
    || !$search_quotes->{$string})
  {
    Irssi::print("Fetching new quotes for search: $string");
    my $sql = "SELECT * FROM quote WHERE quote LIKE ? LIMIT 20";
    my @params = ($sql_string);
    my $href = &db_select($sql, \@params);
    if (!$href || !%$href) {
      &msg($server, $target, "No quotes found matching *$string*.");
      return;
    }
    $search_quotes->{$string} = $href;
  }
  my $id = (keys %{$search_quotes->{$string}})[0];
  my $quote = $search_quotes->{$string}->{$id}->{quote};
  delete $search_quotes->{$string}->{$id};

  my $count_left = scalar (keys %{$search_quotes->{$string}});
  delete $search_quotes->{$string} if $count_left == 0;

  &spew_quote($server, $target, $id, $quote, $count_left, $string);
  return;
}

# @param server $server
# @param string $target
# @param string $msg   Message on a channel enabled for triggers
#
# @return void
sub handle_command {
  my ($server, $target, $msg) = @_;

  # quotestats
  return &quote_stats($server, $target) if $msg =~ /^!?quotestats$/;

  # latest
  return &quote_latest($server, $target) if $msg =~ /^!?latest$/;

  # quote
  return &quote_random($server, $target) if $msg =~ /^!?quote$/;

  # quote <#>
  return &quote_id($server, $target, $1) if $msg =~ /^!?quote (\d+)$/;

  # quote <search string>
  return &quote_search($server, $target, $1) if $msg =~ /^!?quote (.+)$/;
}

# Check if given channel is in the settings string
sub channel_in_settings_str {
	my ($settings_str, $channel) = @_;
	my $raw_settings_str = Irssi::settings_get_str($settings_str);
	my @settings = split / /, $raw_settings_str;
	return grep /$channel/, @settings;
}

sub sig_msg_pub {
  my ($server, $msg, $nick, $address, $target) = @_;
  # Only trigger in enabled channels
  return if !&channel_in_settings_str('quote_channels', $target);
  &handle_command($server, $target, $msg);
  return;
}

sub sig_msg_own_pub {
  my ($server, $msg, $target) = @_;
  &sig_msg_pub($server, $msg, "", "", $target);
  return;
}

Irssi::signal_add('message public', 'sig_msg_pub');
Irssi::signal_add('message own_public', 'sig_msg_own_pub');

Irssi::settings_add_str('quote', 'quote_channels', '');
