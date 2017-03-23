#
# Unit tests for sqlquote.pl
#

use strict;
use warnings;

# I'd rather avoid splitting out Irssi scripts into multiple files. Let's try
# including the script's functions this way to get around having to split out
# a module. Yes, this is hacky.
do './sqlquote.pl';

exit(&main ? 0 : 1);

sub main {
	my $success = 1;

	if (!&test_sql_like_escape) {
		$success = 0;
	}

	if (!$success) {
		print "Some tests failed\n";
		return 0;
	}

	print "All tests succeeded\n";
	return 1;
}

sub test_sql_like_escape {
  my @tests = (
    {
      input  => 'abc',
      output => '%abc%',
    },
    {
      input  => 'ab%_\\c',
      output => '%ab\\%\\_\\\\c%',
    },
    {
      input  => '%_\\',
      output => '%\\%\\_\\\\%',
    },
    {
      input  => '%_\\%_\\',
      output => '%\\%\\_\\\\\\%\\_\\\\%',
    },
    {
      input  => '%_*\\%_*\\',
      output => '%\\%\\_%\\\\\\%\\_%\\\\%',
    },
  );

  my $failures = 0;

  foreach my $test (@tests) {
    my $output = sql_like_escape($test->{ input });
    if ($output ne $test->{ output }) {
      print "FAILURE: sql_like_escape($test->{ input }) = $output, wanted $test->{ output }\n";
      $failures++;
      next
    }
  }

  if ($failures == 0) {
    return 1;
  }

  print "TEST FAILURES: $failures/" . scalar(@tests) . " sql_like_escape tests failed\n";
  return 0;
	return 1;
}
