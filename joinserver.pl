#
# 01/01/2012
# will@summercat.com
#
# Watch joins to channels and alert when a user is found to be on an IRC
# server different than the set one.
#
# Primarily for security: maintain all users on a channel on one server which
# is assumed to be secure, so that no traffic leaves the server other than
# to the channel members.
#
# While this can be achieved with & channels or a mode enforcing SSL, some
# servers do not support the SSL mode (as on the network I use it on), and
# changing to an &channel is not an option.
#
# To add channels to watch:
# /set joinserver_channels #channel1 #channel2
#
# To add servers which will not warn:
# /set joinserver_servers irc.server1.com irc.server2.com
#
# Anyone who joins #channel1 or #channel2 triggers a warning
# unless they are on either irc.server1.com or irc.server2.com
#

use warnings;
use strict;

use Irssi;

use vars qw($VERSION %IRSSI);
$VERSION = "20120101";
%IRSSI = (
	authors     => "Will Storey",
	contact     => "will\@summercat.com",
	name        => "joinserver",
	description => "warn when users join a channel from certain servers",
	license     => "Public domain",
	url         => "http://www.summercat.com",
	changed     => $VERSION
);

# @return aref    Array ref of channel names
#
# Retrieve channels we want to check
sub get_channels {
  my $setting = Irssi::settings_get_str('joinserver_channels');
  my @channels = split /\s+/, $setting;
  return \@channels;
}

# @return aref    Array of server names
sub get_servers {
  my $setting = Irssi::settings_get_str('joinserver_servers');
  my @servers = split /\s+/, $setting;
  return \@servers;
}

# @param server $server
# @param string $channel
# @param string $nick
# @param string $address
#
# @return void
#
# Called when a join occurs
sub sig_message_join {
  my ($server, $channel, $nick, $address) = @_;
  my $channels_aref = &get_channels;

  return unless $channels_aref && @$channels_aref;
  return unless grep(/^$channel$/, @$channels_aref);

  Irssi::print("joinserver: checking server of $nick ($channel)...");

  # send the whois
  # we use redirects to capture its output
  $server->redirect_event(
      # name of registered redirect
      'whois',
      # how many times to redirect
      1,
      # argument to compare with
      $nick,
      # specify if remote command, -1 = default
      -1,
      # failure signal
      "",
      # signals
      {
        # server line in whois
        "event 312" => "redir joinserver whois",
        # ignore the rest
        "" => "event empty",
      }
    );
  $server->send_raw("WHOIS :$nick");
  # Now signal redir joinserver whois will be triggered
}

# @param server $server
# @param string $text
#
# @return void
#
# Called as a result of whois on a join to a watched channel
sub sig_redir_joinserver_whois {
  my ($server, $text) = @_;

  # get the server out of the text
  my @whois_server_args = split / /, $text;
  if (scalar(@whois_server_args) < 3) {
    Irssi::print("joinserver: invalid whois server line: $text");
    return;
  }
  my $whois_nick = $whois_server_args[1];
  my $whois_server = $whois_server_args[2];

  # get the servers we don't warn on
  my $servers_aref = &get_servers;
  if (!$servers_aref || !@$servers_aref) {
    Irssi::print("joinserver: WARNING: no servers set.");
    return;
  }

  # warn if it's not in our good servers
  if (!grep(/^$whois_server$/, @$servers_aref)) {
    Irssi::print("joinserver: WARNING $whois_nick is on $whois_server.");
    return;
  }
}

# Register redirects
# We need to capture server line of a whois
# XXX Not needed... but may as well keep to see use
Irssi::Irc::Server::redirect_register(
    'joinserver whois',
    0,
    0,
    # start events
    {
      "event 311" => -1, # beginning of whois 
    },
    # stop events
    {
      "event 318" => -1, # end of whois
    },
    # optional events
    {}
  );

Irssi::signal_add('message join', 'sig_message_join');
Irssi::signal_add('redir joinserver whois', 'sig_redir_joinserver_whois');

Irssi::settings_add_str('joinserver', 'joinserver_servers', '');
Irssi::settings_add_str('joinserver', 'joinserver_channels', '');
