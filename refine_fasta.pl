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
use File::Remove qw(remove);
use List::Util qw(first max maxstr min minstr reduce shuffle sum);
use List::MoreUtils qw(any all);
use Math::Combinatorics;

use MCE;

use AlignDB::IntSpan;
use AlignDB::Stopwatch;
use AlignDB::Util qw(:all);

use FindBin;

#----------------------------------------------------------#
# GetOpt section
#----------------------------------------------------------#
my $in_dir = '.';    # Specify location here
my $out_dir;         # Specify output dir here
my $aln_prog = 'clustalw';    # Default alignment program

my $quick_mode   = undef;     # quick mode
my $indel_expand = 50;        # in quick mode, expand indel regoin
my $indel_join   = 50;        # in quick mode, join adjacent indel regions

my $outgroup;                 # has outgroup at the end
my $block;                    # input is galaxy style blocked fasta

# run in parallel mode
my $parallel = 1;

my $man  = 0;
my $help = 0;

GetOptions(
    'help|?'      => \$help,
    'man'         => \$man,
    'i|in_dir=s'  => \$in_dir,
    'o|out_dir=s' => \$out_dir,
    'msa=s'       => \$aln_prog,
    'quick'       => \$quick_mode,
    'outgroup'    => \$outgroup,
    'expand=i'    => \$indel_expand,
    'join=i'      => \$indel_join,
    'block'       => \$block,
    'parallel=i'  => \$parallel,
) or pod2usage(2);

pod2usage(1) if $help;
pod2usage( -exitstatus => 0, -verbose => 2 ) if $man;

#----------------------------------------------------------#
# make output dir
#----------------------------------------------------------#
unless ($out_dir) {
    $out_dir = File::Spec->rel2abs($in_dir) . "_$aln_prog";
    $out_dir = $out_dir . "_quick" if $quick_mode;
}

if ( -e $out_dir ) {
    warn "$out_dir exists, remove it.\n";
    remove( \1, $out_dir );
}

mkdir $out_dir, 0777;

#----------------------------------------------------------#
# Search for all files
#----------------------------------------------------------#
my @files
    = File::Find::Rule->file->name( '*.fa', '*.fas', '*.fasta' )->in($in_dir);
printf "\n----Total .fas Files: %4s----\n\n", scalar @files;

#----------------------------------------------------------#
# realign
#----------------------------------------------------------#
my $worker = sub {
    my ( $self, $chunk_ref, $chunk_id ) = @_;

    my $infile = $chunk_ref->[0];

    my $stopwatch = AlignDB::Stopwatch->new;
    print "Process $infile\n";

    my ( $seq_of, $seq_names ) = read_fasta($infile);

    if ( $aln_prog ne 'none' ) {
        if ($quick_mode) {
            realign_quick(
                $seq_of,
                $seq_names,
                {   indel_expand => $indel_expand,
                    indel_join   => $indel_join,
                    aln_prog     => $aln_prog,
                }
            );
        }
        else {
            realign_all( $seq_of, $seq_names );
        }
    }

    trim_pure_dash( $seq_of, $seq_names );

    if ($outgroup) {
        trim_outgroup( $seq_of, $seq_names );
    }
    if ($outgroup) {
        trim_complex_indel( $seq_of, $seq_names );
    }

    my $outfile = basename($infile);
    $outfile = $out_dir . "/$outfile";

    open my $out_fh, '>', $outfile
        or die("Cannot open OUT file $outfile");
    for my $name ( @{$seq_names} ) {
        my $seq = $seq_of->{$name};
        print {$out_fh} ">", $name, "\n";
        print {$out_fh} $seq, "\n";
    }
    close $out_fh;
    print "Done.\n\n";
};

my $worker_block = sub {
    my ( $self, $chunk_ref, $chunk_id ) = @_;

    my $infile = $chunk_ref->[0];

    my $stopwatch = AlignDB::Stopwatch->new;
    print "Process $infile\n";

    # don't use $/ = "\n\n", which cause bioperl panic
    open my $in_fh, "<", $infile;
    my $content = '';
    while ( my $line = <$in_fh> ) {
        if ( $line =~ /^\s+$/ and $content =~ /\S/ ) {
            my @lines = grep {/\S/} split /\n/, $content;
            $content = '';
            die "headers not equal to seqs\n" if @lines % 2;

            my ( $seq_of, $seq_names ) = ( {}, [] );

            # store simplified names
            # because names containing . + () |
            my $names = [ 0 .. @lines / 2 - 1 ];
            while (@lines) {
                my $name = shift @lines;
                $name =~ s/^\>//;
                chomp $name;
                my $seq = shift @lines;
                chomp $seq;
                push @{$seq_names}, $name;
                my $idx = scalar @{$seq_names} - 1;
                $seq_of->{$idx} = $seq;
            }

            if ( $aln_prog ne 'none' ) {
                if ($quick_mode) {
                    realign_quick(
                        $seq_of, $names,
                        {   indel_expand => $indel_expand,
                            indel_join   => $indel_join,
                            aln_prog     => $aln_prog,
                        }
                    );
                }
                else {
                    realign_all( $seq_of, $names );
                }
            }

            trim_pure_dash( $seq_of, $names );

            if ($outgroup) {
                trim_outgroup( $seq_of, $names );
            }
            if ($outgroup) {
                trim_complex_indel( $seq_of, $names );
            }

            my $outfile = basename($infile);
            $outfile = $out_dir . "/$outfile";

            open my $out_fh, '>>', $outfile;
            for my $i ( @{$names} ) {
                print {$out_fh} ">", $seq_names->[$i], "\n";
                print {$out_fh} $seq_of->{$i}, "\n";
            }
            print {$out_fh} "\n";
            close $out_fh;
        }
        else {
            $content .= $line;
        }
    }
    close $in_fh;
    print "Done.\n\n";
};

# process each .fasta files
my $stopwatch = AlignDB::Stopwatch->new;

my $mce = MCE->new( chunk_size => 1, max_workers => $parallel, );
$mce->foreach( [ sort @files ], $block ? $worker_block : $worker );

$stopwatch->block_message( "All files have been processed.", "duration" );
exit;

#----------------------------#
# realign all seqs
#----------------------------#
sub realign_all {
    my $seq_of    = shift;
    my $seq_names = shift;

    my @seqs;
    for ( @{$seq_names} ) {
        push @seqs, $seq_of->{$_};
    }

    my $realigned_seqs = multi_align( \@seqs, $aln_prog );

    for my $i ( 0 .. scalar @{$seq_names} - 1 ) {
        $seq_of->{ $seq_names->[$i] } = uc $realigned_seqs->[$i];
    }

    return;
}

__END__

=head1 NAME

    refine_fasta.pl - realign fasta file

=head1 SYNOPSIS
    perl refine_fasta.pl --in_dir G:/S288CvsRM11 --msa muscle --quick

    refine_fasta.pl [options]
      Options:
        --help              brief help message
        --man               full documentation
        --in_dir            fasta files' location
        --out_dir           output location
        --length            length threshold
        --msa               alignment program (none means don't do realigning)
        --quick             use quick mode
        --no_trim           don't trim outgroup sequence (the first one)
        --expand            in quick mode, expand indel region
        --join              in quick mode, join adjacent indel regions
        --parallel          run in parallel mode

=head1 DESCRIPTION

B<This program> will read the given input file(s) and do someting
useful with the contents thereof.

=cut
