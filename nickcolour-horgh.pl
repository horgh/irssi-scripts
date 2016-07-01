#
# vim: tabstop=2:shiftwidth=2:expandtab
#
# This script is a copy of the nickcolor.pl script found on the Irssi scripts
# site.
#
# My modification is to by default leave all nicks uncoloured. Instead, ou can
# use it to set specific nicks to a colour.
#
# I like having most nicks the same colour but some (e.g. bots) having different
# colours. I don't like the random colouring.
#
# I forked it from the version with this changed date:
# Sun 15 Jun 19:10:44 BST 2014
#

use warnings;
use strict;

use Irssi 20020101.0250 ();
use vars qw($VERSION %IRSSI);

$VERSION = "2";

%IRSSI = (
    authors     => "Timo Sirainen, Ian Peters, David Leadbeater, William Storey",
    contact     => "tss\@iki.fi",
    name        => "Nick Colour (Horgh fork)",
    description => "Assign a different colour for each nick",
    license     => "Public Domain",
    url         => "https://irssi.org/",
    changed     => "Fri  1 Jul 11:22:44 PDT 2016",
);

# Settings:
#   nickcolour_colours: List of colour codes to use.
#   e.g. /set nickcolour_colours 2 3 4 5 6 7 9 10 11 12 13
#   (avoid 8, as used for hilights in the default theme).

# %saved_colours holds those manually set.
my %saved_colours;

# %session_colours holds additional colours set. Such as temporary ones like
# nickname changes.
my %session_colours;

sub load_colours {
  my $fh;
  if (!open $fh, "<", "$ENV{HOME}/.irssi/saved_colours") {
    # Don't complain about this. There may be no saved colours.
    return;
  }

  while (!eof $fh) {
    my $line = <$fh>;
    if (!defined $line) {
      Irssi::print("Unable to read from .irssi/saved_colours");
      close $fh;
      return;
    }

    chomp $line;

    next unless length $line > 0;

    my ($nick, $colour) = split ":", $line;

    next unless defined $nick && defined $colour;
    next unless length $nick > 0;
    next unless $colour =~ /^\d+$/;
    next unless $colour >= 2 && $colour <= 14;

    $saved_colours{ $nick } = $colour;
  }

  close $fh;
}

sub save_colours {
  my $fh;
  if (!open $fh, ">", "$ENV{HOME}/.irssi/saved_colours") {
    Irssi::print("Unable to open .irssi/saved_colours: $!");
    return;
  }

  foreach my $nick (keys %saved_colours) {
    if (!print { $fh } "$nick:$saved_colours{$nick}\n") {
      Irssi::print("Unable to write to .irssi/saved_colours");
      close $fh;
      return;
    }
  }

  if (!close $fh) {
    Irssi::print("Unable to close .irssi/saved_colours");
    return;
  }
}

# sig_nick fires on nick changes.
#
# If someone we've coloured (either through the saved colours, or the hash
# function) changes their nick, we'd like to keep the same colour associated
# with them (but only in the session_colours, ie a temporary mapping).
sub sig_nick {
  my ($server, $newnick, $nick, $address) = @_;
  my $colour;

  $newnick = substr ($newnick, 1) if ($newnick =~ /^:/);

  if ($colour = $saved_colours{$nick}) {
    $session_colours{$newnick} = $colour;
  } elsif ($colour = $session_colours{$nick}) {
    $session_colours{$newnick} = $colour;
  }
}

# sig_public fires on public messages.
sub sig_public {
  my ($server, $msg, $nick, $address, $target) = @_;

  # Has the user assigned this nick a colour?
  my $colour;

  if (exists $saved_colours{ $nick }) {
    $colour = $saved_colours{ $nick };
  }

  if (!defined $colour && exists $session_colours{ $nick }) {
    $colour = $session_colours{ $nick };
  }

  if (defined $colour) {
    $colour = sprintf "\003%02d", $colour;
    $server->command('/^format pubmsg {pubmsgnick $2 {pubnick ' . $colour . '$0}}$1');
    return;
  }

  # No colour set for this nick.
  # However we need to reset the format. It is persistent if we had a format set.
  # TODO: It seems like there should be a nicer way to do this without messing
  #   with formats.
  $server->command('/^format pubmsg {pubmsgnick $2 {pubnick $0}}$1');
}

sub cmd_colour {
  my ($data, $server, $witem) = @_;

  my ($op, $nick, $colour) = split " ", $data;

  if (!defined $op) {
    Irssi::print("No operation given (save/set/clear/list/preview)");
    Irssi::print("");
    Irssi::print("  /colour save");
    Irssi::print("    Saves your colours to disk.");
    Irssi::print("");
    Irssi::print("  /colour set <nick> <colour number [2,14]>");
    Irssi::print("    Sets a nick's colour.");
    Irssi::print("");
    Irssi::print("  /colour clear <nick>");
    Irssi::print("    Clears a nick's colour.");
    Irssi::print("");
    Irssi::print("  /colour list");
    Irssi::print("    List saved nick colours.");
    Irssi::print("");
    Irssi::print("  /colour preview");
    Irssi::print("    List available colours.");
    return;
  }

  $op = lc $op;

  if ($op eq "save") {
    &save_colours;
    return;
  }

  if ($op eq "set") {
    if (!$nick) {
      Irssi::print("Nick not given");
    } elsif (!defined $colour) {
      Irssi::print("Colour not given");
    } elsif ($colour < 2 || $colour > 14) {
      Irssi::print("Colour must be between 2 and 14 inclusive");
    } else {
      $saved_colours{$nick} = $colour;
      &save_colours;
    }
    return;
  }

  if ($op eq "clear") {
    if (!$nick) {
      Irssi::print("Nick not given");
    } else {
      delete ($saved_colours{$nick});
    }
    return;
  }

  if ($op eq "list") {
    Irssi::print("\nSaved colours:");
    foreach my $nick (keys %saved_colours) {
      Irssi::print(chr (3) . "$saved_colours{$nick}$nick" .
        chr (3) . "1 ($saved_colours{$nick})");
    }
    return;
  }

  if ($op eq "preview") {
    Irssi::print("\nAvailable colours:");
    foreach my $i (2..14) {
      Irssi::print(chr (3) . "$i" . "colour #$i");
    }
    return;
  }

  Irssi::print("Unknown operation given. Use one of save/set/clear/list/preview.");
}

&load_colours;

Irssi::settings_add_str('misc', 'nickcolour_colours', '2 3 4 5 6 7 9 10 11 12 13');
Irssi::command_bind('colour', 'cmd_colour');

Irssi::signal_add('message public', 'sig_public');
Irssi::signal_add('event nick', 'sig_nick');
