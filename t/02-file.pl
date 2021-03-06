#!/usr/bin/perl
use strict;
use warnings;

use FindBin;

my $cmd;

$cmd .= "perl $FindBin::Bin/../bz.pl";
$cmd .= " -dt $FindBin::Bin/S288C/chr01.fa";
$cmd .= " -dq $FindBin::Bin/RM11/supercontig1_1.fa";
$cmd .= " -dl $FindBin::Bin/S288CvsRM11_f";

print $cmd, "\n";
system($cmd);