#
# This script provides in-channel interaction with a database of quotes. This
# includes things like searching and displaying quotes in the channel.
#
# It retrieves the quotes from a database using the DBI library. Currently the
# script is written specifically for a PostgreSQL database. The schema is below.
#
# This script does not support adding quotes. To do that use
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
#  -- Optional title for the quote
#  title VARCHAR,
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
#   nick VARCHAR,
#   PRIMARY KEY (id)
# );
#

use warnings;
use strict;

use DateTime::Format::Pg ();
use DBI ();
use Irssi ();

use vars qw($VERSION %IRSSI);
$VERSION = "20170311";
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

# Search quote cache: pattern (string) -> array reference containing hash
# references. Each hash reference element is one quote. They are ordered by
# create date, ascending.
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
		my $db_host = Irssi::settings_get_str('quote_db_host');
		my $db_name = Irssi::settings_get_str('quote_db_name');
		my $db_user = Irssi::settings_get_str('quote_db_user');
		my $db_pass = Irssi::settings_get_str('quote_db_pass');

		if (length $db_host == 0 || length $db_name == 0 || length $db_user == 0 ||
			length $db_pass == 0) {
			&log("Missing database settings. See /set quote");
			return undef;
		}

		my $dsn = "dbi:Pg:dbname=$db_name;host=$db_host";
		$dbh = DBI->connect($dsn, $db_user, $db_pass);
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
	# left and search are optional.
	if (!$server || !defined $target || length $target == 0 || !$quote_href) {
		&log("spew_quote: Invalid parameter");
		return;
	}

	my $header = "Quote #\002" . $quote_href->{ id } . "\002";
	$header .= " ($left left)" if defined $left;
	$header .= ": *$search*" if defined $search;
	&msg($server, $target, $header);

	# Title line
	if (defined $quote_href->{ title }) {
		&msg($server, $target, $quote_href->{ title });
	} else {
		&msg($server, $target, 'No title');
	}

	# Date line
	my $date;
	if (defined $quote_href->{ create_time}) {
		my $datetime = DateTime::Format::Pg->parse_timestamptz(
			$quote_href->{ create_time });

		my $time_zone = Irssi::settings_get_str('quote_timezone');
		if (length $time_zone > 0) {
			$datetime->set_time_zone($time_zone);
		}

		$date = $datetime->strftime("%Y-%m-%d %H:%M:%S %z");
	} else {
		$date = 'missing';
	}
	my $date_header = "Date: $date";
	&msg($server, $target, $date_header);

	# Added by line
	my $added_by = "Added by:";
	if (defined $quote_href->{ added_by }) {
		$added_by .= ' ' . $quote_href->{ added_by };
	}
	&msg($server, $target, $added_by);

	foreach my $line (split /\n|\r/, $quote_href->{ quote }) {
		chomp $line;
		next if $line =~ /^\s*$/;
		&msg($server, $target, " $line");
	}

	if (exists $quote_href->{ image } && defined $quote_href->{ image } &&
		length $quote_href->{ image } > 0) {
		my $site_url = Irssi::settings_get_str('quote_site_url');
		$site_url =~ s/\/$//g;
		if (length $site_url > 0) {
			# We expect the image path to be URI safe.
			my $image_url = $site_url . '/' . $quote_href->{ image };
			&msg($server, $target, " Image: $image_url");
		}
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
# @param string $nick The nick performing the search
# @param string $target
# @param string $pattern Search string
#
# @return void
#
# find the latest quote with the given search string and spew it
sub quote_latest_search {
	my ($server, $nick, $target, $pattern) = @_;
	if (!$server || !defined $nick || length $nick == 0 || !$target ||
		!defined $pattern) {
		&log("quote_latest_search: Invalid parameter");
		return;
	}

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

	&_record_quote_was_searched($quote_href->{ id }, $nick);
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
# @param string $nick The nick performing the search
# @param string $target
# @param int $id         Quote id to fetch
#
# @return void
sub quote_id {
	my ($server, $nick, $target, $id) = @_;
	if (!$server || !defined $nick || length $nick == 0 || !$target ||
		!defined $id) {
		&log("quote_id: Invalid parameter");
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

	&_record_quote_was_searched($quote_href->{ id }, $nick);
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

# Search for quotes matching a *pattern*, and output one.
#
# This function caches all quotes matching the given pattern, and first checks
# the cache for a result before going to the database. For one thing, this
# allows us to easily cycle through all the results.
#
# This function outputs quotes in order of when they were added, ascending. If
# a quote doesn't have an add date set, it uses an arbitrary date far in the
# past.
#
# @param server $server
# @param string $nick The nick performing the search
# @param string $target
# @param string $pattern Search string
#
# @return void
sub quote_search {
	my ($server, $nick, $target, $pattern) = @_;
	if (!$server || !defined $nick || length $nick == 0 || !defined $target ||
		length $target == 0 || !defined $pattern || length $pattern == 0) {
		&log("quote_search: Invalid parameter");
		return;
	}

	# Check whether the global cache has quotes for this search. If it doesn't
	# query the database for quotes.
	if (!$search_quotes || !exists $search_quotes->{ $pattern }) {
		&log("Fetching new quotes for search: *$pattern*");

		my $sql_pattern = &sql_like_escape($pattern);
		my $sql = qq/
SELECT
id, create_time, quote, added_by, title, update_time, update_notes, sensitive,
	image
FROM quote
WHERE quote ILIKE ?
/ . &_sensitive_sql($target) . qq/
ORDER BY COALESCE(create_time, '1970-01-01') ASC, id ASC
/;
		my @params = ($sql_pattern);

		my $rows = &db_select_array($sql, \@params);
		if (!$rows) {
			&msg($server, $target, "Error performing the search.");
			return;
		}

		if (@{ $rows } == 0) {
			&msg($server, $target, "No quotes found matching *$pattern*.");
			return;
		}

		my @quotes;
		foreach my $row (@{ $rows }) {
			push @quotes, {
				id           => $row->[0],
				create_time  => $row->[1],
				quote        => $row->[2],
				added_by     => $row->[3],
				title        => $row->[4],
				update_time  => $row->[5],
				update_notes => $row->[6],
				sensitive    => $row->[7],
				image        => $row->[8],
			};
		}

		# Place the quotes in the global cache.
		$search_quotes->{ $pattern } = \@quotes;
	}

	# At this point there must be a quote available in the cache.

	# Pull a quote out of the global cache
	my $quote_href = $search_quotes->{ $pattern }[0];

	# Remove it.
	splice @{ $search_quotes->{ $pattern } }, 0, 1;

	# If there are no more quotes remaining in the cache, drop the key.
	my $count_left = scalar @{ $search_quotes->{ $pattern } };
	if ($count_left == 0) {
		delete $search_quotes->{ $pattern };
	}

	&spew_quote($server, $target, $quote_href, $count_left, $pattern);

	&_record_quote_was_searched($quote_href->{ id }, $nick);
}

# Record into the database that someone searched for and found this quote.
# The purpose is to be able to look at this afterwards for popular quotes.
#
# Parameters:
# quote_id: Integer referring to a quote id in the database
# nick: String. The nick of the person who searched.
#
# Returns: Boolean, whether we recorded successfully.
sub _record_quote_was_searched {
	my ($quote_id, $nick) = @_;
	if (!defined $quote_id) {
		&log("_record_quote_was_searched: Missing quote identifier");
		return 0;
	}
	if (!defined $nick || length $nick == 0) {
		&log("_record_quote_was_searched: Missing nick");
		return 0;
	}

	my $sql = 'INSERT INTO quote_search(quote_id, nick) VALUES(?, ?)';
	my @params = ($quote_id, $nick);

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
		q.title AS title,
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
		title       => $rows->[0][5],
		image       => $rows->[0][6],
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
# @param string $nick The nick performing the search
# @param string $target
# @param string $msg   Message on a channel enabled for triggers
#
# @return void
sub handle_command {
	my ($server, $nick, $target, $msg) = @_;
	if (!$server || !defined $nick || length $nick == 0 || !$target ||
		!defined $msg) {
		&log("handle_command: Invalid parameter");
		return;
	}

	$msg =~ s/^\s+|\s+$//g;

	# NOTE: We handle case insensitivity in the signal handlers (callers of this
	# function) as we do not want to trigger on 'Quote' for messages we send
	# ourselve. If we did, quote output would trigger itself.

	# quotestats
	return &quote_stats($server, $target)if $msg =~ /^!?quotestats$/;

	# latest
	return &quote_latest($server, $target) if $msg =~ /^!?latest$/;

	# latest <search string>
	return &quote_latest_search($server, $nick, $target, $1)
		if $msg =~ /^!?latest\s+(.+)$/;

	# quote
	return &quote_random($server, $target) if $msg =~ /^!?quote$/;

	# quote <#>
	return &quote_id($server, $nick, $target, $1) if $msg =~ /^!?quote\s+(\d+)$/;

	# quote <search string>
	return &quote_search($server, $nick, $target, $1) if $msg =~ /^!?quote\s+(.+)$/;

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

	&handle_command($server, $nick, $target, $msg);
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

	&handle_command($server, $server->{ nick }, $target, $msg);
}

Irssi::signal_add('message public', 'sig_msg_pub');
Irssi::signal_add('message own_public', 'sig_msg_own_pub');

# Database host.
Irssi::settings_add_str('quote', 'quote_db_host', '');

# Database name.
Irssi::settings_add_str('quote', 'quote_db_name', '');

# Database user.
Irssi::settings_add_str('quote', 'quote_db_user', '');

# Database pass.
Irssi::settings_add_str('quote', 'quote_db_pass', '');

# Time zone to display quote dates in.
Irssi::settings_add_str('quote', 'quote_timezone', 'America/Vancouver');

# Channels where quote triggers work.
Irssi::settings_add_str('quote', 'quote_channels', '');

# Channels where we include quotes that might be sensitive for display.
Irssi::settings_add_str('quote', 'quote_channels_sensitive', '');

# URL to the quote site. We use this to generate image URL on quotes with
# images.
Irssi::settings_add_str('quote', 'quote_site_url', '');

# timer to clear the quote cache every 24 hours.
# timer takes time to run in milliseconds.
Irssi::timeout_add(24*60*60*1000, 'clear_quote_cache', '');
