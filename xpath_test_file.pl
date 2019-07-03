
use strict;
use warnings;
use HTML::TreeBuilder::XPath;

die "Usage: $0 <file.html> /html/body/whatever" unless $#ARGV == 1;

my $t = new HTML::TreeBuilder::XPath;
$t->parse_file($ARGV[0]);
print $t->findvalue($ARGV[1]);

