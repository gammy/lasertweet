#!/usr/bin/env perl
# LaserTweet, a script for allowing laserboys
#             to communicate to and from twitter via irssi.
#
#
# Wishlist:
#		- Create + Destroy + show specific timelines
#		- Shorten the unique ID thing?
# 		- forking code. Use 
# 		  http://pulia.nu/code/junk/currency.pl as 
# 		  a template..
#		- Finish multichan support + get rid of network hack
#               - Nickname white / blacklist?
# Bugs:
#		- Will message users/chans even if they don't exist
#		- For an unknown reason, SSL connects won't respect
#		  the timeout argument. People say this is due to an old
#		  version of IO but mins is recent (1.23)..
#
# Notes:
#		- See the note from 110204. It's weird!
#               - Request is printed after output. I blame the jews.
#               - I store all opts in irssi's registry as strings. Deal with it.
#               - This uses different naming schemes due to being patched
#                 together from currency.pl, newmail.pl and laserquote.pl.
#		- in the channels'-irssi variable. RTFS and see SERVER_TAG_HACK.
#               - checkTwitterUpdates and checkTwitterDMs are identical
#		   except for
#                 - env: twitter_last_id / twitter_dm_last_id
#		  .. so they should just be the same function.
#
# Features:
#               Seen from twitter:
#               - Communicate with an IRC channel(or channels)
#		Seen from IRC:
#		- Automatically see tweets in a channel(or channels)
#               - Send tweets (+ DMs) via your twitter account
#               - Get the status of any twitter name(screen name)
#               - Follow and Unfollow users
#		- Favorite and Unfavorite posts
#
# Usage:
#		- This is how I am using it: I have it loaded in my irssi.
#		  It will listen to all channels in the channel list (/set twit)
#		  and will also broadcast to those channels unless
#		  SERVER_ENABLE_BCAST = 0 (see below). If it is 1, then it
#                 will only listen and publish to the first channel in the list.

## E n v i r o m e n t ######################################################

use warnings; 
use strict;
# For hacking..
# @INC = ("/home/gammy/.irssi/scripts", @INC);

use POSIX;
use Net::Twitter;
use Scalar::Util 'blessed';
use Irssi;
use Irssi::TextUI;
use vars qw(%IRSSI);
use Data::Dumper;
use encoding 'utf8';
#use utf8;
use URI::Escape;
use Encode;

use constant {
	FRIENDS_PER_ROW       => 10,
	HTTP_TIMEOUT          => 20,
	EVAL_TIMEOUT          => 300,            # Should be longer than HTTP_TIMEOUT
	SERVER_TAG_HACK       => 'EFnet',
	SERVER_ENABLE_BCAST   => 1,		# /* Make staticPost broadcast..
	DEBUG                 => 1,             #    ..to all chans in list.. */
	TWITTER_MSG_COUNT     => 10,
	VERSION               => "0.4.1-Plasticvagina",
	MSG_BEGIN             => '|',  # Each outgoing message prepends this.
	MSG_HEADER_GOOD       => ':) ', # Alt: '✔', '♥'
	MSG_HEADER_BAD        => ':( ', # Alt: '✖'
	MSG_HEADER_FAV        =>  '* ', # Alt: '☻', '★'
	MSG_HEADER_DM         => 'DM ', # Alt: '✉'
	MSG_HEADER_STATUS     => '-> ', # Alt: '✎'
};

my %month = (Jan => 0, Feb => 1, Mar => 2, Apr => 3, May => 4, Jun => 5,
	     Jul => 6, Aug => 7, Sep => 8, Oct => 9, Nov => 10, Dec => 11);
my $pipe;
my $waiting = 0;
my $twitter = -1;
my $global_timer = -1;
my $timeout_count = 0;
our $max;
our $timestamp;

# Public commands (mappings)
my %laseropts = (
	"cmdstr_help"       => "help",
	"cmdstr_tweet"      => "add",
	"cmdstr_getstatus"  => "status",
	"cmdstr_following"  => "following",
	"cmdstr_follow"     => "follow",
	"cmdstr_unfollow"   => "unfollow",
	"cmdstr_favorite"   => "favorite",
	"cmdstr_unfavorite" => "unfavorite",
	);

# (Note that these are only defaults - set these via the irssi env (/set))
my %laseropts_env = (
	"channels"           => "#default_channel",
	"flood_delay"        => "5",
	"identifier"         => "!lt",
	"update_interval"    => 60 * 5,
# Basic authentication is deprecated.
#	"twitter_login"      => "twitter login",
#	"twitter_password"   => "twitter password",
	"twitter_access_token_key"    => "Your access token",
	"twitter_access_token_secret" => "Your access token secret",
	"twitter_key"        => "Your OAuth key",
	"twitter_secret"     => "Your OAuth secret",
	"twitter_last_id"    => "-1", # Stores the twitter ID
	"twitter_dm_last_id" => "-1", # Stores the twitter DM ID
	);

%IRSSI = (
        authors     => "gammy with help from phyber",
        contact     => "gambananamy at pepeachan dot org(without fruits)",
        name        => "Fuck you fuck FUCK FUCK FAGOT FAT FAGOT",
        description => "",
        license     => "GPLv2"
);

## F r a m e w o r k ########################################################

sub handleEvalError {
	my ($location, $msg) = @_;

	if($msg =~ m/Eval/) {
		dStatPrint("Timeout(SHOULD NOT HAPPEN) in Net::Twitter during $location: $msg");
	} else {

		if($msg =~ m/timeout/i) {
			dStatPrint("Error in Net::Twitter during $location: $msg");
			$timeout_count++;
		}elsif($msg =~ m/Could not authenticate you/i) {
			# Silently re-instantiate
		}else {
			dStatPrint("Error in Net::Twitter during $location: $msg");
		}
	}
	
	initTwitter();

	return($msg);

}

sub handleArgs {
        my $Argument = lc($_[0]);

        if("$Argument" eq "" || "$Argument" eq "help"){
                statPrint("");
                statPrint("IRSSI environment variables:");
                statPrint('   - lasertweet_identifier      = "' . $laseropts_env{'identifier'} . '"');
                statPrint('   - lasertweet_channels        = "' . $laseropts_env{'channels'} . '"');
                statPrint('   - lasertweet_flood_delay     = "' . $laseropts_env{'flood_delay'} . '"');
                statPrint('   - lasertweet_update_interval = "' . $laseropts_env{'update_interval'} . '"');
                statPrint('   - lasertweet_twitter_access_token_key   = "' . $laseropts_env{'twitter_access_token_key'} . '"');
                statPrint('   - lasertweet_twitter_access_token_secret= "' . $laseropts_env{'twitter_access_token_secret'} . '"');
#                statPrint('   - lasertweet_twitter_login   = "' . $laseropts_env{'twitter_login'} . '"');
#                statPrint('   - lasertweet_twitter_password= "' . $laseropts_env{'twitter_password'} . '"');
                statPrint('   - lasertweet_twitter_key     = "' . $laseropts_env{'twitter_key'} . '"');
                statPrint('   - lasertweet_twitter_secret  = "' . $laseropts_env{'twitter_secret'} . '"');
                statPrint('   - lasertweet_cmdstr_help     = "' . $laseropts{'cmdstr_help'} . '"');
                statPrint("");
                statPrint("Commands:");
                statPrint("  /lasertweet help   - This text");
                statPrint("");
                statPrint("Public commands:");
		statPrint("  " . join(", ", values(%laseropts)));
        }
}

sub loadSettings {

	for my $key (keys(%laseropts)) {
		$laseropts{$key} = Irssi::settings_get_str('lasertweet_' . $key);
	}
	for my $key (keys(%laseropts_env)) {
		$laseropts_env{$key} = Irssi::settings_get_str('lasertweet_' . $key);
		#dStatPrint("LOAD lasertweet_$key = $laseropts_env{$key}");
	}

	initTwitter();
	resetTimer();

	dStatPrint("Loaded settings.");
}

## T i m e r ################################################################

sub alarmHandler {
	dStatPrint("BUGTRACK: Eval timeout");
	die "Eval timeout";
}

sub stopTimer{
        Irssi::timeout_remove($global_timer) if $global_timer != -1;
}

sub resetTimer{
        #dStatPrint("Reset timer $global_timer.");
        stopTimer();

	my $multiplier = 1 + $timeout_count;

        $global_timer = Irssi::timeout_add($laseropts_env{'update_interval'} * ($multiplier * 1000), 
					   'cmdTwitterCallback', 
					   undef);
}

sub dStatPrint{
	statPrint(@_) if DEBUG;
}

sub statPrint{

	# XXX debug
	staticPost($_) for @_;
		
        Irssi::active_win->print(@_);
}

# Construct a timestamp based on utc timestamp.
sub constructTimestamp {

        my $utc_string = shift;

        # 0   1   2  3        4     5
        # Tue Jun 22 08:29:30 +0000 2010
        my @d = split ' ', $utc_string;

        # 0  1  2
        # 08:29:30
        my @t = split ':', $d[3];

        my @remote = ($t[2], $t[1], $t[0], $d[2], $month{$d[1]}, $d[5] - 1900);
        my @local = localtime();

        my $output = '';

        # Do some web 2.0-shit here..
        if($remote[5] == $local[5] && # Same Year
           $remote[4] == $local[4] && # Same month
           $remote[3] == $local[3]) { # Same day
                $output = strftime "%R", @remote;
        }else {
                $output = strftime "%x at %R", @remote;
        }

        return($output);

}

# userstr = 'user' / 'sender'
sub constructTwitterStatus {
	my ($entry, $user_str) = @_;

	my $favorite = '';
	my $user_location = '';

	if(defined $entry->{$user_str}{location}) {
		if($entry->{$user_str}{location} ne ""){
			$user_location = ' in ' . $entry->{$user_str}{'location'};
		}
	}

	# XXX Note that this /never/ works (NET::Twitter bug??)
	my $favorited = $entry->{'favorited'};
	if(defined $favorited) {
		$favorite = MSG_HEADER_FAV if $$favorited;
	}

	return(sprintf("%s@%s: %s (%s%s)",
		       $favorite,
		       $entry->{$user_str}{'screen_name'},
		       $entry->{'text'},
		       constructTimestamp($entry->{'created_at'}),
		       $user_location));
		       
}

## S e r v e r ##############################################################

# IRC

sub serverPost{
    my ($server, $msg, $target) = @_;
    $server->command("MSG $target " . MSG_BEGIN . $msg);
}

# In broadcast mode, this goes through all channels in the channel list.
# In "normal" mode, it only sends to the first channel in the channel list.
# This function is (& should only be) used by the twitter->irc functions.
# FIXME still using the SERVER_TAG_HACK.
sub staticPost {

	my $msg = $_[0];

	my @channels;

	if(SERVER_ENABLE_BCAST == 1) {
		@channels = split "[ |,]", $laseropts_env{'channels'};
	} else {
		@channels = (split "[ |,]", $laseropts_env{'channels'})[0];
	}

	while(my $channel = shift @channels) {
	      my $server = Irssi::server_find_tag(SERVER_TAG_HACK);
	      $server->command("MSG $channel " . MSG_BEGIN . $msg) if defined $server;
       	}

}

sub initTwitter {
	
	#dStatPrint("Init Twitter");

	undef $twitter;

	$timeout_count = 0;

	eval {
		alarm(EVAL_TIMEOUT);

		$twitter = new Net::Twitter(
				traits               => [qw/API::REST OAuth/],
				# Basic authentication is deprecated.
				# username             => $laseropts_env{'twitter_login'},
				# password             => $laseropts_env{'twitter_password'},
				access_token         => $laseropts_env{'twitter_access_token_key'},
				access_token_secret  => $laseropts_env{'twitter_access_token_secret'},
				consumer_key         => $laseropts_env{'twitter_key'},
				consumer_secret      => $laseropts_env{'twitter_secret'},
				ssl                  => 1,
				decode_html_entities => 1,
				# All of these below seem ignored
				clientname           => "LaserTweet",
				clientver            => VERSION,
				useragent            => "Lasertweet/" . VERSION,
				useragent_args       => {
					timeout => HTTP_TIMEOUT,
				}
				);

	};

	alarm(0);
	
	if($@) {
		my $r = $@;
		handleEvalError("Init", $r);
		return();
	} else {
		$timeout_count = 0;
	}

	unless(defined $twitter) {
		dStatPrint("Error instantiating Net::Twitter.");
	}

}

# Twitter

sub checkTwitterUpdates{

	#dStatPrint("CHECKUPDATE: Last entry was \""  .
	#	   $laseropts_env{'twitter_last_id'}."\"");

	my $ret;

	eval {
		alarm(EVAL_TIMEOUT);

		$ret = $twitter->home_timeline({
			since_id => $laseropts_env{'twitter_last_id'},
			count    => TWITTER_MSG_COUNT });
	};

	alarm(0);

	if($@) {
		my $r = $@;
		handleEvalError("checkTwitterUpdates", $r);
		return();
	} else {
		$timeout_count = 0;
	}

	my $new_id = ${$ret}[0]->{'id'};
	unless(defined $new_id) {
		#dStatPrint("Apparently nothing new?");
		#dStatPrint(Dumper($ret));
		return();
	}

	if("$laseropts_env{twitter_last_id}" eq "$new_id") {
		#dStatPrint("last id [$laseropts_env{twitter_last_id}] = new id [$new_id]");
		return();
	}

	# Update "last seen"-id
	$laseropts_env{'twitter_last_id'} = $new_id;
	Irssi::settings_set_str('lasertweet_twitter_last_id', 
				$laseropts_env{'twitter_last_id'});

	foreach my $entry (reverse(@$ret)) {

		unless(defined $entry) {
			dStatPrint("Twitter not defined, " .
				   "assuming no new messages?");
			next;
		}

		my $new_id = $entry->{'id'};
		#dStatPrint("Currently on $new_id");

		my $text = MSG_HEADER_STATUS . 
			constructTwitterStatus($entry, 'user');
		
		# dStatPrint(Dumper($ret));

		staticPost($text);
	}

}

sub checkTwitterDMs{
	
	#dStatPrint("(DM) CHECKUPDATE: Last entry was \""  .
	#	   $laseropts_env{'twitter_dm_last_id'}."\"");

	my $ret;

	eval {
		alarm(EVAL_TIMEOUT);

		$ret = $twitter->direct_messages({
			since_id => $laseropts_env{'twitter_dm_last_id'},
			count   => TWITTER_MSG_COUNT });
	};

	alarm(0);

	if($@) {
		my $r = $@;
		handleEvalError("checkTwitterDMs", $r);
		return();
	} else {
		$timeout_count = 0;
	}


	my $new_id = ${$ret}[0]->{'id'};
	unless(defined $new_id) {
		#dStatPrint("(DM) Apparently nothing new?");
		#dStatPrint(Dumper($ret));
		return();
	}

	if("$laseropts_env{twitter_dm_last_id}" eq "$new_id") {
		#dStatPrint("(DM) last id [$laseropts_env{twitter_dm_last_id}] = new id [$new_id]");
		return();
	}

	# Update "last seen"-id
	$laseropts_env{'twitter_dm_last_id'} = $new_id;
	Irssi::settings_set_str('lasertweet_twitter_dm_last_id', 
				$laseropts_env{'twitter_dm_last_id'});

	foreach my $entry (reverse(@$ret)) {

		unless(defined $entry) {
			dStatPrint("(DM) Twitter not defined, " .
				   "assuming no new messages?");
			next;
		}

		my $new_id = $entry->{'id'};
		#dStatPrint("(DM) Currently on $new_id");
		
		my $text = MSG_HEADER_DM .
			constructTwitterStatus($entry, 'sender');

		# dStatPrint(Dumper($ret));

		staticPost($text);
	}

}
## I n t e r p r e t e r ####################################################

sub getMyQuery{
    my ($server, $msg, $target) = @_;
    my @wrap = ($server, $msg, $server->{nick}, $server->{userhost}, $target);
    getQuery(@wrap);
}

sub getQuery{
    my ($server, $msg, $nick, $address, $target) = @_;
	#dStatPrint("getQuery($server, $msg, $nick, $address, $target)");

	# Go through channel list
    my $active = 0;
    my @channels = split "[ |,]", $laseropts_env{'channels'};

    for my $channel (@channels) {
		   $active = 1 if "$channel" eq "$target";
    }

    return if $active == 0;

    my @calls = split(" ", "$msg");
    my $ident = shift(@calls);

    return 1 if "$ident" ne $laseropts_env{'identifier'};

    my $tmptime = time() - $timestamp;
    if($tmptime < $laseropts_env{'flood_delay'}) {
	    #dStatPrint("Time $tmptime, ignoring request");
	    serverPost($server, MSG_HEADER_BAD . 'Slow down.', 
		       $target);
	    return;
    }
    $timestamp = time();

    my $arg = lc(shift(@calls));
    return unless length($arg) > 1;
    
    if("$arg" eq $laseropts{'cmdstr_tweet'}) {
	    my $offset = index($msg, $arg);
	    $msg = substr $msg, $offset + length($arg) + 1;
	    return if $offset + length($arg) == length($msg); # no more args
	    cmdTweet($server, $target, $msg);
    }elsif("$arg" eq $laseropts{'cmdstr_getstatus'}) {
	    cmdGetStatusByScreenName($server, $target, @calls);
    }elsif("$arg" eq $laseropts{'cmdstr_following'}) {
	    cmdGetFollowing($server, $target, @calls);
    }elsif("$arg" eq $laseropts{'cmdstr_follow'}) {
	    cmdFollow($server, $target, @calls);
    }elsif("$arg" eq $laseropts{'cmdstr_unfollow'}) {
	    cmdUnfollow($server, $target, @calls);
    }elsif("$arg" eq $laseropts{'cmdstr_favorite'}) {
	    cmdFavorite($server, $target, @calls);
    }elsif("$arg" eq $laseropts{'cmdstr_unfavorite'}) {
	    cmdUnfavorite($server, $target, @calls);
    }elsif("$arg" eq $laseropts{'cmdstr_help'}) {
	    cmdHelp($server, $target, @calls);
    }else {
	    cmdHelp($server, $target, @calls);
    }

}

sub setTwitterDM {
		
	my ($status, $user) = @_;
	my $ret;

	eval {
		alarm(EVAL_TIMEOUT);

		# For some reason this gives us a "Not Found" error and
		# an error even though we conform to the API:
		# "Use of uninitialized value in subroutine entry at 
		#  /usr/local/share/perl/5.10.0/Net/Twitter/Core.pm line 113."
		# ... so we do the same as setTwitterUpdate but don't
		# don't save the last_id since it won't turn up in our timeline.

		#$ret = $twitter->new_direct_message({screen_name => $user,
		#				    text => $status});
		
		# FIXME HACK see above.
		$ret = $twitter->update('DM @' . $user . ' ' . $status);
	};

	alarm(0);

	if($@) {
		my $r = $@;
		handleEvalError("setTwitterDM", $r);
		return($r);
	} else {
		$timeout_count = 0;
	}

	unless(defined $ret) {
		dStatPrint("Twitter not defined, assuming DM failed?");
		return();
	}

	# XXX We don't save this id because DM:s don't show up in our home list.

	return;

}
sub setTwitterUpdate {
		
	my $status = shift;
	my $ret;

	eval {
		alarm(EVAL_TIMEOUT);

		#dStatPrint("Status = $status");
		$ret = $twitter->update(decode("utf8", $status));
	};

	alarm(0);

	if($@) {
		my $r = $@;
		handleEvalError("setTwitterUpdate", $r);
		return($r);
	} else {
		$timeout_count = 0;
	}

	my $entry = $ret;

	unless(defined $entry) {
		dStatPrint("Twitter not defined, assuming update failed?");
		return();
	}
	my $new_id = $entry->{'id'};

	#dStatPrint("new id (from the update) = $new_id, last = $twitter_last_id");

	# Update last ID so we don't fetch our just-posted entry
	$laseropts_env{'twitter_last_id'} = $new_id;
	Irssi::settings_set_str('lasertweet_twitter_last_id', 
				$laseropts_env{'twitter_last_id'});

	return;

}
## C o m m a n d s ##########################################################

sub cmdHelp {
	my ($server, $target, @calls) = (shift, shift, @_);
		
		
	#dStatPrint("->@calls");
	my $opt = "";

	if(@calls > 0) {
		$opt = shift @calls;
	}
		
	if("$opt" eq $laseropts{'cmdstr_help'}){
		if(lc shift @calls eq "more") {
			if(lc shift @calls eq "more") {
				serverPost($server, "noomoar :( fag", $target);
			}else{
				serverPost($server, "MOAR?!", $target);
			}
		}else{
			serverPost($server, "moar?", $target);
		}

	}elsif("$opt" eq $laseropts{'cmdstr_tweet'}){
		serverPost($server, "$laseropts{cmdstr_tweet}: Add a tweet.", $target);
		serverPost($server, "Usage: $laseropts{cmdstr_tweet} <text>", $target);
	}elsif("$opt" eq $laseropts{'cmdstr_getstatus'}){
		serverPost($server, "$laseropts{cmdstr_getstatus}: Get current status of screen_name.", $target);
		serverPost($server, "Usage: $laseropts{cmdstr_getstatus} <screen_name>", $target);
	}elsif("$opt" eq $laseropts{'cmdstr_following'}){
		serverPost($server, "$laseropts{cmdstr_follow}: List following[friends].", $target);
		serverPost($server, "Usage: $laseropts{cmdstr_following}", $target);
	}elsif("$opt" eq $laseropts{'cmdstr_follow'}){
		serverPost($server, "$laseropts{cmdstr_follow}: Follow screen_name.", $target);
		serverPost($server, "Usage: $laseropts{cmdstr_follow} <screen_name>", $target);
	}elsif("$opt" eq $laseropts{'cmdstr_unfollow'}){
		serverPost($server, "$laseropts{cmdstr_unfollow}: Unfollow screen_name.", $target);
		serverPost($server, "Usage: $laseropts{cmdstr_unfollow} <screen_name>", $target);
	}elsif("$opt" eq $laseropts{'cmdstr_favorite'}){
		serverPost($server, "$laseropts{cmdstr_favorite}: Favorite id.", $target);
		serverPost($server, "Usage: $laseropts{cmdstr_favorite} <id>", $target);
	}elsif("$opt" eq $laseropts{'cmdstr_unfavorite'}){
		serverPost($server, "$laseropts{cmdstr_unfavorite}: Favorite id.", $target);
		serverPost($server, "Usage: $laseropts{cmdstr_unfavorite} <id>", $target);
	}else {
		serverPost($server, "Yelp, yelp! Help for LaserTweet v" . VERSION, $target);
		serverPost($server, "Usage: " . $laseropts_env{'identifier'} . " <" .
			   (join " | ", values(%laseropts)) . 
			   "> [option]...", $target);
		serverPost($server, 'Symbols: ' . 
			MSG_HEADER_GOOD  . ', ' .  
			MSG_HEADER_BAD   . ', ' .
			MSG_HEADER_FAV   . ', ' .  
			MSG_HEADER_DM    . ', ' . 
			MSG_HEADER_STATUS . ' = ' . 
		'good, bad, favorite, direct message, normal', $target);

	}
}

sub cmdTweet {
	my ($server, $target, $entry) = @_;

	if(length($entry) < 3) {
		serverPost($server, "|nothx.", $target);
		return;
	}

	my $ret;
	my $user;

	# XXX hack! Has several problems.
	my $dm = 0;
	if(length($entry) > 4) {
		my $header = lc substr($entry, 0, 4);
		if($header eq 'dm @') {
			my $end_offset = index($entry, ' ', 4); #XXX Can be out of bounds!
			$user = substr($entry, 4, $end_offset - 4);
			$entry = substr($entry, $end_offset + 1);
			#dStatPrint("offs = $end_offset\nuser = '$user'\nentry = '$entry'\n");
			$dm = 1; # XXX wtf do better, stoner.
		}
	} 

	# add wants lines in the array - not words.
	if($dm == 1) {
		$ret = setTwitterDM($entry, $user);
	} else {
		$ret = setTwitterUpdate($entry);
	}
		
	unless (defined $ret) {
		serverPost($server, MSG_HEADER_GOOD . 'Tweeted.', $target);
	} else {
		serverPost($server, MSG_HEADER_BAD .  "\"$ret\".", $target);
	}
}

sub cmdGetFollowing {
	my ($server, $target, @calls) = @_;
	# No args for this.

	my $ret;
	eval {
		alarm(EVAL_TIMEOUT);
		$ret = $twitter->friends();
	};

	alarm(0);

	if($@) {
		my $r = $@;
		# FIXME 
		handleEvalError("cmdGetFollowing", $r);
		serverPost($server, MSG_HEADER_BAD . "\"$r\".", $target);
		return();
	} else {
		$timeout_count = 0;
	}

	unless(defined $ret) { # Shouldnt happen.
		dStatPrint("Error in create_friend: wt??");
		return();
	}

	my @friends;
	push @friends, $_->{screen_name} for @$ret;

	my $friends_per_row = FRIENDS_PER_ROW;

	$friends_per_row = @friends if @friends < $friends_per_row;
		
	serverPost($server, MSG_HEADER_GOOD . 'Following ' . @friends . ':', $target);

	while (@friends) {
		my $line = join ', ', splice @friends, 0, $friends_per_row;
		serverPost($server, $line, $target);
	}

}

sub cmdFavorite {
	my ($server, $target, @calls) = @_;
	
	if(@calls > 1) {
		serverPost($server, MSG_HEADER_BAD . 
			   'Multiple favorite requests are a TODO.', $target);
	}

	my $entry = shift @calls; # FIXME

	if(! defined $entry || length($entry) < 8 || ! isdigit $entry) {
		serverPost($server, MSG_HEADER_BAD . 'nothx.', $target);
		return;
	}

	$entry = substr($entry, 0, 20); # I dunno. People are idiots.

	my $ret;
	eval {
		alarm(EVAL_TIMEOUT);
		$ret = $twitter->create_favorite($entry);
	};

	alarm(0);

	if($@) {
		my $r = $@;
		# FIXME
		handleEvalError("cmdFavorite", $r);
		serverPost($server, MSG_HEADER_BAD . "\"$r\".", $target);
		return();
	} else {
		$timeout_count = 0;
	}

	unless(defined $ret) { # Shouldnt happen.
		dStatPrint("Error in create_friend: wt??");
		return();
	}

	serverPost($server, MSG_HEADER_GOOD . 'Favorited.', $target);
}

sub cmdUnfavorite {
	my ($server, $target, @calls) = @_;
	
	if(@calls > 1) {
		serverPost($server, MSG_HEADER_BAD . 
			   'Multiple unfavorite requests are a TODO.', $target);
	}

	my $entry = shift @calls; # FIXME

	if(! defined $entry || length($entry) < 8 || ! isdigit $entry) {
		serverPost($server, MSG_HEADER_BAD . 'nothx.', $target);
		return;
	}

	$entry = substr($entry, 0, 20); # I dunno. People are idiots.

	my $ret;
	eval {
		alarm(EVAL_TIMEOUT);
		$ret = $twitter->destroy_favorite($entry);
	};

	alarm(0);

	if($@) {
		my $r = $@;
		# FIXME
		handleEvalError("cmdUnfavourite", $r);
		serverPost($server, MSG_HEADER_BAD . "\"$r\".", $target);
		return();
	} else {
		$timeout_count = 0;
	}

	unless(defined $ret) { # Shouldnt happen.
		dStatPrint("Error in create_friend: wt??");
		return();
	}

	serverPost($server, MSG_HEADER_GOOD . 'Unfavorited.', $target);
}

sub cmdFollow {
	my ($server, $target, @calls) = @_;
	
	if(@calls > 1) {
		serverPost($server, MSG_HEADER_BAD . 
			   'Multiple follow requests are a TODO.', $target);
	}

	my $entry = shift @calls; # FIXME

	if(! defined $entry || length($entry) < 2) {
		serverPost($server, MSG_HEADER_BAD . 'nothx.', $target);
		return;
	}

	$entry = substr($entry, 0, 64); # I dunno. People are idiots.

	my $ret;
	eval {
		alarm(EVAL_TIMEOUT);
		$ret = $twitter->create_friend($entry);
	};

	alarm(0);

	if($@) {
		my $r = $@;
		handleEvalError("cmdFollow", $r);
		serverPost($server, MSG_HEADER_BAD . "\"$r\".", $target);
		return();
	} else {
		$timeout_count = 0;
	}

	unless(defined $ret) { # Shouldnt happen.
		dStatPrint("Error in create_friend: wt??");
		return();
	}

	serverPost($server, MSG_HEADER_GOOD . 'Followed.', $target);
}

sub cmdUnfollow {
	my ($server, $target, @calls) = @_;
	
	if(@calls > 1) {
		serverPost($server, MSG_HEADER_BAD . 
			   'Multiple follow requests are a TODO.', $target);
	}

	my $entry = shift @calls; # FIXME

	if(! defined $entry || length($entry) < 2) {
		serverPost($server, MSG_HEADER_BAD . 'nothx.', $target);
		return;
	}

	$entry = substr($entry, 0, 64); # I dunno. People are idiots.

	my $ret;
	eval {
		alarm(EVAL_TIMEOUT);
		$ret = $twitter->destroy_friend($entry);
	};

	alarm(0);

	if($@) {
		my $r = $@;
		handleEvalError("cmdUnfollow", $r);
		serverPost($server, MSG_HEADER_BAD . "\"$r\".", $target);
		return();
	} else {
		$timeout_count = 0;
	}

	unless(defined $ret) { # Shouldnt happen.
		dStatPrint("Error in destroy_friend: wt??");
		return();
	}

	serverPost($server, MSG_HEADER_GOOD . 'Unfollowed.', $target);
}

sub cmdGetStatusByScreenName {
	my ($server, $target, @calls) = @_;

	if(@calls > 1) {
		serverPost($server, MSG_HEADER_BAD . 
			   'Multiple names requests are a TODO.', $target);
	}

	my $entry = shift @calls; # FIXME

	if(! defined $entry || length($entry) < 2) {
		serverPost($server, MSG_HEADER_BAD . 'nothx.', $target);
		return();
	}

	$entry = substr($entry, 0, 64); # I dunno. People are idiots.

	my $ret;
	eval {
		alarm(EVAL_TIMEOUT);
		$ret = $twitter->user_timeline({ screen_name => $entry,
		   			         count       => 1});
	};

	alarm(0);

	if($@) { # Is also true if there is no user with that name
		my $r = $@;
		handleEvalError("cmdGetStatusByScreenName", $r);
		serverPost($server, MSG_HEADER_BAD .  "\"$r\".", $target);
		return();
	} else {
		$timeout_count = 0;
	}

	unless(defined $ret) {  # User hasn't made any posts?
		serverPost($server, MSG_HEADER_BAD .  'No tweets.', $target);
		return();
	}

	my $text = constructTwitterStatus(${$ret}[0], 'user');

	serverPost($server, MSG_HEADER_STATUS . $text, $target);
}


sub cmdTwitterCallback {
	checkTwitterUpdates();
	checkTwitterDMs();
}

## I n i t ##################################################################

# Setup sigalarm handler
my $sigmask = POSIX::SigSet->new(SIGALRM);
my $sigact = POSIX::SigAction->new("alarmHandler", $sigmask);
my $oldaction = POSIX::SigAction->new();
sigaction(SIGALRM, $sigact, $oldaction);

# Setup defaults
for my $key (keys(%laseropts)) {
	Irssi::settings_add_str('misc', "lasertweet_$key", $laseropts{$key});
}
for my $key (keys(%laseropts_env)) {
	Irssi::settings_add_str('misc', "lasertweet_$key", $laseropts_env{$key});
	#dStatPrint("SET lasertweet_$key => $laseropts_env{$key}");
}

loadSettings();

# Bindings and signals
Irssi::command_bind("lasertweet", 'handleArgs');
Irssi::signal_add('setup changed', 'loadSettings');
Irssi::signal_add_last('message public', 'getQuery');
Irssi::signal_add_last('message own_public', 'getMyQuery');
Irssi::signal_add_last('message private', 'getMyQuery');
Irssi::signal_add_last('message own_private', 'getMyQuery');

$timestamp = time() - $laseropts_env{'flood_delay'};

statPrint("LaserTweet v" . VERSION);
staticPost(MSG_HEADER_GOOD . 
	"LaserTweet v" . VERSION . (DEBUG == 1 ? " (debug)" : "") . 
	": your friendly twitter<>IRC gateway.");

