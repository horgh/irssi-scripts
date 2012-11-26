#
# vim: tabstop=2:shiftwidth=2:expandtab
#
# 25/11/2012
# will@summercat.com
#
# run specified commands at specified times and output their results
# to specific nicks/channels.
#
# for instance, you may define that the command 'who' should be run at
# 0730 and 1630, and send the output to the channel #test on network with
# the tag 'testing'.
#
# times are compared against perl's localtime().
#
# config format is as follows:
# <network name #1>
# <channel name #1>
# <hh:mm #1>[,<hh:mm #2>] (24 hr. comma separated.)
# <command #1>
# <command #1 argument #1>
# <command #1 argument #2>
# ...
#
# <network name #2>
# ...
#
# where a blank line separates different commands.
#

use strict;
use warnings;

use lib $ENV{HOME} . '/perllib';

use Irssi ();

use WS;
use WS::Irssi;

# config file.
my $CONFIG = Irssi::get_irssi_dir . '/command_period.conf';
# aref of hrefs - each href describes a command.
my $COMMANDS;

# @param aref $lines   strings
#
# @return mixed aref of hrefs describing commands or undef if failure
#
# parse a command out of multiple lines in the format specified
# in the header comment
sub parse_command {
  my ($lines) = @_;
  if (!$lines) {
    irclog('error', "invalid parameter");
    return undef;
  }

  # must have at least 4 lines.
  if (@$lines < 4) {
    irclog('error', "invalid line count");
    return undef;
  }

  my ($network, $target, $time_string, @command) = @$lines;

  # parse the times and add the command at each time.
  my @commands;
  foreach my $time (split /,/, $time_string) {
    chomp $time;
    next unless length $time;

    if ($time !~ /^\s*([0-9]{2}):([0-9]{2})\s*$/) {
      irclog('error', "invalid time format: $time");
      return undef;
    }
    my ($hour, $minute) = ($1, $2);

    my $cmd = {
      network => $network,
      target => $target,
      hour => $hour,
      minute => $minute,
      command => \@command,
    };

    irclog('debug', "read command: network: $network target: $target"
      . " time: $hour:$minute command: " . join(' ', @command));
    push(@commands, $cmd);
  }

  return \@commands;
}

# @return mixed href of commands or undef if failure
#
# read the configuration file and return all commands along with the
# times to run each.
sub read_config {
  if (! -e $CONFIG || ! -r $CONFIG) {
    irclog('error', "cannot read config file: $CONFIG");
    return undef;
  }

  # read the file into memory.
  my $lines = read_file($CONFIG);
  if (!$lines) {
    irclog('error', "failed to read config file: $CONFIG");
    return undef;
  }

  # array of hrefs.
  my @commands;
  # parse it.
  my @commandLines;
  foreach my $line (@$lines) {
    # blank line - we have read in a command.
    if ($line =~ /^\s*$/) {
      my $commands = &parse_command(\@commandLines);
      if (!$commands) {
        irclog('error', "failed to parse command");
        return undef;
      }
      push(@commands, @$commands);
      @commandLines = ();
      next;
    }
    push(@commandLines, $line);
  }

  # may still have a command to parse (or may not if file ended
  # with a blank line).
  if (@commandLines) {
    my $commands = &parse_command(\@commandLines);
    if (!$commands) {
      irclog('error', "failed to parse final command");
      return undef;
    }
    push(@commands, @$commands);
  }

  return \@commands;
}

# @return void
#
# look at the current time and all available commands.
# see if we should run a command.
sub run_commands {
  # get the current local time.
  my ($sec, $minute, $hour) = localtime;

  # nothing to do if no commands.
  return unless $COMMANDS;

  foreach my $command (@$COMMANDS) {
    next unless $command->{hour} == $hour;
    next unless $command->{minute} == $minute;

    # find the Irssi::Server for the network.
    my $server = Irssi::server_find_chatnet($command->{network});
    if (!$server) {
      irclog('error', "failed to find server for network "
        . $command->{network});
      next;
    }

    # execute the command and get the output.
    my $output = run_process($command->{command});
    if (!$output) {
      irclog('error', "failed to execute command");
      next;
    }

    # output it.
    foreach my $line (@$output) {
      next if $line =~ /^\s*$/;
      msg($server, $command->{target}, $line);
    }

    irclog('info', "ran command: " . join(' ', @{ $command->{command} }));
  }
}

# use the irssi log function for WS log output.
WS::setLogFunction(\&WS::Irssi::irclog);

# set WS debug bool.
#WS::setDebug(1);

# commands
#Irssi::command_bind('load_bot_keys', 'cmd_load_bot_keys');

# load initial commands.
$COMMANDS = &read_config;

# check whether we should run commands every 60 secs.
Irssi::timeout_add(60*1000, 'run_commands', undef);
