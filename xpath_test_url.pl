
use strict;
use warnings;
use HTML::TreeBuilder::XPath;
use LWP::UserAgent;

die "Usage: $0 <url> /html/body/whatever" unless $#ARGV == 1;

my $url = $ARGV[0];
my $t = new HTML::TreeBuilder::XPath;
my $ua = LWP::UserAgent->new(timeout => 10);
$ua->env_proxy;
my $response = $ua->get($url);
if ($response->is_success){
    $t->parse( $response->decoded_content);
    $t->eof;
    print $t->findvalue($ARGV[1]);
} else {
    print "Fetching $url failed: " . $response->status_line;
}
