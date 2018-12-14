
use strict;
use warnings;
use feature 'say';

use utf8;
use Data::Dumper;
use Data::Printer;
use Digest::MD5 'md5_hex';
use Encode;
use FindBin qw( $Bin ); # use to know the running dir $Bin is built-in variable
use LWP::UserAgent;
use MIME::Lite;
use POSIX qw( strftime );
use HTML::TreeBuilder::XPath;

my $cfg_file = "$Bin/check.cfg";

# get the smt authentication from (poor man's) config file
die "Missing config $cfg_file" unless -e $cfg_file;
my $cfg = do $cfg_file;
my $pages        = $cfg->{pages};
my $persist_file = $cfg->{persist_file};
my $mail_from    = $cfg->{mail_from};
my $mail_to      = $cfg->{mail_to};
my $persist = {};

my $iso_time = '%Y-%m-%dT%H:%M:%SZ';

# reload persisted data
if (-e "$Bin/$persist_file"){
    my $data = do "$Bin/$persist_file";
    # say p $data;
    $persist = $data;
}
# say p $persist;

my $ua = new LWP::UserAgent( 
    env_proxy => 1,
    agent      => 'Mozilla/4.73 [en] (X11; I; Linux 2.2.16 i686; Nav)', # some websites refuse to serve Perl (406 - Not acceptable)
    );

say strftime($iso_time, gmtime time);
# map { my $p = $_; say "$p->{name} = $p->{url}" } @$pages;
for my $p (@$pages){
    my $name = $p->{name};
    my $url = $p->{url};
    print "'$name'";

    # get the page
    my $req = new HTTP::Request( GET => $url );
    my $res = $ua->request($req);
    
    my $status = $res->status_line;
    print " ($status)";

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
                say " has not changed.";
            } else {
                say " HAS CHANGED !!!";
                my $mime = new MIME::Lite(
                    From => $mail_from,
                    To => $mail_to,
                    Subject => "change detected for $name",
                    Type    => "text/plain",
                    Data    => "I am $0\nA change has been detected in the page $url"
                    );
                $mime->send() or die "Failed to send mail: $!";
            }

        } else {
            say " was not monitored yet.";
        }
        $persist->{$name}{digest} = $digest;
    }
    
    $persist->{$name}{last_check_res} = $status;
    $persist->{$name}{last_check_time} = strftime($iso_time, gmtime time);
}

open my $p, '>', "$Bin/$persist_file" or die "Cannot open $Bin/$persist_file for save: $!";
my $dd = new Data::Dumper( [ $persist ] , [ 'persist' ] );
print $p $dd->Dump;
close $p;

# Local Variables: 
# coding: utf-8-unix
# mode: perl
# tab-width: 4
# indent-tabs-mode: nil
# End:
# ex: ts=4 sw=4 sts=4 et :
