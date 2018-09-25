#!/usr/bin/perl

use 5.10.0;
use strict;
use warnings;

use Data::Dumper;
use File::Basename;
use File::Spec::Functions 'catfile';
use Getopt::Long qw(GetOptions);
use Pod::Usage qw(pod2usage);
use XML::LibXML::Reader;
use XML::LibXML;

my $help = 0;
my $debug = 0;

GetOptions(
    'help|?' => \$help,
    'debug' => \$debug,
) or pod2usage(2);

pod2usage("Usage: $0 <adl_search_file> <filelist_file>")
    if $help || @ARGV != 2;

my ($adl_search_file, $filelist_file) = @ARGV;

my $adl_search_xml = XML::LibXML->load_xml(location => $adl_search_file);
my $filelist_reader = XML::LibXML::Reader->new(location => $filelist_file)
    or die "cannot read file '$filelist_file': $!\n";

my @file_searches;
my @directory_searches;
my @full_path_searches;
my $active_searches_query = '//ADLSearch/SearchGroup/Search/IsActive[text()="1"]/..';

foreach my $search ($adl_search_xml->findnodes($active_searches_query)) {
    my $search_definition = {
        search_string   => $search->findvalue('./SearchString'),
        min_size        => $search->findvalue('./MinSize'),
        max_size        => $search->findvalue('./MaxSize'),
        size_type       => $search->findvalue('./SizeType'),
        dest_directory  => $search->findvalue('./DestDirectory'),
    };

    my $source_type = $search->findvalue('./SourceType');

    if ($source_type eq 'Filename') {
        push @file_searches, $search_definition;
    } elsif ($source_type eq 'Directory') {
        push @directory_searches, $search_definition;
    } elsif ($source_type eq 'Full Path') {
        push @full_path_searches, $search_definition;
    } else {
        $debug && print STDERR "Unknown ADL search source type: $source_type";
    }
}

my @path;

while ($filelist_reader->read) {
    my $node_type = $filelist_reader->nodeType;

    if ($node_type == &XML_READER_TYPE_ELEMENT) {
        my $element_name = $filelist_reader->name;
        my $name_attr = $filelist_reader->getAttribute('Name');

        next if $element_name eq 'FileListing';

        if ($element_name eq 'Directory') {
            $debug && say "Directory:\t$name_attr";
            push @path, $name_attr;
            match_directory($name_attr, \@path);
        } elsif ($element_name eq 'File') {
            my $size_attr = $filelist_reader->getAttribute('Size');

            $debug && say "File:\t$name_attr";
            match_file($name_attr, \@path, $size_attr);

            $debug && say "Full Path:\t" . catfile(@path, $name_attr);
            match_full_path($name_attr, \@path);
        } else {
            die "Unrecognized filelist XML element: '$element_name'";
        }
    } elsif ($node_type == &XML_READER_TYPE_END_ELEMENT &&
             $filelist_reader->name eq 'Directory') {
        pop @path;
    }
}

sub match_directory {
    my ($name, $path) = @_;

    foreach my $search (@directory_searches) {
        if ($name =~ /$search->{search_string}/) {
            say "$search->{dest_directory} " . dirname(catfile(@{$path})) . " : $name";
        }
    }
}

sub match_file {
    my ($name, $path, $bytes) = @_;
    my %size_of = (
        B => 1,
        KiB => 1024,
        MiB => 1024 * 1024,
        GiB => 1024 * 1024 * 1024,
        );

    foreach my $search (@file_searches) {
        my $min_bytes = $search->{min_size} * $size_of{$search->{size_type}};
        my $max_bytes = $search->{max_size} * $size_of{$search->{size_type}};

        if (($min_bytes < 0 || $bytes >= $min_bytes) &&
            ($max_bytes < 0 || $bytes <= $max_bytes) &&
            $name =~ /$search->{search_string}/)
        {
            say "$search->{dest_directory} " . catfile(@{$path}) . " : $name";
        }
    }
}

sub match_full_path {
    my ($name, $path) = @_;

    foreach my $search (@full_path_searches) {
        if (catfile(@{$path}, $name) =~ /$search->{search_string}/) {
            say "$search->{dest_directory} " . dirname(catfile(@{$path})) . " : $name";
        }
    }
}