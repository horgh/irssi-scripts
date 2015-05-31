#
# this script is to send a message to yourself every N seconds.
# the rationale I have for it is my raspberry pi seems to drop connection
# consistently. if I do this then the connection stays up, yay.
#
# the idea is we need to exercise the connection between the raspberry
# pi server and the server it is linked to. connections to clients seem
# to remain already.
#

use warnings;
use strict;

use Irssi;

# delay in seconds between keepalive messages
my $DELAY = 10;
# channel to send keepalive messages to.
# note you must ensure a client from another server you want to keep
# the connection alive to is in this channel so that the connection
# gets used.
my $CHANNEL = '#keepalive';

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
		$server->command("MSG $CHANNEL h");
	}
}

# first parameter is time in milliseconds.
Irssi::timeout_add($DELAY * 1000, 'keepalive_message_self', '');
