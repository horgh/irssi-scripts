#
# 21/1/2012
# will@summercat.com
#
# Simple botnet like behaviour
#
# All channels the client is in will be treated as botnet channels.
# If the client isn't an op in a channel it will request to be opped.
# All clients must have the same network name for each network for this
# to function.
#
# All bots in a defined command channel will try to op each other
#
# This works as follows:
#  - periodically look at every channel we are in
#  - if we are not opped in a channel, find our command channel
#  - if we are not in the command channel, nothing to do
#  - if we are in the command channel, send an op request which includes
#    channel name and our nick
#  - all bots other than self try to op me there if they are opped
#

use warnings;
use strict;
use Irssi;

#
# config
#

# check every delay seconds
my $delay = 120;

#
# done config
#

my $timeout_tag;

use vars qw($VERSION %IRSSI);
$VERSION = "20120121";
%IRSSI = (
	authors     => "Will Storey",
	contact     => "will\@summercat.com",
	name        => "bot",
	description => "simple botnet",
	license     => "Public domain",
	url         => "http://www.summercat.com",
	changed     => $VERSION
);

# suppress the Irssi::Nick warnings...
# see http://bugs.irssi.org/index.php?do=details&task_id=242
# and http://pound-perl.pm.org/code/irssi/autovoice.pl
{ package Irssi::Nick }

# @param string $msg
#
# @return void
sub log {
  my ($msg) = @_;
  Irssi::print("\002bot\002: $msg");
  return;
}

# @param server $command_server  server with command channel
# @param channel $c_channel      command channel
# @param channel $channel        channel to request ops on
#
# @return void
#
# request op on $channel
sub request_op {
  my ($command_server, $c_channel, $channel) = @_;

  &log("Requesting op on " . $channel->{name});

  if (!$command_server || !$c_channel || !$channel) {
    &log("request_op: invalid param");
    return;
  }

  # we need our nick on the channel we want ops in
  my $nick = $channel->{server}->{nick};
  if (!$nick) {
    &log("request_op: failed to find our nick on the channel we want ops in");
    return;
  }

  # and we need the network of the channel we want ops on
  my $network = $channel->{server}->{chatnet};
  if (!$network) {
    &log("request_op: failed to find network of channel we want ops in");
    return;
  }

  # and the name of the channel
  my $channel_name = $channel->{name};
  if (!$channel_name) {
    &log("request_op: failed to find channel name");
    return;
  }

  # command channel name
  my $c_channel_name = $c_channel->{name};
  if (!$c_channel_name) {
    &log("request_op: failed to find command channel name");
    return;
  }

  $command_server->command("MSG $c_channel_name opme $network $channel_name $nick");
  return;
}

# @return void
#
# main function which is called repeatedly
sub bot_loop {
  my $command_network = Irssi::settings_get_str('bot_command_network');
  my $command_channel = Irssi::settings_get_str('bot_command_channel');
  if (!$command_network || !$command_channel) {
    &log("bot_loop: command network or command channel not set!");
    return;
  }

  # find the command server
  my $command_server = Irssi::server_find_chatnet($command_network);
  if (!$command_server) {
    &log("bot_loop: failed to find server on command network");
    return;
  }

  # find the command channel
  my $c_channel = $command_server->channel_find($command_channel);
  if (!$c_channel) {
    &log("bot_loop: failed to find command channel");
    return;
  }

  # loop at every channel we are in
  my @channels = Irssi::channels;
  foreach my $channel (@channels) {
    # don't do anything with command channel
    next if $channel->{name} eq $c_channel->{name} && $channel->{server}->{chatnet} eq $c_channel->{server}->{chatnet};

    # if we're not opped, request op
    &request_op($command_server, $c_channel, $channel) if !$channel->{chanop};
  }
  return;
}

# @param string $params   portion of command after 'opme'
#
# @return void
#
# handle an op request from another bot
sub do_opme {
  my ($params) = @_;
  if (!$params) {
    &log("do_opme: invalid params");
    return;
  }

  # parse the params
  my $chatnet;
  my $channel_name;
  my $nick;
  if ($params =~ /^(\S+) (\S+) (\S+)$/) {
    $chatnet = $1;
    $channel_name = $2;
    $nick = $3;
  } else {
    &log("do_opme: invalid opme params");
    return;
  }

  &log("do_opme: Trying to op $nick on $channel_name @ $chatnet");

  # find the server for this chatnet
  my $server = Irssi::server_find_chatnet($chatnet);
  if (!$server) {
    &log("do_opme: failed to find network $chatnet");
    return;
  }

  # find the channel on this server
  my $channel = $server->channel_find($channel_name);
  if (!$channel) {
    &log("do_opme: failed to find channel $channel_name on $chatnet");
    return;
  }

  # check that we have ops there
  if (!$channel->{chanop}) {
    &log("do_opme: I am not opped in $channel_name on $chatnet");
    return;
  }

  # perform the op
  $server->command("MODE $channel_name +o $nick");
  return;
}

# @param server $server
# @param string $msg
# @param string $nick
# @param string $address
# @param string $target
#
# @return void
#
# handle commands in the command channel
sub sig_msg_pub {
  my ($server, $msg, $nick, $address, $target) = @_;
  # must be on command network & channel
  my $command_network = Irssi::settings_get_str('bot_command_network');
  my $command_channel = Irssi::settings_get_str('bot_command_channel');
  return unless $command_network && $command_channel;
  return unless $server->{chatnet} eq $command_network && $target eq $command_channel;
  if ($msg =~ /^(\S+) ?(.*)$/) {
    my $command = $1;
    my $params = $2;

    if ($command eq 'opme') {
      &do_opme($2);
    }
  }
}

$timeout_tag = Irssi::timeout_add($delay * 1000, 'bot_loop', undef);
Irssi::signal_add('message public', 'sig_msg_pub');

# command channel
Irssi::settings_add_str('bot', 'bot_command_channel', '');
Irssi::settings_add_str('bot', 'bot_command_network', '');
