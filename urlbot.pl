#!/usr/bin/perl
#
# **** URL Title Bot ****
# 
# * announce titles of URLs pasted to an IRC channel
# * logs newest urls to a HTML file
# * HTML can be uploaded somewhere or just symlinked to public_html
# * also saves urls to a database file
# * reads some FB and Twitter post metadata
# * fuzzy filtering to avoid spamming the obvious titles
# 
# Requirements:
# apt-get install libbot-basicbot-perl libio-socket-ssl-perl libconfig-file-perl
#
# Usage:
# rename urlbot_default.conf to urlbot.conf and adjust the settings (required)
# [screen] perl urlbot.pl
#
#
# Author: induktio <info@induktio.net>
#
# Released under The MIT License.
#

package Bot;
use 5.10.0;
use strict;
use warnings;
use utf8;
use base qw(Bot::BasicBot);
use LWP::UserAgent;
use HTML::HeadParser;
use HTML::Entities;
use URI::Escape;
use Config::File;
use Unicode::Normalize;
use open qw( :encoding(UTF-8) :std );

my $cfg = Config::File::read_config_file($ARGV[0] || "urlbot.conf") or die $!;

my $db_file = $cfg->{db_file};
my $html_max_size = $cfg->{html_max_size};
my $html_file = $cfg->{html_file};
my $redir = $cfg->{redir};
my $comment_prefix = $cfg->{comment_prefix};
my $title_max_len = $cfg->{title_max_len};
my $fuzzy_filter = $cfg->{fuzzy_filter};
my $nick = $cfg->{nick};
my $irc_chan = $cfg->{irc_chan};
my $server = $cfg->{server};
my $port = $cfg->{port};
my @urls;
my @ignores;

for my $dn (split(/\s+/, $cfg->{hide_title_msgs})) {
	push @ignores, $dn;
}
if (open DB, '<', "$db_file") {
#	binmode DB, ':utf8';
	while (<DB>) {
		chomp;
		my ($time, $nick, $url, $title) = split(/\t/);
		push @urls, [$time, $nick, $url, $title];
		if ($cfg->{html_max_size} && scalar @urls > $cfg->{html_max_size}) {
			shift @urls;
		}	
	}
	close DB;
	print "DB loaded from $db_file\n";
} else {
	print "DB not found.\n";
}

sub said {
	my $self = shift;
	my $message = shift;
	my $body = $message->{body};
	print $message->{channel}.':'.$message->{who}.':'.$body."\n";
	if (lc($message->{channel}) eq lc($irc_chan) &&	$body =~ /(https?:\/\/[^ \/]{4,}[^ ]*)/i) {
		my $url = $1;
		for my $i ($#urls-100..$#urls) {
			if (defined $urls[$i] && $urls[$i][2] eq $url) {
				print "Old link: $url\n";
				return;
			}
		}
		my $ua = LWP::UserAgent->new(
			timeout => 15,
			agent => "Mozilla/5.0 (Windows NT 6.1; WOW64; rv:20.0) Gecko/20100101 Firefox/20.0",
			ssl_opts => {verify_hostname => 0},
			max_size => 256000
		);
		$ua->default_header('Accept-Language' => "en");
		$ua->env_proxy;
		my $response = $ua->get($url);
		if (!$response->is_success) {
			print $response->status_line."\n";
			return;
		}
		my $title = findtitle($url, $response->decoded_content);
		
		if (notignored($url) && length $title->{text} > 0 
		&& !fuzzymatch($url, $title->{text})) {
			$self->say(
				channel => $irc_chan,
				body => $title->{prefix}.$title->{author}.': '.fixtitle($title->{text})
			);
		}
		print "Add link: $url\n";
		push @urls, [time, $message->{who}, $url, 
			($title->{author} ? $title->{author}.': '.$title->{text} : $title->{text})];
		shift @urls while scalar @urls > $html_max_size;
		open DB, '>>', "$db_file" or die $!;
		print DB join("\t", @{$urls[$#urls]})."\n";
		close DB;
		open HTML, '>', "$html_file" or die $!;
		print HTML qq{<!DOCTYPE html>
<html><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
<title>$irc_chan urls</title></head><body>
};
		my $stamp = "";
		my $i = $#urls;
		while ($i >= 0) {
			my @u = @{ $urls[$i] };
			$u[3] = "" if !defined $u[3];
			$u[2] = encode_entities($u[2]);
			$u[3] = encode_entities($u[3]);
			my $tt = scalar(localtime($u[0]));
			my $day = substr($tt, 0, 10);
			my $time = substr($tt, 11, 5);
			if ($stamp ne $day) {
				print HTML "<h2>$day</h2>\n";
			}
			print HTML qq
{$time &lt;$u[1]&gt; <a href="$redir$u[2]" title="$u[3]" target="_blank">$u[2]</a><br>
};
			$stamp = $day;
			$i--;
		}
		print HTML "</body></html>";
		close HTML;
	}
	return; # don't say anything else
}

sub notignored($) {
	my ($domain) = shift =~ /^https?:\/\/([^ \/]+)/i;
	for my $dn (@ignores) {
		return 0 if ($domain =~ /\Q$dn\E$/i);
	}
	return 1;
}

sub findtitle($$) {
	my ($url, $webpage) = @_;
	my $parser = HTML::HeadParser->new;
	$parser->parse($webpage);
	my $title = ($parser->header('Title') or '');
	my ($prefix, $author, $topic) = ('', '', '');
	my ($special_re, $filter, $author_re);
	my ($domain) = $url =~ /^https?:\/\/([^ \/]+)/i;
	
	if ($url =~ /^https?:\/\/(www.)?facebook.com\/photo.php?/i) {
		$author_re = '<div class="fbPhotoContributorName" id="fbPhotoPageAuthorName">(.+?)</div>';
		$special_re = '<span class="fbPhotosPhotoCaption".*?><span class="hasCaption">(.+?)<span class=';
		$prefix = 'FB';
	} elsif ($domain =~ /facebook.com$/i) {
		$author_re = '<div class="permalinkHeaderInfo[^"]*">(.+?)</div>';
		$special_re = '<span class="userContent[^"]*">(.+?)</span>';
		$filter = '<span class="[^"]*fwn[^"]*">.*?</span>';
		$prefix = 'FB';
	} elsif ($url =~ /^https?:\/\/(www.)?twitter.com\/.*photo\//i) {
		$author_re = '<span class=\'tweet-full-name[^\']*\'>(.+?)</span>';
		$special_re = '<div class="[^"]*tweet-text[^"]*">(.+?)</div>';
		$filter = '<span class="[^"]*(hidden|invisible)[^"]*">.*?</span>';
		$prefix = 'Twitter';
    } elsif ($domain =~ /twitter.com$/i) {
		$author_re = '<div class="permalink-header[^"]*">.*?'.
		'<strong class="fullname[^"]*">(.*?)</strong>';
		$special_re = '<div class="[^"]*permalink-tweet[^"]*".*?'.
		'<p class="[^"]*tweet-text[^"]*">(.+?)</p>';
		$filter = '<span class="[^"]*(hidden|invisible)[^"]*">.*?</span>';
		$prefix = 'Twitter';
    }
	if ($special_re && $webpage =~ /$special_re/ms) {
		$topic = $1;
		if ($author_re && $webpage =~ /$author_re/ms) {
			$prefix .= " - ";
			$author = $1;
			$author =~ s/$filter//sg if $filter;
			$author =~ s/<.+?>//sg;
		}
	}
	if ($author =~ /\w/ && $topic =~ /\w/) {
		$topic =~ s/$filter//sg if $filter;
		$topic =~ s/<.+?>//sg;
		$title=$topic;
	} else {
		$prefix = $comment_prefix;
		$author = "";
	}
	return {prefix => $prefix, author => substr(clean($author), 0, 50), 
		text => substr(clean($title), 0, 255)};
}

sub clean($) {
	$_ = decode_entities(shift);
	s/\s+/ /g;
	s/^ +| +$//g;
	return $_;
}

sub fuzzymatch($$) {
	if (!$fuzzy_filter) {
		return 0;
	}
	my $url = NFD(lc(uri_unescape(shift))); #  decompose (Unicode Normalization Form D)
	my $title = NFD(lc(shift));
	$url =~ s/[^\p{L}]/ /g;  # Unicode not-Letter
	$title =~ s/[^\p{L}]/ /g;
    $url =~ s/\pM//g;  #  strip combining characters
	$title =~ s/\pM//g;
	$title =~ s/^ +| +$//g;
	my $len=0;
	my $match=0;
	for my $word (split(/ +/, $title)) {
		my $wl = length($word);
		$match += $wl if $url =~ /\Q$word\E/i;
		$len += $wl;
	}
	if ($len==0 || $match/$len > 0.8) {
		return 1;
	} else {
		return 0;
	}
}

sub fixtitle($) {
	my $t = shift;
	$t =~ s/[\p{Pd}]/-/g; # Unicode Dash_Punctuation
	if (length $t > $title_max_len) {
		return substr($t, 0, $title_max_len) . '...';
	} else {
		return $t;
	}
}

Bot->new(
	server => $server,
	port   => $port,
	channels => [$irc_chan],
	nick      => $nick,
	alt_nicks => [$nick."-", $nick."_"],
	username  => "",
	name      => ""
)->run();


