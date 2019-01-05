
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
use HTML::TreeBuilder::XPath;
use LWP::UserAgent;
use Net::SMTP;
use Pod::Usage;
use POSIX qw( strftime );
use Sys::Hostname;


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
my $pages        = $cfg->{pages};
my $persist_file = $cfg->{persist_file};
my $mail_from    = $cfg->{mail_from};
my $mail_to      = $cfg->{mail_to};
my $mail_server  = $cfg->{mail_server};
my $persist = {};

my $iso_time = '%Y-%m-%dT%H:%M:%SZ';
my $host = hostname();
my $whom = getlogin();
my $path = cwd();
my $script = basename($0);

if ($arg_list){
    list_sites();
    exit 0;
}

# reload persisted data
if (-e "$Bin/$persist_file"){
    my $data = do "$Bin/$persist_file";
    # say p $data;
    $persist = $data;
}
# say p $persist;


# Define a custom User-Agent
# - to use the environment-defined proxy
# - and because some websites refuse to serve Perl ⇒ 406 - Not acceptable
my $ua = new LWP::UserAgent( 
    env_proxy => 1,
    agent      => 'Mozilla/4.73 [en] (X11; I; Linux 2.2.16 i686; Nav)', 
    );

say strftime($iso_time, gmtime time);
# map { my $p = $_; say "$p->{name} = $p->{url}" } @$pages;
for my $p (@$pages){
    my $name = $p->{name};
    my $url = $p->{url};
    print "'$name'" if $arg_verbose;

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
        } else {
            # else we are computing the change of the whole document
            $content = $res->decoded_content;
        }
        # md5_hex expects a string of bytes for input, but content is a decoded string 
        # (i.e a string that may content Unicode Code Points). Explicitly encode the string if needed.
        my $digest = md5_hex( utf8::is_utf8($content) ? Encode::encode_utf8($content) : $content);
        if (defined $persist->{$name}{digest}){
            my $old = $persist->{$name}{digest};
            if ($digest eq $old){
                say " has not changed." if $arg_verbose;
            } else {
                say " HAS CHANGED !!!" if $arg_verbose;
                notify_change($name, $url);
            }

        } else {
            say " was not monitored yet." if $arg_verbose;
        }
        $persist->{$name}{digest} = $digest;
    }
    
    $persist->{$name}{last_check_res} = $status;
    $persist->{$name}{last_check_time} = strftime($iso_time, gmtime time);
}

open my $p, '>', "$Bin/$persist_file" or die "Cannot open $Bin/$persist_file for saving states: $!";
my $dd = new Data::Dumper( [ $persist ] , [ 'persist' ] );
print $p $dd->Dump;
close $p;

sub list_sites {
    for my $site (@$pages){
        my $detail = "";
        $detail = "(Full page)" unless exists $site->{xpath};
        say sprintf "%s - %s %s", $site->{name}, $site->{url}, $detail;
    }
}

sub notify_change {
    my ($name, $url) = @_;
    
    my $smtp = Net::SMTP->new($mail_server, $arg_debug ? (Debug => 1) : ());
    if($smtp){
        $smtp->mail($mail_from);
        if($smtp->to(split /,/, $mail_to)){
            $smtp->data(<<"MSG");
From: $mail_from
To: $mail_to
Subject: change detected for "$name"
Content-Type: text/plain;

I am $path/$script for $whom\@$host.

A change has been detected in the page of "$name"
URL is $url
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

=back

=cut

# Local Variables: 
# coding: utf-8-unix
# mode: perl
# tab-width: 4
# indent-tabs-mode: nil
# End:
# ex: ts=4 sw=4 sts=4 et :
