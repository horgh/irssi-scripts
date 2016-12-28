#
# Interact with a database of quotes using DBI. Provide quote display and
# searching functionality to configured channels.
#
# This script does not support adding quotes. To do that I use
# https://github.com/horgh/quote-site
#
# PostgreSQL schema:
#
# -- Store the quote itself.
# CREATE TABLE quote (
#  id SERIAL,
#  create_time TIMESTAMP WITH TIME ZONE DEFAULT current_timestamp,
#  quote VARCHAR NOT NULL,
#  added_by VARCHAR,
#  -- Manually set an update time when you update the quote.
#  update_time TIMESTAMP WITH TIME ZONE,
#  -- Manually add a note if you change the quote.
#  update_notes VARCHAR,
#  -- Flag a quote as sensitive
#  sensitive BOOL NOT NULL DEFAULT false,
#  -- Optional image associated with the quote.
#  image VARCHAR,
#  UNIQUE (quote),
#  PRIMARY KEY (id)
# );
#
# -- Record when someone's search turns up a quote.
# CREATE TABLE quote_search (
#   id SERIAL,
#   create_time TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT current_timestamp,
#   quote_id INTEGER NOT NULL REFERENCES quote(id)
#     ON UPDATE CASCADE ON DELETE CASCADE,
#   PRIMARY KEY (id)
# );
#

use warnings;
use strict;

use DateTime::Format::Pg ();
use DBI ();
use Irssi ();

# Config

my $DB_HOST = 'beast';
my $DB_NAME = 'quote';
my $DB_USER = 'quote';
my $DB_PASS = 'quote';

my $dsn = "dbi:Pg:dbname=$DB_NAME;host=$DB_HOST";

# Time zone to display quote dates in.
my $TIME_ZONE = 'America/Vancouver';

# Base URL to the associated quote website.
my $QUOTE_URL = '';

# Done config

use vars qw($VERSION %IRSSI);
$VERSION = "20161228";
%IRSSI = (
	authors     => "Will Storey",
	contact     => "will\@summercat.com",
	name        => "sqlquote",
	description => "Quote SQL database interaction",
	license     => "Public domain",
	url         => "https://github.com/horgh/irssi-scripts",
	changed     => $VERSION,
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

sub db_select_array {
	my ($sql, $params) = @_;
	if (!defined $sql || length $sql == 0 || !$params) {
		&log('Invalid parameter');
		return undef;
	}

	my $sth = &db_query($sql, $params);
	if (!$sth) {
		&log('Failed to execute query');
		return undef;
	}

	my $rows = $sth->fetchall_arrayref;
	if (!$rows) {
		&log('Fetchall failed');
		return undef;
	}
	if ($sth->err) {
		&log('Fetchall failed (2)');
		return undef;
	}
	return $rows;
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
	my $date;
	if (defined $quote_href->{ create_time}) {
		my $datetime = DateTime::Format::Pg->parse_timestamptz(
			$quote_href->{create_time});
		$datetime->set_time_zone($TIME_ZONE);
		$date = $datetime->strftime("%Y-%m-%d %H:%M:%S %z");
	} else {
		$date = 'missing';
	}
	my $date_header = "Date: $date";
	&msg($server, $target, $date_header);

	# added by line
	my $added_by = "Added by:";
	if (defined $quote_href->{ added_by }) {
		$added_by .= ' ' . $quote_href->{ added_by };
	}
	&msg($server, $target, $added_by);

	foreach my $line (split /\n|\r/, $quote_href->{quote}) {
		chomp $line;
		next if $line =~ /^\s*$/;
		&msg($server, $target, " $line");
	}

	if (exists $quote_href->{ image } && length $quote_href->{ image } > 0) {
		# Expect the image path to be URI safe.
		my $url = $QUOTE_URL . $quote_href->{ image };
		&msg($server, $target, " Image: $url");
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
SELECT * FROM quote
WHERE 1=1 / . &_sensitive_sql($target) . qq/
ORDER BY id DESC LIMIT 1
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
# @param string $pattern Search string
#
# @return void
#
# find the latest quote with the given search string and spew it
sub quote_latest_search {
	my ($server, $target, $pattern) = @_;
	if (!$server || !$target || !defined $pattern) {
		&log("invalid param");
		return;
	}

	# convert to sql wildcard
	my $sql_pattern = &sql_like_escape($pattern);

	my $sql = qq/
SELECT * FROM quote
WHERE quote ILIKE ?
/ . &_sensitive_sql($target) . qq/
ORDER BY id DESC
LIMIT 1
/;
	my @params = ($sql_pattern);
	my $href = &db_select($sql, \@params);
	if (!$href || !%$href) {
		&msg($server, $target, "No quotes found matching *$pattern*.");
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
SELECT * FROM quote
WHERE 1=1 / . &_sensitive_sql($target) . qq/
ORDER BY random() LIMIT 20
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
/ . &_sensitive_sql($target) . qq/
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

# @param string $pattern Search string pattern
#
# @return string the pattern escaped and wrapped in sql LIKE wildcards
#
# escape a string that will be used as the pattern for an sql LIKE
# query. also wrap the query in % so we do wildcard matching correctly,
# and translate '*' to '%'.
sub sql_like_escape {
	my ($pattern) = @_;
	if (!defined $pattern) {
		&log("invalid param");
		return '';
	}

	# _ and % are special characters for ILIKE, so escape them.
	$pattern =~ s/(_|%|\\)/\\$1/g;
	# we want *$pattern*
	$pattern = "%$pattern%";
	# we use '*' wildcarding.
	$pattern =~ s/\*/%/g;

	return $pattern;
}

# @param server $server
# @param string $target
# @param string $pattern Search string
#
# @return void
sub quote_search {
	my ($server, $target, $pattern) = @_;
	if (!$server || !$target || !defined $pattern) {
		&log("invalid param");
		return;
	}

	my $sql_pattern = &sql_like_escape($pattern);

	# check whether the global cache has a result for this search
	if (!$search_quotes || !exists $search_quotes->{$pattern}) {
		&log("Fetching new quotes for search: *$pattern*");
		my $sql = qq/
SELECT * FROM quote
WHERE quote ILIKE ?
/ . &_sensitive_sql($target) . qq/
ORDER BY id ASC
/;
		my @params = ($sql_pattern);
		my $href = &db_select($sql, \@params);
		if (!$href || !%$href) {
			&msg($server, $target, "No quotes found matching *$pattern*.");
			return;
		}

		# place the result in the global cache
		$search_quotes->{$pattern} = $href;
	}

	# pull a result out of the global cache
	my $id = (keys %{$search_quotes->{$pattern}})[0];
	my $quote_href = $search_quotes->{$pattern}->{$id};
	delete $search_quotes->{$pattern}->{$id};

	# remove the cache key for this search if there are none remaining
	my $count_left = scalar (keys %{$search_quotes->{$pattern}});
	delete $search_quotes->{$pattern} if $count_left == 0;

	# Record that we showed this quote from a search.
	# This is to track popular quotes.
	# I don't check success here because either way I want to proceed.
	&_record_quote_was_searched($quote_href->{ id });

	&spew_quote($server, $target, $quote_href, $count_left, $pattern);
}

# Record into the database that someone searched for and found this quote.
# The purpose is to be able to look at this afterwards for popular quotes.
#
# Parameters:
# quote_id: Integer referring to a quote id in the database
#
# Returns: Boolean, whether we recorded successfully.
sub _record_quote_was_searched {
	my ($quote_id) = @_;
	if (!defined $quote_id) {
		&log("_record_quote_was_searched: Missing quote identifier");
		return 0;
	}

	my $sql = 'INSERT INTO quote_search(quote_id) VALUES(?)';
	my @params = ($quote_id);

	my $row_count = &db_manipulate($sql, \@params);
	if (!defined $row_count || $row_count != 1) {
		&log("_record_quote_was_searched: Unable to insert");
		return 0;
	}

	return 1;
}

# @param server $server
# @param string $target
# @param string $pattern Search string
#
# @return void
sub quote_count {
	my ($server, $target, $pattern) = @_;
	if (!$server || !$target || !defined $pattern) {
		&log("invalid param");
		return;
	}

	my $sql_pattern = &sql_like_escape($pattern);

	# get the count of quotes matching the pattern
	my $sql = qq/
SELECT COUNT(1) FROM quote WHERE LOWER(quote) LIKE LOWER(?)
/;
	my @params = ($sql_pattern);
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
		"There are $count/$total_count ($percent%) quotes matching *$pattern*.");
}

sub quote_added_by_top {
	my ($server, $target) = @_;
	if (!$server || !$target) {
		&log("invalid parameter");
		return;
	}
	my $sql = '
		SELECT added_by, COUNT(quote) AS count
		FROM quote
		WHERE added_by IS NOT NULL
		GROUP BY(added_by)
		ORDER BY count DESC
		LIMIT 5
	';
	my @params;
	my $rows = &db_select_array($sql, \@params);
	if (!$rows) {
		&log('Unable to retrieve rows');
		return;
	}

	&msg($server, $target, "Top quote adders (all time):");
	foreach my $row (@{ $rows }) {
		my ($name, $count) = @{ $row };
		my $msg = " $name: $count";
		&msg($server, $target, $msg);
	}
}

sub quote_added_by_top_days {
	my ($server, $target, $days) = @_;
	if (!$server || !$target || !defined $days) {
		&log("invalid parameter");
		return;
	}
	my $sql = '
		SELECT added_by, COUNT(quote) AS count
		FROM quote
		WHERE added_by IS NOT NULL AND
		create_time IS NOT NULL AND
		create_time > now() - ?::interval
		GROUP BY(added_by)
		ORDER BY count DESC
		LIMIT 5
	';
	my @params = ("$days days");
	my $rows = &db_select_array($sql, \@params);
	if (!$rows) {
		&log('Unable to retrieve rows');
		return;
	}

	&msg($server, $target, "Top quote adders (past $days days):");
	foreach my $row (@{ $rows }) {
		my ($name, $count) = @{ $row };
		my $msg = " $name: $count";
		&msg($server, $target, $msg);
	}
}

sub quote_rank {
	my ($server, $target, $rank) = @_;
	if (!$server || !$target || !defined $rank) {
		&log("quote_rank: Invalid parameter");
		return;
	}

	# Find the n'th most popular quote and display it.
	# Rank 1 means the #1 most popular.

	my $sql = q/
		SELECT

		COUNT(*) AS count,
		q.id AS id,
		q.quote AS quote,
		q.create_time AS create_time,
		q.added_by AS added_by,
		q.image

		FROM quote_search qs
		LEFT JOIN quote q
		ON q.id = qs.quote_id

		WHERE 1=1 / . &_sensitive_sql($target) . q/

		GROUP BY q.id

		ORDER BY count DESC, q.id ASC
		LIMIT 1 OFFSET ?
	/;

	my @params = ($rank-1);

	my $rows = &db_select_array($sql, \@params);
	if (!$rows) {
		&log("quote_rank: Select failure");
		return;
	}

	if (@{ $rows } == 0) {
		&msg($server, $target, "Quote not found.");
		return;
	}

	my $quote = {
		id          => $rows->[0][1],
		quote       => $rows->[0][2],
		create_time => $rows->[0][3],
		added_by    => $rows->[0][4],
	};

	my $votes = $rows->[0][0];

	my $msg = "#$rank most popular quote (" . $votes;
	$msg .= " search" if $votes == 1;
	$msg .= " searches" if $votes != 1;
	$msg .= "):";
	&msg($server, $target, $msg);
	&spew_quote($server, $target, $quote, undef, undef);
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
	$msg =~ s/^\s+|\s+$//g;

	# NOTE: we handle case insensitivity in a function above this as
	#       we cannot trigger on 'Quote' for self messages (else output
	#       of the quote triggers on itself).

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

	# quoteaddedbytop
	return &quote_added_by_top($server, $target) if $msg =~ /^!?quoteaddedbytop$/;

	# quoteaddedbytop <days>
	return &quote_added_by_top_days($server, $target, $1)
		if $msg =~ /^!?quoteaddedbytop\s+(\d+)$/;

	# quoterank
	if ($msg =~ /^!?quoterank$/i) {
		my $rank = 1;
		return &quote_rank($server, $target, $rank);
	}

	if ($msg =~ /^!?quoterank\s+(\d+)$/i) {
		my $rank = ($1);
		return &quote_rank($server, $target, $rank);
	}
}

sub _sensitive_sql {
	my ($channel) = @_;
	if (&_channel_includes_sensitive($channel)) {
		return '';
	}

	return ' AND sensitive = false ';
}

sub _channel_includes_sensitive {
	my ($channel) = @_;
	return &channel_in_settings_str('quote_channels_sensitive', $channel);
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

# Channels where quote triggers work.
Irssi::settings_add_str('quote', 'quote_channels', '');
# Channels where we include display quotes.
Irssi::settings_add_str('quote', 'quote_channels_sensitive', '');

# timer to clear the quote cache every 24 hours.
# timer takes time to run in milliseconds.
Irssi::timeout_add(24*60*60*1000, 'clear_quote_cache', '');
