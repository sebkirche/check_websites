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

use Cwd qw( cwd );
use Data::Dumper;
use Data::Printer;
use Digest::MD5 'md5_hex';
use Encode;
use File::Basename;
use FindBin qw( $Bin ); # use to know the running dir $Bin is built-in variable
use Getopt::Long;
use HTML::TreeBuilder;
use HTML::TreeBuilder::XPath;
use LWP::UserAgent;
use MIME::Base64;
use Net::SMTP;
use Pod::Usage;
use POSIX qw( strftime );
use Sys::Hostname;
use Text::Diff;
use Compress::Zlib;

$|++; # auto flush messages
$Data::Dumper::Sortkeys = 1;

my ($arg_hlp, $arg_man, $arg_debug, $arg_verbose, $arg_list) = (0,0,0,0,0);
GetOptions(
    'help|h|?'  => \$arg_hlp,
    'man'       => \$arg_man,
    'debug|d'   => \$arg_debug,
    'list|l'    => \$arg_list,
    'verbose|v' => \$arg_verbose,
    ) or pod2usage(2);
pod2usage(1) if $arg_hlp;
pod2usage(-exitval => 0, -verbose => 2) if $arg_man;

# debug implies verbose
$arg_verbose = 1 if $arg_debug;

my $cfg_file = "$Bin/check.cfg";

# Read our poor man's config file
die "Missing config $cfg_file" unless -e $cfg_file;
my $cfg = do $cfg_file;
die "Cannot parse $cfg_file: $@" if $@;
die "Cannot do $cfg_file: $!" unless defined $cfg;
die "Cannot run $cfg_file" unless $cfg;

my $pages        = $cfg->{pages};
my $persist_file = $cfg->{persist_file};
my $mail_from    = $cfg->{mail_from};
my $mail_to      = $cfg->{mail_to};
my $mail_server  = $cfg->{mail_server};
my $persist = {};

my $host   = hostname();
my $whom   = getlogin();
my $path   = cwd();
my $script = basename($0);

# reload persisted data
if (-e "$Bin/$persist_file"){
    my $data = do "$Bin/$persist_file";
    # say p $data;
    $persist = $data;
}
# say p $persist;

if ($arg_list){
    list_sites();
    exit 0;
}

# Define a custom User-Agent
# - to use the environment-defined proxy
# - and because some websites refuse to serve Perl ⇒ 406 - Not acceptable
my $ua = new LWP::UserAgent( 
    env_proxy => 1,
    agent      => 'Mozilla/4.73 [en] (X11; I; Linux 2.2.16 i686; Nav)', 
    );

printf "%s --------------------------------------------------\n", stringify_datetime(time, 1);
# map { my $p = $_; say "$p->{name} = $p->{url}" } @$pages;
PAGE: for my $p (@$pages){
    my $name = $p->{name};
    my $url = $p->{url};
    my $enabled = $p->{enable} // 1;
    print "'$name'" if $arg_verbose;
    unless ($enabled){
        print " is disabled.\n" if $arg_verbose;
        next PAGE;
    }

    # get the page
    my $req = new HTTP::Request( GET => $url );
    my $res = $ua->request($req);
    
    my $status = $res->status_line;
    print " ($status)" if $arg_debug;

    if ($res->is_success){
        my $content;
        if( exists $p->{xpath} ){
            # if we provided a XPath, check that specific item
            my $xpath = $p->{xpath};
            my $tree = new HTML::TreeBuilder::XPath;
            $tree->parse($res->decoded_content);
            $content = $tree->findvalue($xpath);
            $tree->delete;
        } elsif (exists $p->{rx_match}){
            my $re = $p->{rx_match};
            # say $re;
            my $tree = new HTML::TreeBuilder;
            $tree->parse($res->decoded_content);
            $content = $tree->as_text;
            if ($content =~ /$re/){
                $content = $&;
            }
        } else {
            # else we are computing the change of the whole document
            $content = $res->decoded_content;
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
                if ($last_res !~ /^2/){
                    my $msg = "Previous check of $url got `$last_res`";
                    send_mail($mail_from, $mail_to, "'$name' is back online", $msg);
                }
                say " has not changed." if $arg_verbose;
            } else {
                say " HAS CHANGED !!!" if $arg_verbose;
                my $diff;
                if ($persist->{$name}{data}){
                    my $ori = uncompress(decode_base64($persist->{$name}{data}));
                    $diff = diff(\($ori."\n"), \($content."\n")) if $ori;
                }
                notify_change($name, $url, $diff);

                # Save the retrieved data only on fetch success & change
                # same comment than for md5_hex: compress expects bytes
                # we could also "use bytes;"
                my $data = encode_base64(compress($content), '');
                chomp($data);
                $persist->{$name}{data} = $data; # save the data for future diff
            }

        } else {
            # first time we have a result for the url
            say " was not monitored yet." if $arg_verbose;
        }
        $persist->{$name}{digest} = $digest; # save the hash
    } else {
        my $msg = "$url returned `" . $status .'`';
        say STDERR " $msg";
        if (defined $persist->{$name}{last_check_res} && $persist->{$name}{last_check_res} !~ /^2/){
            if ($persist->{$name}{last_check_res} ne $status){
                # different error from previous time
                $msg .= "\nPrevious check got `$persist->{$name}{last_check_res}`";
                send_mail($mail_from, $mail_to, "Different problem encountered while checking for '$name'", $msg);
            }
        } else {
            # first error
            send_mail($mail_from, $mail_to, "Problem encountered while checking for '$name'", $msg);
        }
    }
    
    $persist->{$name}{last_check_res} = $status;
    $persist->{$name}{last_check_time} = stringify_datetime(time, 1);
    $persist->{$name}{last_ok_time} = $persist->{$name}{last_check_time} if $res->is_success;
}

open my $p, '>', "$Bin/$persist_file" or die "Cannot open $Bin/$persist_file for saving states: $!";
my $dd = new Data::Dumper( [ $persist ] , [ 'persist' ] );
print $p $dd->Dump;
close $p;

sub list_sites {
    for my $site (sort { $a->{name} cmp $b->{name} } @$pages){
        my $url = $site->{url};
        $url .= "(Full page)" unless exists $site->{xpath};
        my $last = "";
        if ($arg_verbose){
            my $state = $persist->{$site->{name}};
            if (defined $state){
                $last .= " - $state->{last_check_res} ($state->{last_check_time})";
            }
            $last .= " (DISABLED)" unless $site->{enable} // 1;
        }
        say sprintf "%30s - %-60s%s", $site->{name}, $url, $last;
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
    my ($name, $url, $diff) = @_;
    $diff = $diff ? "\n\nDiff: $diff" : '';
    send_mail($mail_from, $mail_to, "Change detected for '$name'", <<"CHANGE");
A change has been detected in the page of "${name}"
URL is ${url}${diff}
CHANGE
}

sub send_mail {
    my ($from, $to, $subject, $message) = @_;
    
    my $smtp = Net::SMTP->new($mail_server, $arg_debug ? (Debug => 1) : ());
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
Sent by $path/$script from $whom\@$host.
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

v0.9

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

=back

=cut

# Local Variables: 
# coding: utf-8-unix
# mode: perl
# tab-width: 4
# indent-tabs-mode: nil
# End:
# ex: ts=4 sw=4 sts=4 et :
