#!/usr/bin/env perl

# check.pl is a tool to check websites periodicaly
# and notify by mail if something has changed (usually, a new version of a software is available)
#
# The basic mean to check if something has changed is
# - retrieve an url
# - perform an md5 hash of the retrieved content
# - if the hash is different from the previous, notify that
# - you can limit the check to a portion of the document to retrieve by using the xpath of a sub part

use strict;
use warnings;
use feature 'say';
use utf8;

use Data::Dumper;
use Data::Printer;
use Digest::MD5 'md5_hex';
use Encode;
use File::Basename;
use FindBin qw( $Bin ); # use to know the running dir $Bin is built-in variable
use Getopt::Long qw(:config no_ignore_case bundling auto_version);
use HTML::TreeBuilder;
use HTML::TreeBuilder::XPath;
use LWP::UserAgent;
use MIME::Base64;
use Net::SMTP;
use Pod::Usage;
use POSIX qw( setlocale LC_TIME strftime );
use Sys::Hostname;
use Text::Diff;
use Compress::Zlib;

$|++; # auto flush messages
$Data::Dumper::Sortkeys = 1;

our $VERSION = '0.9.3';

my %args;
GetOptions(\%args,
           'help|h|?',
           'man',
           'debug|d',
           'list|l',
           'showdata|D',
           'test|t',
           'verbose|v'
    ) or pod2usage(2);
pod2usage(1) if $args{help};
pod2usage(-exitval => 0, -verbose => 2) if $args{man};

# debug implies verbose
$args{verbose} = 1 if $args{debug};

my $cfg_file = "$Bin/check.cfg";

# Read our poor man's config file
die "Missing config $cfg_file" unless -e $cfg_file;
my $cfg = do $cfg_file;
die "Cannot parse $cfg_file: $@" if $@;
die "Cannot do $cfg_file: $!" unless defined $cfg;
die "Cannot run $cfg_file" unless $cfg;

my $net_check       = $cfg->{net_check};
my $pages           = $cfg->{pages}; # pages is the arrayref of each page to check
my $persist_file    = $cfg->{persist_file};
my $mail_from       = $cfg->{mail_from};
my $default_mail_to = $cfg->{mail_to};
my $mail_server     = $cfg->{mail_server};
my $persist         = {};

my $host   = hostname();
my $whom   = getlogin() || getpwuid($<); # $< is real uid of this process
my $path   = $Bin;
my $script = basename($0);
setlocale(LC_TIME, 'C');        # to avoid incorrectly encoded accents in the mail - need to set it as setting?

# reload persisted data
if (-e "$Bin/$persist_file"){
    my $data = do "$Bin/$persist_file";
    # say p $data;
    $persist = $data;
}
# say p $persist;

if ($args{list}){
    list_sites();
    exit 0;
}

# Define a custom User-Agent
# - to use the environment-defined proxy
# - and because some websites refuse to serve Perl ⇒ 406 - Not acceptable
my $ua = new LWP::UserAgent( 
    env_proxy => 1,
    agent     => 'Mozilla/4.73 [en] (X11; I; Linux 2.2.16 i686; Nav)', # impersonate Firefox
    ssl_opts  => { verify_hostname => 0 } 
    );

printf "%s --------------------------------------------------\n", stringify_datetime(time, 1) if $args{verbose};

# first, we check if network is OK (no need to report one fail per page then)
my $check = retrieve_url($ua, HEAD => $net_check);
unless ($check->is_success){
    my $status = $check->status_line;
    my $msg = "Net check on $net_check got `$status`.";
    send_mail($mail_from, $default_mail_to, "Network check failed", $msg);
    say STDERR $msg;
    say STDERR "Aborting.";
    exit 1;
}

# map { my $p = $_; say "$p->{name} = $p->{url}" } @$pages;
PAGE: for my $p (@$pages){
    my $name        = $p->{name};
    my $url         = $p->{url};
    my $notify_mail = $p->{mail_to} // $default_mail_to;
    my $enabled     = $p->{enable} // 1;
    print "'$name'" if $args{verbose};
    unless ($enabled){
        print " is disabled.\n" if $args{verbose};
        next PAGE;
    }

    # get the page
    my $res = retrieve_url($ua, GET => $url);
    
    my $status = $res->status_line;
    print " ($url => $status)" if $args{debug};
    
    if ($res->is_success){
        my $content;
        if( exists $p->{xpath} ){
            # if we provided a XPath, check that specific item
            my $xpath = $p->{xpath};
            my $tree = new HTML::TreeBuilder::XPath;
            $tree->parse($res->decoded_content);
            $tree->eof;
            $content = $tree->findvalue($xpath);
            $tree->delete;
        } elsif (exists $p->{rx_text} || exists $p->{rx_raw} ){
            my $re;
            if ($p->{rx_raw}){
                $re = $p->{rx_raw};
                $content = $res->content;
            } elsif ($p->{rx_text}){
                $re = $p->{rx_text};
                my $tree = new HTML::TreeBuilder;
                $tree->parse($res->decoded_content);
                $tree->eof;
                $content = $tree->as_text;
            }
            say $re if $args{debug};
            if ($content =~ /$re/){
                say " matches" if $args{debug};
                $content = $1 || $&;
            } else {
                $content = "NO MATCH";
                say " NO MATCH ??";
                send_mail($mail_from, $notify_mail, "No match for '$name'", <<"NOMATCH") unless $args{test};
In the page of "${name}" the specified regex matches nothing.
$re
URL: $url
NOMATCH
            }
        } else {
            # else we are computing the change of the whole document
            $content = $res->decoded_content;
        }

        unless ($content){
            say "No content ??" if $args{test};
            my $check;
            if ($p->{xpath}){
                $check = "XPath " . $p->{xpath};
            } elsif ($p->{rx_raw}){
                $check = "RX on html content: " . $p->{rx_raw};
            } elsif ($p->{rx_text}){
                $check = "RX on body text: " . $p->{rx_text};
            }
            send_mail($mail_from, $notify_mail, "No content from check for '$name'", <<"EMPTY") unless $args{test};
In the page of "${name}" the specified URL returns an empty content.
$check
URL: $url
EMPTY
        }
        
        # md5_hex expects a string of bytes for input, but content is a decoded string 
        # (i.e a string that may content Unicode Code Points). Explicitly encode the string if needed.
        if (utf8::is_utf8($content)){
            $content = Encode::encode_utf8($content);
        }
        my $digest = md5_hex($content);
        
        if (defined $persist->{$name}{digest}){
            # we previously managed to get a hash
            my $previous_digest = $persist->{$name}{digest};
            if ($digest eq $previous_digest){
                # this is the same content than previously
                my $last_res = $persist->{$name}{last_check_res};
                my $last_time = $persist->{$name}{last_check_time};
                if ($last_res !~ /^2/){
                    my $msg = "Previous check of ${url} at ${last_time} got `${last_res}`.";
                    $msg .= "\nLast time it was OK: " . ($persist->{$name}{last_ok_time} || 'never') . '.';
                    send_mail($mail_from, $default_mail_to, "'${name}' is back online", $msg);
                }
                say " has not changed." if $args{verbose};
            } else {
                if ($args{verbose}){
                    if ($args{test}){
                        say " HAS CHANGED ==> $content";
                    } else {
                        say " HAS CHANGED !!!";
                    }
                }
                my $diff;
                if ($persist->{$name}{data}){
                    my $ori = Compress::Zlib::memGunzip(decode_base64($persist->{$name}{data}));
                    $diff = diff( [$ori."\n"], [$content."\n"]) if $ori;
                }
                unless ($args{test}){
                    # Note: empty defined email allows disabling email
                    notify_change($name, $url, $diff, $notify_mail, $p->{additional}) if $notify_mail;
                }
                # Save the retrieved data only on fetch success & change
                # same comment than for md5_hex: compress expects bytes
                # we could also "use bytes;"
                my $data = encode_base64(Compress::Zlib::memGzip($content), '');
                chomp($data);
                $persist->{$name}{data} = $data; # save the data for future diff
            }
            
        } else {
            # first time we have a result for the url
            say " was not monitored yet." if $args{verbose};
            my $data = encode_base64(Compress::Zlib::memGzip($content), '');
            chomp($data);
            $persist->{$name}{data} = $data; # save the data for future diff
        }
        $persist->{$name}{digest} = $digest; # save the hash
    } else {
        # Retrieve failed
        my $msg = "$url returned `" . $status .'`';
        say STDERR " $msg";
        $msg .= "\nLast time it was OK: " . ($persist->{$name}{last_ok_time} || 'never') . '.';
        if ((defined $persist->{$name}{last_check_res}) && ($persist->{$name}{last_check_res} !~ /^2/)){
            if ($persist->{$name}{last_check_res} ne $status){
                # different error from previous time
                $msg .= "\nPrevious problem was `$persist->{$name}{last_check_res}`";
                send_mail($mail_from, $default_mail_to, "Different problem encountered while checking for '$name'", $msg);
            }
        } else {
            # first error
            send_mail($mail_from, $default_mail_to, "Problem encountered while checking for '$name'", $msg);
        }
    }
    
    $persist->{$name}{last_check_res} = $status;
    $persist->{$name}{last_check_time} = stringify_datetime(time, 1);
    $persist->{$name}{last_ok_time} = $persist->{$name}{last_check_time} if $res->is_success;
}

unless ($args{test}){
    open my $p, '>', "$Bin/$persist_file" or die "Cannot open $Bin/$persist_file for saving states: $!";
    my $dd = new Data::Dumper( [ $persist ] , [ 'persist' ] );
    print $p $dd->Dump;
    close $p;
}
say "Done." if $args{verbose};

sub retrieve_url {
    my ($ua, $method, $url) = @_;
    my $req = new HTTP::Request( $method => $url );
    my $res = $ua->request($req);
    return $res;
}

sub list_sites {
    if ($args{verbose}){
        say sprintf "%35s - %-60s %-35s %s", 'Name', 'URL', 'Last check', 'Part [XPath/ Rx(Content) / Rx(Text)]';
    } elsif ($args{showdata}) {
        say sprintf "%35s - %-60s", 'Name', 'Last check', 'Value';
    } else {
        say sprintf "%35s - %-60s", 'Name', 'URL';
    }
    for my $site (sort { $a->{name} cmp $b->{name} } @$pages){
        my $url = $site->{url};
        my $part;
        if (exists $site->{xpath}){
            $part = 'XPath:'.$site->{xpath};
        } elsif (exists $site->{rx_text}){
            $part = 'RxT:/'.$site->{rx_text}.'/';
        } elsif (exists $site->{rx_raw}){
            $part = 'RxC:/'.$site->{rx_raw}.'/';
        } else {
            $part = "(Full page)";
        }
        my $last = "";
        my $value = "";
        my $state = $persist->{$site->{name}};
        if (defined $state){
            $last .= "$state->{last_check_res} ($state->{last_check_time})";
            $value = Compress::Zlib::memGunzip(decode_base64($persist->{$site->{name}}{data}));
        } else {
            $last .= "??";
        }
        $last .= " (DISABLED)" unless $site->{enable} // 1;

        if ($args{verbose}){
            say sprintf "%35s - %-60s %-35s %s", $site->{name}, $url, $last, $part;
        } elsif ($args{showdata}) {
            say sprintf "%35s - %-35s %s", $site->{name}, $last, $value;
        } else {
            say sprintf "%35s - %-60s", $site->{name}, $url;
        }
    }
}

# return the string of a date and time
# pass non-undef as 2nd argument if you want the local time representation
sub stringify_datetime {
    my $date = shift;
    my $wantlocal = shift;
    my $iso_time_fmt   = '%Y-%m-%dT%H:%M:%SZ';
    my $human_time_fmt = '%d %b %Y %H:%M:%S';
    my @date_parts = gmtime $date;
    @date_parts = localtime $date if $wantlocal;
    return strftime $human_time_fmt, @date_parts;
}

sub notify_change {
    my ($name, $url, $diff, $email, $add) = @_;
    $diff = $diff ? "\n\nDiff: $diff" : '';
    send_mail($mail_from, $email, "Change detected for '$name'", <<"CHANGE");
A change has been detected in the page of "${name}"
URL is ${url}${diff}
${add}
CHANGE
}

sub send_mail {
    my ($from, $to, $subject, $message) = @_;
    
    my $smtp = Net::SMTP->new($mail_server, $args{debug} ? (Debug => 1) : ());
    if($smtp){
        $smtp->mail($from);
        if($smtp->to(split /,/, $to)){
            $smtp->data(<<"MSG");
From: ${from}
To: ${to}
Subject: ${subject}
Content-Type: text/plain;

${message}
---
Sent by $path/$script v$VERSION from $whom\@$host.
MSG
        } else {
            say STDERR "Failed to send mail: ", $smtp->message();
        }
        $smtp->quit();
    } else {
        say STDERR "Failed to instanciate Net::SMTP :(";
    }
}

__END__

=head1 NAME

check.pl - An automatic page change tester written in Perl.

=head1 VERSION

v0.9.1

=head1 SYNOPSIS

check.pl [options]

=head1 DESCRIPTION

This is a simple tool that can monitor a list of websites and will send a mail if one had changed.

Typical usage is to be run periodically from a Cron job.

=head1 OPTIONS

=over 4

=item B<-h --help>

Display a short help.

=item B<--man>

Display the full manual.

=item B<-v --verbose>

Show verbose messages during processing.

=item B<-d --debug>

Activate the debug flag (show SMTP details).

=item B<-l --list>

List the sites monitored.

=item B<-t --test>

Just perform the test, do not notify / persist results.

=back

=cut

# Local Variables: 
# coding: utf-8-unix
# mode: perl
# tab-width: 4
# indent-tabs-mode: nil
# End:
# ex: ts=4 sw=4 sts=4 et :
