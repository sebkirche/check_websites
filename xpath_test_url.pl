#!/usr/bin/env perl

use strict;
use warnings;
use feature 'say';
use HTML::TreeBuilder::XPath;
use LWP::UserAgent;

die "Usage: $0 <url> /html/body/whatever" unless $#ARGV == 1;

my $url = $ARGV[0];
my $t = new HTML::TreeBuilder::XPath;
my $ua = LWP::UserAgent->new(timeout => 10,
                             agent   => 'Mozilla/4.73 [en] (X11; I; Linux 2.2.16 i686; Nav)');
$ua->env_proxy;
my $response = $ua->get($url);
say $response->status_line;
if ($response->is_success){
    say $response->content unless $ARGV[1];
    $t->parse( $response->content);
    $t->eof;
    if($ARGV[1]){
        say $t->findvalue($ARGV[1]);
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
    }
} else {
    print "Fetching $url failed: " . $response->status_line;
}
