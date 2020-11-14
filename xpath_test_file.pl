
use strict;
use warnings;
use feature 'say';
use HTML::TreeBuilder::XPath;

die "Usage: $0 <file.html> /html/body/whatever" unless $#ARGV == 1;

my $t = new HTML::TreeBuilder::XPath;
$t->parse_file($ARGV[0]);
# print $t->findvalue($ARGV[1]);



my @nodes = $t->findnodes($ARGV[1]);
if (@nodes){
    for my $node (@nodes){
        my $text;
        # node can be HTML::TreeBuilder::XPath::TextNode
        #             HTML::TreeBuilder::XPath::Node
        #             HTML::Element
        # use Data::Printer;
        # say p $node;
        
        if ($node->isa('HTML::TreeBuilder::XPath::TextNode')){
            $text = $node->getValue;
        } elsif ($node->isa('HTML::Element') && scalar $node->descendants == 0) {
            $text = $node->getValue;
        } else {
            $text = $node->as_XML;
        }
        say "---\n${text}";
    }
} else {
    say "No match.";
}
