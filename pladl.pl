#!/usr/bin/perl
#
# Copyright (C) 2018  Joel Pettersson
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

use 5.10.0;
use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);
use Getopt::Long qw(GetOptions);
use IO::Uncompress::Bunzip2 qw(bunzip2 $Bunzip2Error) ;
use List::Util qw(reduce);
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
my $filelist_bunzip = new IO::Uncompress::Bunzip2 $filelist_file
    or die "IO::Uncompress::Bunzip2 failed: $Bunzip2Error\n";
my $filelist_reader = XML::LibXML::Reader->new(IO => $filelist_bunzip)
    or die "cannot read file '$filelist_file': $!\n";

my @file_searches;
my @directory_searches;
my @full_path_searches;
my $active_searches_query = '//ADLSearch/SearchGroup/Search/IsActive[text()="1"]/..';

foreach my $search ($adl_search_xml->findnodes($active_searches_query)) {
    my $search_definition = {
        search_string     => $search->findvalue('./SearchString'),
        min_size          => $search->findvalue('./MinSize'),
        max_size          => $search->findvalue('./MaxSize'),
        size_type         => $search->findvalue('./SizeType'),
        dest_directory    => $search->findvalue('./DestDirectory'),
        is_case_sensitive => $search->findvalue('./IsCaseSensitive')
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

my $longest_dest_directory_name = reduce {
    my $longest = $a;
    my $challenger = length $b->{dest_directory};
    $challenger > $longest ? $challenger : $longest;
} 0, @file_searches, @directory_searches, @full_path_searches;

our %size_of = (
    B => 1,
    KiB => 1024,
    MiB => 1024 * 1024,
    GiB => 1024 * 1024 * 1024,
    kB => 1000,
    MB => 1000 * 1000,
    GB => 1000 * 1000 * 1000,
);

my @path;
my $total_matches = 0;

while ($filelist_reader->read) {
    my $node_type = $filelist_reader->nodeType;

    if ($node_type == &XML_READER_TYPE_ELEMENT) {
        my $element_name = $filelist_reader->name;

        next if $element_name eq 'FileListing';

        my $name_attr = $filelist_reader->getAttribute('Name');
        my $size_attr = $filelist_reader->getAttribute('Size') // 0;

        if ($element_name eq 'Directory') {
            $debug && say "Directory:\t$name_attr";
            push @path, $name_attr;
            $total_matches += match_directory($name_attr, \@path, $size_attr);
        } elsif ($element_name eq 'File') {
            $debug && say "File:\t$name_attr";
            $total_matches += match_file($name_attr, \@path, $size_attr);

            $debug && say "Full Path:\t" . catfile(@path, $name_attr);
            $total_matches += match_full_path($name_attr, \@path, $size_attr);
        } else {
            die "Unrecognized filelist XML element: '$element_name'";
        }
    } elsif ($node_type == &XML_READER_TYPE_END_ELEMENT &&
             $filelist_reader->name eq 'Directory') {
        pop @path;
    }
}

exit 1 if $total_matches == 0;

sub match_directory {
    my ($name, $path, $bytes) = @_;
    my $matches = 0;
    foreach my $search (@directory_searches) {
        if (match($search, $name, $bytes)) {
            $matches++;
            print_match($search->{dest_directory}, dirname(catfile(@{$path})), $name, $bytes);
        }
    }
    return $matches;
}

sub match_file {
    my ($name, $path, $bytes) = @_;
    my $matches = 0;
    foreach my $search (@file_searches) {
        if (match($search, $name, $bytes)) {
            $matches++;
            print_match($search->{dest_directory}, catfile(@{$path}), $name, $bytes);
        }
    }
    return $matches;
}

sub match_full_path {
    my ($name, $path, $bytes) = @_;
    my $matches = 0;
    foreach my $search (@full_path_searches) {
        if (match($search, catfile(@{$path}, $name), $bytes)) {
            $matches++;
            print_match($search->{dest_directory}, dirname(catfile(@{$path})), $name, $bytes);
        }
    }
    return $matches;
}

sub match {
    my ($search, $subject, $bytes) = @_;
    my $ignore_case = ($search->{is_case_sensitive} == 0) ? "i" : "";
    return (($search->{min_size} < 0 || $bytes >= $search->{min_size} * $size_of{$search->{size_type}}) &&
            ($search->{max_size} < 0 || $bytes <= $search->{max_size} * $size_of{$search->{size_type}}) &&
            $subject =~ /(?$ignore_case)$search->{search_string}/);
}

sub print_match {
    my ($dest_directory, $location, $name, $bytes) = @_;
    printf "%-${longest_dest_directory_name}s | %s | %s | %d\n", $dest_directory, $location, $name, $bytes;
}
