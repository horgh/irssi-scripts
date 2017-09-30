Thsi is a small collection of scripts for the IRC client
[Irssi](https://irssi.org) I've written or heavily modified.


### Scripts
  * allwin.pl: Print all channel messages into a separate window. This can
    be useful to have a single window to review while also having
    windows for each channel.
  * bot.pl: Turn Irssi clients into a simple botnet. Mainly useful for
    maintaining control over a channel on networks without services.
    * bot_verify.pl: Helper program used by bot.pl to verify messages.
  * command_period.pl: Run external programs and send their output to
    channels.
  * correct.pl: Suggest corrections to messages in channels.
  * joinserver.pl: Warn (and optionally ban) if users join channels from
    particular servers.
  * keepalive.pl: Attempt to keep connections to IRC servers alive on
    unstable connections.
  * nickalias.pl: Alias user@hosts to show as particular nicks.
  * nickcolour-horgh.pl: Assign colours to nicks in channels. By default
    none will be coloured.
  * seen.pl: !seen nick functionality.
  * sqlquote.pl: Interact with a quote database.
    * sqlquote_test.pl: Tests for sqlquote.pl
  * urltitle.pl: Retrieve URLs and print their titles to channels.
  * userlist.pl: Auto-op particular users in channels.


### License
Unless otherwise specified, GPL 3. Many if not all of the scripts have
their own license set inside.
