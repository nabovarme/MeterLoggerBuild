#!/usr/bin/perl
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);
use List::Util qw(min max);
use Image::Magick;

# --- CONFIGURATION ---
my $roi_size	= 12;
my $search_margin = 20;
my $debug	   = 1;
my $bit_smooth_window = 0;
my $brightness_smooth_window = 5;

# --- Arguments ---
my $video_file;
while (@ARGV) {
	my $arg = shift @ARGV;
	if ($arg eq '--bit-smooth') {
		$bit_smooth_window = shift @ARGV // 0;
	} elsif ($arg eq '--smooth') {
		$brightness_smooth_window = shift @ARGV // 5;
	} else {
		$video_file = $arg;
	}
}
die "Usage: $0 <video_file> [--smooth N] [--bit-smooth N]\n" unless $video_file;

# --- Step 0: Detect FPS ---
my $ffprobe = "/opt/local/bin/ffprobe";
my $fps = 0;
{
	open my $fh, "-|", "$ffprobe -v 0 -of csv=p=0 -select_streams v:0 -show_entries stream=r_frame_rate \"$video_file\"" or die "ffprobe failed: $!";
	my $r_frame_rate = <$fh>;
	close $fh;
	chomp $r_frame_rate if defined $r_frame_rate;
	if ($r_frame_rate =~ m|(\d+)/(\d+)|) {
		$fps = $1 / $2;
	} else {
		$fps = 30;
	}
}
print "Detected FPS: $fps\n" if $debug;

# --- Step 1: Extract frames ---
my $frame_dir = tempdir(CLEANUP => 1);
my $ffmpeg = "/opt/local/bin/ffmpeg";
system($ffmpeg, '-y', '-i', $video_file,
	'-vf', "scale=128:128",
	"$frame_dir/frame%05d.png") == 0
	or die "ffmpeg failed: $!\n";

# --- Step 2: Brightness tracking ---
opendir(my $dh, $frame_dir) or die "Cannot open $frame_dir: $!\n";
my @frames = sort grep { /\.png$/ } readdir($dh);
closedir($dh);
die "No frames extracted!\n" unless @frames;

my ($roi_cx, $roi_cy);
my @brightness_samples;

sub clamp {
	my ($v,$minv,$maxv) = @_;
	return $v<$minv?$minv:($v>$maxv?$maxv:$v);
}

foreach my $idx (0..$#frames) {
	my $frame_file = "$frame_dir/$frames[$idx]";
	my $img = Image::Magick->new;
	$img->Read($frame_file);
	my ($img_w, $img_h) = $img->Get('width','height');

	my ($sx1,$sy1,$sx2,$sy2);
	if (!defined $roi_cx) {
		($sx1,$sy1,$sx2,$sy2) = (0,0,$img_w-1,$img_h-1);
	} else {
		$sx1 = clamp($roi_cx - $search_margin,0,$img_w-1);
		$sy1 = clamp($roi_cy - $search_margin,0,$img_h-1);
		$sx2 = clamp($roi_cx + $search_margin,0,$img_w-1);
		$sy2 = clamp($roi_cy + $search_margin,0,$img_h-1);
	}

	my $max_b = -1;
	my ($mx,$my) = (0,0);
	for my $y ($sy1..$sy2) {
		for my $x ($sx1..$sx2) {
			my @px = $img->GetPixel(x=>$x,y=>$y);
			my $b = $px[2];
			if ($b > $max_b) { $max_b = $b; ($mx,$my)=($x,$y); }
		}
	}
	($roi_cx,$roi_cy)=($mx,$my) if $max_b>0.05;

	my $rx1 = clamp($roi_cx - int($roi_size/2),0,$img_w-1);
	my $ry1 = clamp($roi_cy - int($roi_size/2),0,$img_h-1);
	my $rx2 = clamp($roi_cx + int($roi_size/2),0,$img_w-1);
	my $ry2 = clamp($roi_cy + int($roi_size/2),0,$img_h-1);
	my ($sum_b,$count)=(0,0);
	for my $y ($ry1..$ry2) {
		for my $x ($rx1..$rx2) {
			my @px = $img->GetPixel(x=>$x,y=>$y);
			$sum_b += $px[2];
			$count++;
		}
	}
	push @brightness_samples, $count ? $sum_b/$count : 0;
	undef $img;
}

# Smooth brightness
my @smoothed;
if ($brightness_smooth_window>1 && $brightness_smooth_window%2==1) {
	for my $i (0..$#brightness_samples) {
		my $s = $i-int($brightness_smooth_window/2);
		my $e = $i+int($brightness_smooth_window/2);
		$s=0 if $s<0; $e=$#brightness_samples if $e>$#brightness_samples;
		my $sum=0; my $cnt=0;
		$sum+=$brightness_samples[$_] for $s..$e;
		$cnt=$e-$s+1;
		push @smoothed, $sum/$cnt;
	}
} else {
	@smoothed=@brightness_samples;
}

# Threshold
my $min_v = min(@smoothed);
my $max_v = max(@smoothed);
my $thr = ($min_v+$max_v)/2;
print "Auto threshold: min=$min_v max=$max_v thr=$thr\n" if $debug;
my @raw_bits = map { $_>$thr?1:0 } @smoothed;
print "Frame-level bits: ", join('',@raw_bits), "\n" if $debug;

# --- Detect frames_per_bit using preamble 10101010 ---
sub detect_frames_per_bit_from_preamble {
	my ($bits_ref) = @_;
	my @bits = @$bits_ref;

	# Find longest run of 10101010 in raw bits (allow ~20% mismatch per symbol)
	my $best_start = -1;
	my $best_len = 0;
	for my $i (0..$#bits-80) {  # search 80 frames at a time
		my $window = join('', @bits[$i..$i+79]);
		my $ones = ($window =~ tr/1//);
		my $zeros = ($window =~ tr/0//);
		# Look for a balanced mix, not flatline
		if ($ones > 30 && $zeros > 30) {
			if (length($window) > $best_len) {
				$best_len = length($window);
				$best_start = $i;
			}
		}
	}
	die "Could not detect preamble region!\n" if $best_start < 0;

	# Measure edge distances in that region
	my @edges;
	my $last = $bits[$best_start];
	for my $i ($best_start..$best_start+$best_len-1) {
		if ($bits[$i] != $last) {
			push @edges, $i;
			$last = $bits[$i];
		}
	}
	die "No edges in preamble!\n" unless @edges > 1;

	my @periods;
	for (my $j=1;$j<@edges;$j++) {
		push @periods, $edges[$j]-$edges[$j-1];
	}

	# Average period with slack (ignore outliers ±20%)
	my $mean = 0; $mean+=$_ for @periods; $mean /= @periods;
	my @valid = grep { $_ > 0.8*$mean && $_ < 1.2*$mean } @periods;
	$mean = 0; $mean+=$_ for @valid; $mean /= @valid;

	return int($mean+0.5);
}

my $frames_per_bit = detect_frames_per_bit_from_preamble(\@raw_bits);
print "Detected frames_per_bit=$frames_per_bit (~".($fps/$frames_per_bit)." bps)\n" if $debug;

# --- Collapse to bit stream (majority vote) ---
my @bits;
for (my $i=0;$i<@raw_bits;$i+=$frames_per_bit){
	my $ones=0; my $tot=0;
	for my $j ($i..$i+$frames_per_bit-1){ last if $j>$#raw_bits; $ones+=$raw_bits[$j];$tot++; }
	push @bits, ($ones>$tot/2)?1:0;
}
print "Symbol bits: ", join('',@bits), "\n" if $debug;

# --- Step: Find preamble (10101010) ---
my @preamble=(1,0,1,0,1,0,1,0);
my $start=-1;
for my $i (0..$#bits-7){
	if (join('',@bits[$i..$i+7]) eq '10101010'){ $start=$i+8; last; }
}
die "Preamble not found!\n" if $start==-1;
print "Preamble found at index $start (payload starts)\n" if $debug;

# --- Step: Extract payload bits ---
my @payload = @bits[$start..$#bits];

# --- Hamming(7,4) decode ---
sub hamming74_decode {
	my @b=@_;
	my $s1=$b[0]^$b[2]^$b[4]^$b[6];
	my $s2=$b[1]^$b[2]^$b[5]^$b[6];
	my $s3=$b[3]^$b[4]^$b[5]^$b[6];
	my $err=$s1*1+$s2*2+$s3*4;
	$b[$err-1]^=1 if $err;
	return ($b[2],$b[4],$b[5],$b[6]); # data bits (4 bits)
}

my @nibbles;
for (my $i=0;$i+6<@payload;$i+=7){
	push @nibbles, join('',hamming74_decode(@payload[$i..$i+6]));
}

# Combine nibbles into bytes
my @bytes;
for (my $i=0;$i+1<@nibbles;$i+=2){
	my $hi=oct("0b$nibbles[$i]");
	my $lo=oct("0b$nibbles[$i+1]");
	push @bytes, chr(($hi<<4)|$lo);
}
print "Decoded string: ", join('',@bytes), "\n";

print "Processing complete.\n";
