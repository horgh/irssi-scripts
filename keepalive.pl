#
# this script is to send a message to yourself every N seconds.
# the rationale I have for it is my raspberry pi seems to drop connection
# consistently. if I do this then the connection stays up, yay.
#

use warnings;
use strict;

use Irssi;

my $DELAY = 10;

use vars qw($VERSION %IRSSI);
$VERSION = '20140609';

%IRSSI = (
	authors     => "Will Storey",
	contact     => "will\@summercat.com",
	name        => "keepalive",
	description => "keep connections alive by messaging yourself",
	license     => "Public domain",
	url         => "http://www.summercat.com",
	changed     => $VERSION
);

# suppress the Irssi::Nick warnings...
# see http://bugs.irssi.org/index.php?do=details&task_id=242
# and http://pound-perl.pm.org/code/irssi/autovoice.pl
{ package Irssi::Nick }

# message myself on every serer I'm on!
sub keepalive_message_self {
	foreach my $server (Irssi::servers()) {
		my $nick = $server->{nick};
		$server->command("MSG $nick hi");
	}
}

# first parameter is time in milliseconds.
Irssi::timeout_add($DELAY * 1000, 'keepalive_message_self', '');
