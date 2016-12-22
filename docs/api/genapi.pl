#!/usr/bin/env perl
use strict;
use warnings;

use Pod::AsciiDoctor;

my $adoc = Pod::AsciiDoctor->new();

my $data_dir = "./src/";
opendir(DIR, $data_dir) or die("Cannot read directories: $data_dir");
my @files = grep { /\.pm$/ } readdir DIR;

foreach my $current_file (@files){

        open(my $ifh, '<', $data_dir.$current_file) or die ("Cannot open $current_file");
        print "Transforming $current_file\n";
        $current_file =~ s/^(.*)\.pm$/$1.asciidoc/;
        open(my $ofh, ">", $current_file) or die ("Cannot open $current_file");

        $adoc->append("include::header.asciidoc[]");
        $adoc->append("\n");
        # $adoc->append($adoc->make_header("head0", $current_file =~ s/(.*)\.*/API documentation for $1/ , 1));
        $adoc->parse_from_filehandle($ifh);

        print $ofh $adoc->adoc();
        close($ofh);
        close($ifh);

}

