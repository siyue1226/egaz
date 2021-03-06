#!/usr/bin/perl
use strict;
use warnings;
use autodie;

use Getopt::Long;
use Pod::Usage;
use YAML qw(Dump Load DumpFile LoadFile);

use File::Spec;
use File::Find::Rule;
use File::Basename;
use IO::Zlib;

use MCE;

use AlignDB::Stopwatch;
use AlignDB::Util qw(:all);

#----------------------------------------------------------#
# GetOpt section
#----------------------------------------------------------#
my $in_dir = '.';    # Specify location here
my $out_dir;         # Specify output dir here
my $length = 1000;   # Set the threshold of alignment length
my $subset;          # get sequences of listed names, seperated by comma

# run in parallel mode
my $parallel = 1;

my $gzip;            # open .gz

my $man  = 0;
my $help = 0;

GetOptions(
    'help|?'      => \$help,
    'man'         => \$man,
    'i|in_dir=s'  => \$in_dir,
    'o|out_dir=s' => \$out_dir,
    'l|length=i'  => \$length,
    'subset=s'    => \$subset,
    'parallel=i'  => \$parallel,
    'gzip'        => \$gzip,
) or pod2usage(2);

pod2usage(1) if $help;
pod2usage( -exitstatus => 0, -verbose => 2 ) if $man;

#----------------------------------------------------------#
# Init
#----------------------------------------------------------#
unless ($out_dir) {
    $out_dir = File::Spec->rel2abs($in_dir) . "_fasta";
    $out_dir = $out_dir . "_$subset" if $subset;
}
if ( !-e $out_dir ) {
    mkdir $out_dir, 0777;
}

#----------------------------------------------------------#
# Search for all files
#----------------------------------------------------------#
my @files;
if ( !$gzip ) {
    @files = sort File::Find::Rule->file->name('*.maf')->in($in_dir);
    printf "\n----Total .maf Files: %4s----\n\n", scalar @files;
}
if ( scalar @files == 0 or $gzip ) {
    @files = sort File::Find::Rule->file->name('*.maf.gz')->in($in_dir);
    printf "\n----Total .maf.gz Files: %4s----\n\n", scalar @files;
    $gzip++;
}

#----------------------------------------------------------#
# run
#----------------------------------------------------------#
my $worker = sub {
    my ( $self, $chunk_ref, $chunk_id ) = @_;

    # open files
    my $infile = $chunk_ref->[0];
    my $in_fh;
    if ( !$gzip ) {
        open $in_fh, '<', $infile;
    }
    else {
        $in_fh = IO::Zlib->new( $infile, "rb" );
    }

    my $outfile = basename($infile);
    $outfile = $out_dir . "/$outfile" . ".fas";
    open my $out_fh, ">", $outfile;

    # read and write
    my $content = '';
ALN: while ( my $line = <$in_fh> ) {
        if ( $line =~ /^\s+$/ and $content =~ /\S/ ) {    # meet blank line
            my @slines = grep {/\S/} split /\n/, $content;
            $content = '';

            # parse maf
            my @names;
            my $info_of = {};
            for my $sline (@slines) {
                my ( $s, $src, $start, $size, $strand, $srcsize, $text )
                    = split /\s+/, $sline;

                my ( $species, $chr_name ) = split /\./, $src;
                $chr_name = $species if !defined $chr_name;

                # adjust coordinates to be one-based inclusive
                $start = $start + 1;

                push @names, $species;
                $info_of->{$species} = {
                    seq        => $text,
                    name       => $species,
                    chr_name   => $chr_name,
                    chr_start  => $start,
                    chr_end    => $start + $size - 1,
                    chr_strand => $strand,
                };
            }

            if ($subset) {
                my $name_str = join " ", @names;
                my @subsets = split ",", $subset;
                next ALN if scalar @names < scalar @subsets;
                for (@subsets) {
                    next ALN if $name_str !~ /$_/;
                }
                @names = @subsets;
            }

            # output
            for my $species (@names) {
                printf {$out_fh} ">%s\n", encode_header( $info_of->{$species} );
                printf {$out_fh} "%s\n",  $info_of->{$species}{seq};
            }
            print {$out_fh} "\n";
        }
        elsif ( $line =~ /^#/ ) {    # comments
            next;
        }
        elsif ( $line =~ /^s\s/ ) {    # s line, contain info and seq
            $content .= $line;
        }
        else {                         # a, i, e, q lines
                # just ommit it
                # see http://genome.ucsc.edu/FAQ/FAQformat.html#format5
        }
    }

    # close file handlers
    if ( !$gzip ) {
        close $in_fh;
    }
    else {
        $in_fh->close;
    }
    close $out_fh;

    print ".fas file generated.\n\n";
};

# process each files
my $stopwatch = AlignDB::Stopwatch->new;

my $mce = MCE->new( chunk_size => 1, max_workers => $parallel, );
$mce->foreach( [ sort @files ], $worker );

$stopwatch->block_message( "All files have been processed.", "duration" );

exit;

__END__

=head1 NAME

    maf2fasta.pl - convert maf to fasta

=head1 SYNOPSIS
    perl maf2fasta.pl --in G:/S288CvsRM11

    maf2fasta.pl [options]
      Options:
        --help              brief help message
        --man               full documentation
        --in                maf files' location
        --out               output location
        --length            length threshold
        --parallel          run in parallel mode

=cut
