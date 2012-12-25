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
#  added_by VARCHAR NOT NULL,
#  UNIQUE (quote),
#  PRIMARY KEY (id)
# );
#

use warnings;
use strict;

use DBI ();
use Irssi ();
use DateTime::Format::Pg ();

# Config

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
  if (!defined $msg || !length $msg) {
    $msg = "no log message given!";
  }
  chomp $msg;

  my $caller = (caller(1))[3];
  # Irssi finds function name that looks like:
  # "Irssi::Script::sqlquote::quote_search"
  # trim off "Irssi::Script::".
  $caller =~ s/^Irssi::Script:://;
  my $output = "$caller: $msg";

  Irssi::print($output);
}

# @return mixed DBI handle or undef
sub get_dbh {
  if (!$dbh || !$dbh->ping) {
    $dbh = DBI->connect($dsn, $DB_USER, $DB_PASS);
    if (!$dbh || !$dbh->ping) {
      &log("failed to connect to database: " . $DBI::errstr);
      return undef;
    }
  }
  return $dbh;
}

# @param string $sql         SQL to execute
# @param aref $paramsAref    Params given to the prepared statement
#
# @return mixed DBI statement handle object, or undef if failure
#
# Executes a query and returns the sth
# Lowest level DB interaction
sub db_query {
  my ($sql, $paramsAref) = @_;
  if (!$sql || !$paramsAref) {
    &log("invalid param");
    return undef;
  }

  my $dbh = &get_dbh;
  if (!$dbh || !$dbh->ping) {
    &log("failure getting dbh");
    return undef;
  }

  my $sth = $dbh->prepare($sql);
  if (!$sth) {
    &log("failure preparing sql: $sql : " . $dbh->errstr);
    return undef;
  }

  if (!$sth->execute(@$paramsAref)) {
    &log("failure executing sql: $sql : " . $sth->errstr);
    return undef;
  }
  return $sth;
}

# @param string $sql             SQL to execute
#                                Should be adequate for prepare()
# @param array ref $paramsAref   Parameters to use
# @param string $keyField        Column to use as key in hash. Optional.
#                                Defaults to 'id'.
#
# @return mixed undef if failure, or hash reference if success
#
# Execute and return rows from a SELECT query
sub db_select {
  my ($sql, $paramsAref, $keyField) = @_;
  # keyField is optional
  if (!$sql || !$paramsAref) {
    &log("invalid param");
    return undef;
  }

  my $sth = &db_query($sql, $paramsAref);
  if (!$sth) {
    &log("failure executing query");
    return undef;
  }

  # id = key field
  my $key = 'id';
  if ($keyField) {
    $key = $keyField;
  }
  my $href = $sth->fetchall_hashref($key);

  # Check if successfully fetched href
  # Fetchall_hashref will have set dbh->err if so
  my $dbh = &get_dbh;
  if (!$dbh || $dbh->err) {
    &log("Failure fetching results of SQL: $sql " . $dbh->errstr);
    return undef;
  }
  return $href;
}

# @param string $sql
# @param aref $paramsAref
#
# @return undef if failure, number of rows affected if success
#
# Perform a data changing query, such as UPDATE, DELETE, INSERT
sub db_manipulate {
  my ($sql, $paramsAref) = @_;
  if (!$sql || !$paramsAref) {
    &log("invalid param");
    return undef;
  }

  my $sth = &db_query($sql, $paramsAref);
  if (!$sth) {
    &log("failure executing query");
    return undef;
  }
  return $sth->rows;
}

# @param server $server
# @param string $target   channel/nickname
# @param string $msg      message content
#
# @return void
#
# output an irc message to a target - channel/nick.
sub msg {
  my ($server, $target, $msg) = @_;
  if (!$server || !$target || !$msg) {
    &log("invalid param");
    return;
  }

  $server->command("MSG $target $msg");
}

# @return void
#
# clear the quote cache.
sub clear_quote_cache {
  # free the cached quotes by unsetting the global hashes which hold
  # the cached results.
  $random_quotes = undef;
  $search_quotes = undef;
  &log("Quote cache cleared.");
}

# @return mixed int count of quotes or undef if failure
#
# count of quotes in the database
sub get_quote_count {
  my $sql = qq/
SELECT COUNT(1) AS id FROM quote
/;
  my @params = ();
  my $href = &db_select($sql, \@params);
  return undef unless $href && %$href && scalar(keys(%$href)) == 1;
  my $count = (keys %$href)[0];
  return $count;
}

# @param server $server
# @param string $target
#
# @return void
#
# Get database stats
sub quote_stats {
  my ($server, $target) = @_;
  if (!$server || !$target) {
    &log("invalid param");
    return;
  }

  my $count = &get_quote_count;
  if (!$count) {
    &msg($server, $target, "Failed to get quote count.");
    return;
  }

  &msg($server, $target, "There are $count quotes in the database.");
}

# @param server $server
# @param string $target
# @param href $quote_href   Quote information from the database
# @param string $left       Number of quotes left of this search
# @param string $search     Search string
#
# @return void
sub spew_quote {
  my ($server, $target, $quote_href, $left, $search) = @_;
  # left, search are optional
  if (!$server || !$target || !$quote_href) {
    &log("invalid param");
    return;
  }

  my $header = "Quote #\002" . $quote_href->{id} . "\002";
  $header .= " ($left left)" if defined $left;
  $header .= ": *$search*" if defined $search;
  &msg($server, $target, $header);

  # date line
  my $dt_parser = DateTime::Format::Pg->parse_timestamp($quote_href->{create_time});
  my $date = DateTime::Format::Pg->format_date($dt_parser);
  my $date_header = "Date: $date";
  &msg($server, $target, $date_header);

  # added by line
  my $added_by = "Added by: " . $quote_href->{added_by};
  &msg($server, $target, $added_by);

  foreach my $line (split /\n|\r/, $quote_href->{quote}) {
    chomp $line;
    next if $line =~ /^\s*$/;
    &msg($server, $target, " $line");
  }
}

# @param server $server
# @param string $target
#
# @return void
#
# Get latest quote
sub quote_latest {
  my ($server, $target) = @_;
  if (!$server || !$target) {
    &log("invalid param");
    return;
  }

  my $sql = qq/
SELECT * FROM quote ORDER BY id DESC LIMIT 1
/;
  my @params = ();
  my $href = &db_select($sql, \@params);
  return unless $href;

  my $id = (keys %$href)[0];
  return unless $id;

  my $quote_href = $href->{$id};
  &spew_quote($server, $target, $quote_href);
}

# @param server $server
# @param string $target
# @param string $search   search string
#
# @return void
#
# find the latest quote with the given search string and spew it
sub quote_latest_search {
  my ($server, $target, $search) = @_;
  if (!$server || !$target || !defined $search) {
    &log("invalid param");
    return;
  }

  # convert to sql wildcard
  my $sql_search = "%$search%";
  $sql_search =~ s/\*/%/g;

  my $sql = qq/
SELECT * FROM quote
WHERE LOWER(quote) LIKE LOWER(?)
ORDER BY id DESC
LIMIT 1
/;
  my @params = (
                $sql_search,
               );
  my $href = &db_select($sql, \@params);
  if (!$href || !%$href) {
    &msg($server, $target, "No quotes found matching *$search*.");
    return;
  }

  # find the only key in the hash
  my $id = (keys %$href)[0];
  if (!defined $id) {
    &log("no id found");
    return;
  }

  my $quote_href = $href->{$id};
  &spew_quote($server, $target, $quote_href);
}

# @param server $server
# @param string $target
#
# @return void
#
# Get a random quote
sub quote_random {
  my ($server, $target) = @_;
  if (!$server || !$target) {
    &log("invalid param");
    return;
  }

  # check if we need to fetch more quotes into the global cache
  if (!$random_quotes || !%$random_quotes) {
    &log("Fetching new random quotes.");
    my $sql = qq/
SELECT * FROM quote ORDER BY random() LIMIT 20
/;
    my @params = ();
    my $href = &db_select($sql, \@params);
    return unless $href;

    # set the global cache
    $random_quotes = $href;
  }

  # pull a quote out of the global cache
  my $id = (keys %$random_quotes)[0];
  my $quote_href = $random_quotes->{$id};
  delete $random_quotes->{$id};

  &spew_quote($server, $target, $quote_href);
}

# @param server $server
# @param string $target
# @param int $id         Quote id to fetch
#
# @return void
sub quote_id {
  my ($server, $target, $id) = @_;
  if (!$server || !$target || !defined $id) {
    &log("invalid param");
    return;
  }

  my $sql = qq/
SELECT * FROM quote WHERE id = ?
/;
  my @params = ($id);
  my $href = &db_select($sql, \@params);
  if (!$href || !%$href || !defined($href->{$id})) {
    &msg($server, $target, "No quote with id $id found.");
    return;
  }

  my $quote_href = $href->{$id};
  &spew_quote($server, $target, $quote_href);
}

# @param server $server
# @param string $target
# @param string $string   Search string
#
# @return void
sub quote_search {
  my ($server, $target, $string) = @_;
  if (!$server || !$target || !defined $string) {
    &log("invalid param");
    return;
  }

  my $sql_string = "%$string%";
  $sql_string =~ s/\*/%/g;

  # check whether the global cache has a result for this search
  if (!$search_quotes || !defined($search_quotes->{$string})
    || !$search_quotes->{$string})
  {
    &log("Fetching new quotes for search: $string");
    my $sql = qq/
SELECT * FROM quote WHERE LOWER(quote) LIKE LOWER(?)
/;
    my @params = ($sql_string);
    my $href = &db_select($sql, \@params);
    if (!$href || !%$href) {
      &msg($server, $target, "No quotes found matching *$string*.");
      return;
    }

    # place the result in the global cache
    $search_quotes->{$string} = $href;
  }

  # pull a result out of the global cache
  my $id = (keys %{$search_quotes->{$string}})[0];
  my $quote_href = $search_quotes->{$string}->{$id};
  delete $search_quotes->{$string}->{$id};

  # remove the cache key for this search if there are none remaining
  my $count_left = scalar (keys %{$search_quotes->{$string}});
  delete $search_quotes->{$string} if $count_left == 0;

  &spew_quote($server, $target, $quote_href, $count_left, $string);
}

# @param server $server
# @param string $target
# @param string $str      search string
#
# @return void
sub quote_count {
  my ($server, $target, $str) = @_;
  if (!$server || !$target || !defined $str) {
    &log("invalid param");
    return;
  }

  # sql wildcard the string
  my $sql_str = "%$str%";
  $sql_str =~ s/\*/%/g;

  # get the count of quotes matching the pattern
  my $sql = qq/
SELECT COUNT(1) FROM quote WHERE LOWER(quote) LIKE LOWER(?)
/;
  my @params = ($sql_str);
  my $href = &db_select($sql, \@params, 'count');
  if (!$href || !%$href) {
    &msg($server, $target, "Failed to find count.");
    return;
  }
  # one and only key of hash should be the count
  if (scalar(keys(%$href)) != 1) {
    &msg($server, $target, "Count not found.");
    return;
  }
  my $count = (keys(%$href))[0];

  # get the total count
  my $total_count = &get_quote_count;
  if (!$total_count) {
    &msg($server, $target, "Failed to find total count of quotes.");
    return;
  }

  # calculate %
  my $percent = $count / $total_count * 100;
  $percent = sprintf "%.2f", $percent;

  &msg($server, $target,
    "There are $count/$total_count ($percent%) quotes matching *$str*.");
}

# @param server $server
# @param string $target   channel
#
# @return void
#
# output information about our stored state/memory
sub quote_memory {
  my ($server, $target) = @_;
  if (!$server || !$target) {
    &log("invalid parameter");
    return;
  }

  # find how many random quotes currently cached.
  my $random_quote_count = 0;
  $random_quote_count = scalar (keys %$random_quotes) if $random_quotes;

  # find how many search strings stored.
  my $search_string_count = 0;
  $search_string_count = scalar (keys %$search_quotes) if $search_quotes;

  # find how many quotes are stored for all search strings.
  my $search_quote_count = 0;
  if ($search_quotes) {
    foreach my $str (keys %$search_quotes) {
      my $search_href = $search_quotes->{$str};
      $search_quote_count += scalar (keys $search_href);
    }
  }

  my $total_quote_count = $random_quote_count + $search_quote_count;

  my @msgs = (
    qq/Currently caching $total_quote_count quotes:/,
    qq/    $random_quote_count random quotes/,
    qq/    $search_quote_count search results for $search_string_count/
        . qq/ search strings/,
  );

  foreach my $msg (@msgs) {
    &msg($server, $target, $msg);
  }
}

# @param server $server
# @param string $target   channel
#
# @return void
#
# free cached quotes.
sub quote_free {
  my ($server, $target) = @_;
  if (!$server || !$target) {
    &log("invalid parameter");
    return;
  }

  &clear_quote_cache;
  &msg($server, $target, "Quote cache cleared.");
}

# @param server $server
# @param string $target
# @param string $msg   Message on a channel enabled for triggers
#
# @return void
sub handle_command {
  my ($server, $target, $msg) = @_;
  if (!$server || !$target || !defined $msg) {
    &log("invalid param");
    return;
  }

  # trim whitespace
  $msg =~ s/^\s+//;
  $msg =~ s/\s+$//;

  # quotestats
  return &quote_stats($server, $target)if $msg =~ /^!?quotestats$/;

  # latest
  return &quote_latest($server, $target) if $msg =~ /^!?latest$/;

  # latest <search string>
  return &quote_latest_search($server, $target, $1)
    if $msg =~ /^!?latest\s+(.+)$/;

  # quote
  return &quote_random($server, $target) if $msg =~ /^!?quote$/;

  # quote <#>
  return &quote_id($server, $target, $1) if $msg =~ /^!?quote\s+(\d+)$/;

  # quote <search string>
  return &quote_search($server, $target, $1) if $msg =~ /^!?quote\s+(.+)$/;

  # quotecount <search string>
  return &quote_count($server, $target, $1) if $msg =~ /^!?quotecount\s+(.+)$/;

  # quotememory
  return &quote_memory($server, $target) if $msg =~ /^!?quotememory$/;

  # quotefree
  return &quote_free($server, $target) if $msg =~ /^!?quotefree$/;
}

# @param string $settings_str  Name of the setting
# @param string $channel       Channel name
#
# @return bool Whether channel is in the setting
#
# Check if given channel is in the settings string
sub channel_in_settings_str {
	my ($settings_str, $channel) = @_;
  if (!$settings_str || !$channel) {
    &log("invalid param");
    return 0;
  }

	my $raw_settings_str = Irssi::settings_get_str($settings_str);
	my @settings = split / /, $raw_settings_str;
	return grep /$channel/, @settings;
}

# @param server $server
# @param string $msg
# @param string $nick
# @param string $address
# @param string $target
#
# @return void
sub sig_msg_pub {
  my ($server, $msg, $nick, $address, $target) = @_;
  if (!$server || !defined $msg || !$nick || !$address || !$target) {
    &log("invalid param");
    return;
  }

  $msg = lc $msg;

  # Only trigger in enabled channels
  return unless &channel_in_settings_str('quote_channels', $target);
  &handle_command($server, $target, $msg);
}

# @param server $server
# @param string $msg
# @param string $target
#
# @return void
sub sig_msg_own_pub {
  my ($server, $msg, $target) = @_;
  if (!$server || !defined $msg || !$target) {
    &log("invalid param");
    return;
  }

  # we WANT case sensitivity for own messages, or else we print
  # out quotes again due to the 'Quote #' quote header.

  # Only trigger in enabled channels
  return unless &channel_in_settings_str('quote_channels', $target);
  &handle_command($server, $target, $msg);
}

Irssi::signal_add('message public', 'sig_msg_pub');
Irssi::signal_add('message own_public', 'sig_msg_own_pub');

Irssi::settings_add_str('quote', 'quote_channels', '');

# timer to clear the quote cache every 24 hours.
# timer takes time to run in milliseconds.
Irssi::timeout_add(24*60*60*1000, 'clear_quote_cache', '');
