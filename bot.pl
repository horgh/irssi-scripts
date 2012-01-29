#
# 21/1/2012
# will@summercat.com
#
# Simple botnet like behaviour
#
# All channels the client is in and set in the setting 'bot_channels' will
# be treated as botnet channels.
#
# If the client isn't an op in a bot channel it will request to be opped.
#
# All clients must have the same network name for each network for this
# to function.
#
# All bots in a defined command channel will try to op each other.
#
# This works as follows:
#  - periodically look at every bot channel we are in
#  - if we are not opped in a channel, find our command channel
#  - if we are not in the command channel, nothing to do
#  - if we are in the command channel, send an op request which includes
#    channel name, our nick, and the network
#  - all bots other than self try to op me there if they are opped there
#
# Requirements:
# - Crypt::OpenSSL::RSA - libcrypt-openssl-rsa-perl
#

use warnings;
use strict;
use Irssi;
use Crypt::OpenSSL::RSA ();
use Time::Local ();
use MIME::Base64 ();

#
# config
#

# check every delay seconds
my $delay = 10;
# bot private + public key file
my $my_key_file = Irssi::get_irssi_dir . '/bot.keys';
# bot public key file
my $pubkey_file = Irssi::get_irssi_dir . '/bot.pubkeys';
# accept commands given within this number of seconds
my $acceptable_delay = 30;
# script used to verify sigs
my $verify_script = Irssi::get_irssi_dir . '/bot_verify.pl';

#
# done config
#

# timeout tag (from timeout_add())
my $timeout_tag;
# bot pubkeys
my @pubkeys = ();
# my priv/pub key
my $privkey;
my $pubkey;

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

  # time
  my $time = Time::Local::timegm(gmtime());

  # build the message we will send
  my $msg = "opme $network $channel_name $nick $time";

  # sign it
  my $rsa = Crypt::OpenSSL::RSA->new_private_key($privkey);
  my $signed_msg = $rsa->sign($msg);

  # base64 encode whole thing (signature is non-ascii)
  # (second param to encode is separator)
  my $base64 = MIME::Base64::encode_base64("$msg $signed_msg", "");

  # send it
  $command_server->command("MSG $c_channel_name $base64");
  return;
}

# @return mixed array ref of channel objects or undef if failure
#
# look at the setting 'bot_channels' and find the channel objects
# associated with them
#
# if a channel name is on multiple servers, return each one.
sub get_bot_channels {
  my @channels;
  my $bot_channels_s = Irssi::settings_get_str('bot_channels');
  foreach my $channel_name (split(/ /, $bot_channels_s)) {
    # clean up the name
    $channel_name = lc($channel_name);
    $channel_name =~ s/^\s+//g;
    $channel_name =~ s/\s+$//g;
    next unless $channel_name;

    # find the channel objects on every server we are on
    foreach my $server (Irssi::servers()) {
      my $channel = $server->channel_find($channel_name);
      push(@channels, $channel) if $channel;
    }
  }
  return \@channels;
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

  # get the bot channels
  my $channels_aref = &get_bot_channels;
  if (!$channels_aref || !@$channels_aref) {
    &log("bot_loop: no bot channels found");
    return;
  }

  # loop over every bot channel we are in
  foreach my $channel (@$channels_aref) {
    # don't do anything with command channel
    next if $channel->{name} eq $c_channel->{name} && $channel->{server}->{chatnet} eq $c_channel->{server}->{chatnet};

    # if we're not opped, request op
    &request_op($command_server, $c_channel, $channel) if !$channel->{chanop};
  }
  return;
}

# @param string $string
# @param string $signature
#
# @return int 1 valid 0 invalid
#
# check whether the given string and signature are valid based on one of
# our known pubkeys
sub valid_signature {
  my ($string, $signature) = @_;

  if (!$string || !$signature) {
    &log("valid_signature: invalid param");
    return 0;
  }

  if (! -f $verify_script || ! -x $verify_script) {
    &log("valid_signature: cannot find verify script at $verify_script");
    return 0;
  }

  #&log("valid_signature: string: $string signature: $signature");

  # open process to verify script to pipe stdin
  my $fh;
  if (!open($fh, '|-', $verify_script)) {
    &log("valid_signature: failed to open process");
    return 0;
  }
  # print each pubkey to its stdin
  foreach my $pubkey (@pubkeys) {
    print { $fh } "$pubkey\n\n";
  }
  # and the plaintext
  print { $fh } "$string\n";
  # and the signature in base64 (since it could have newlines in it)
  my $signature_b64 = MIME::Base64::encode_base64("$signature", "");
  print { $fh } "$signature_b64";
  # returns false if nonzero exit code when using a process
  if (!close($fh)) {
    &log("valid_signature: failed to verify signature: exit code $? " . ($? & 127));
    return 0;
  }
  return 1;

  # XXX old way
  # check it against every signature we know about
  foreach my $pubkey (@pubkeys) {
    &log("valid_signature: pubkey: $pubkey");

    # wrap in eval since it can kill us
    my $res = eval {
      #no warnings 'all';
      no warnings;
      my $rsa = Crypt::OpenSSL::RSA->new_public_key($pubkey);
      # this will be return value
      $rsa->verify($string, $signature);
    };
    # if error, this var is set
    if ($@) {
      &log("valid_signature: rsa failed: $@");
      next;
    }
    if ($res) {
      return 0;
      #return 1;
    }
  }
  return 0;
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
  # should be: 'network channel nick time signature'
  my $chatnet;
  my $channel_name;
  my $nick;
  my $time;
  my $signature;
  if ($params =~ /^(\S+) (\S+) (\S+) (\d+) (.*)$/s) {
    $chatnet = $1;
    $channel_name = $2;
    $nick = $3;
    $time = $4;
    $signature = $5;
  } else {
    &log("do_opme: invalid opme params");
    return;
  }

  &log("do_opme: Trying to op $nick on $channel_name @ $chatnet");

  # time must be within delta of current time for the command to be valid
  my $current_time = Time::Local::timegm(gmtime());
  if ($current_time - $time > $acceptable_delay) {
    &log("do_opme: Invalid time in opme request, ignoring.");
    return;
  }

  # verify the signature vs. the signed string
  my $string = "opme $chatnet $channel_name $nick $time";
  if (!&valid_signature($string, $signature)) {
    &log("do_opme: Invalid signature found, ignoring.");
    return;
  }

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

  # commands will be base64 decoded
  my $decoded = MIME::Base64::decode_base64($msg);
  return unless $msg;
  #&log("sig_msg_pub: decoded: $decoded");
  
  # parse the command
  if ($decoded =~ /^(\S+) ?(.*)$/s) {
    my $command = $1;
    my $params = $2;

    if ($command eq 'opme') {
      &do_opme($2);
    }
  }
  return;
}

# @return void
#
# generate a keypair and save it
sub generate_keys {
  if (-f $my_key_file) {
    &log("generate_keys: key file already exists, aborting");
    return;
  }

  # generate the keypair
  &log("generate_keys: generating new keypair...");
  my $rsa = Crypt::OpenSSL::RSA->generate_key(1024);

  # write them to disk
  my $fh;
  if (!open($fh, '>', $my_key_file)) {
    &log("generate_keys: could not open $my_key_file: $?");
    return;
  }

  print { $fh } $rsa->get_private_key_string;
  print { $fh } "\n";
  print { $fh } $rsa->get_public_key_string;
  close $fh;
}

# @param aref $linesAref
#
# @return mixed aref of strings or undef if failure
#
# split an array of lines into strings on blank lines
sub split_on_blank_line {
  my ($linesAref) = @_;
  if (!$linesAref || !@$linesAref) {
    &log("split_on_blank_line: invalid param");
    return undef;
  }

  my @strings = ();
  my $s = '';
  foreach (@$linesAref) {
    if (/^\s*$/) {
      push(@strings, $s);
      $s = '';
      next;
    }
    $s .= $_;
  }
  # last key
  push(@strings, $s) if $s;

  return \@strings;
}

# @param string $fname
#
# @return mixed aref of lines from file or undef if failure
#
# read all of a file
sub read_in_file {
  my ($fname) = @_;
  if (!$fname) {
    &log("read_in_file: invalid filename");
    return undef;
  }
  # load our keys from the file
  my $fh;
  if (!open($fh, '<', $fname)) {
    &log("read_in_file: failed to open file: $fname: $?");
    return undef;
  }
  my @lines = <$fh>;
  close $fh;
  return \@lines;
}

# @return int 1 success 0 failure
#
# load our keypair
sub load_my_keys {
  # if we don't have a key file for ourself, generate
  if (! -f $my_key_file) {
    &generate_keys;
  }

  # now we should have a key file. read it
  my $linesAref = &read_in_file($my_key_file);
  if (!$linesAref || !@$linesAref) {
    &log("load_my_keys: failed to get content of my key file");
    return 0;
  }

  # split on a blank line (private, blank line, public)
  my $keysAref = &split_on_blank_line($linesAref);
  if (!$keysAref || !@$keysAref || scalar(@$keysAref) != 2) {
    &log("load_my_keys: did not find necessary keys");
    return 0;
  }

  $privkey = $keysAref->[0];
  $pubkey = $keysAref->[1];
  &log("load_my_keys: loaded my keypair.");
  return 1;
}

# @return int 1 success 0 failure
#
# load other bot pubkeys
sub load_pubkeys {
  if (! -f $pubkey_file || ! -r $pubkey_file) {
    &log("load_pubkeys: pubkey file not found: $pubkey_file");
    return 0;
  }

  # read content of file
  my $linesAref = &read_in_file($pubkey_file);
  if (!$linesAref || !@$linesAref) {
    &log("load_pubkeys: no pubkeys found");
    return 0;
  }

  # keys are separated by a blank line
  my $keysAref = &split_on_blank_line($linesAref);
  if (!$keysAref || !@$keysAref) {
    &log("load_pubkeys: no pubkeys found (2)");
    return 0;
  }

  my $count = 0;
  foreach my $key (@$keysAref) {
    chomp $key;
    push(@pubkeys, $key);
    ++$count;
  }
  &log("cmd_load_bot_keys: $count public keys loaded.");
  return 1;
}

# @return void
#
# load our private + public key and public keys for all bots
sub cmd_load_bot_keys {
  my ($data, $server, $witem) = @_;

  @pubkeys = ();
  $privkey = '';
  $pubkey = '';

  # load my priv/pub key
  if (!&load_my_keys) {
    &log("cmd_load_bot_keys: failed to load my keys");
    return;
  }

  # load other bot keys
  &load_pubkeys;
}

$timeout_tag = Irssi::timeout_add($delay * 1000, 'bot_loop', undef);
Irssi::signal_add('message public', 'sig_msg_pub');

# command channel
Irssi::settings_add_str('bot', 'bot_command_channel', '');
Irssi::settings_add_str('bot', 'bot_command_network', '');
# channels to act as bot in
Irssi::settings_add_str('bot', 'bot_channels', '');

# commands
Irssi::command_bind('load_bot_keys', 'cmd_load_bot_keys');

# load keys on load
&cmd_load_bot_keys;
