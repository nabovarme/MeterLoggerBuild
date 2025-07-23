#!/usr/bin/perl
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);
use List::Util qw(min max);

# --- CONFIGURATION ---
my $fps			 = 120;			   # must match video frame rate
my $bits_per_sec	= 10;			   # initial guess, will be auto-detected
my $frames_per_bit  = $fps / $bits_per_sec;  # will be updated dynamically
my @preamble		= (1,0,1,0,1,0,1,0); # raw preamble (before Manchester)
my $roi_size		= 12;			   # ROI size (square in pixels)
my $search_margin   = 20;			   # search window around last position
my $debug		   = 1;

# --- Arguments ---
my $video_file;
my $smooth_window = 0;	  # brightness smoothing
my $bit_smooth_window = 0;  # bit-level smoothing (debounce)

while (@ARGV) {
	my $arg = shift @ARGV;
	if ($arg eq '--smooth') {
		$smooth_window = shift @ARGV // 0;
	} elsif ($arg eq '--bit-smooth') {
		$bit_smooth_window = shift @ARGV // 0;
	} else {
		$video_file = $arg;
	}
}
die "Usage: $0 <video_file> [--smooth N] [--bit-smooth N]\n" unless $video_file;

# --- Step 1: Extract frames (downscale only) ---
my $frame_dir = tempdir(CLEANUP => 0);
my $ffmpeg = "/opt/local/bin/ffmpeg";
system($ffmpeg, '-y', '-i', $video_file,
	'-vf', "scale=128:128",
	"$frame_dir/frame%05d.png") == 0
	or die "ffmpeg failed: $!\n";

# --- Step 2: Process frames (ROI + blue channel) ---
opendir(my $dh, $frame_dir) or die "Cannot open $frame_dir: $!\n";
my @frames = sort grep { /\.png$/ } readdir($dh);
closedir($dh);
die "No frames extracted!\n" unless @frames;

use Image::Magick;

my ($roi_cx, $roi_cy);
my @brightness_samples;
my @roi_positions;

sub clamp {
	my ($val,$minv,$maxv) = @_;
	return $val < $minv ? $minv : ($val > $maxv ? $maxv : $val);
}

foreach my $idx (0..$#frames) {
	my $frame_file = "$frame_dir/$frames[$idx]";
	my $img = Image::Magick->new;
	$img->Read($frame_file);
	my ($img_w, $img_h) = $img->Get('width','height');
	my $quantum = $img->Get('quantumrange') || 65535;

	# Define search region
	my ($search_x1, $search_y1, $search_x2, $search_y2);
	if (!defined $roi_cx or !defined $roi_cy) {
		($search_x1,$search_y1,$search_x2,$search_y2) = (0,0,$img_w-1,$img_h-1);
	} else {
		$search_x1 = clamp($roi_cx - $search_margin, 0, $img_w - 1);
		$search_y1 = clamp($roi_cy - $search_margin, 0, $img_h - 1);
		$search_x2 = clamp($roi_cx + $search_margin, 0, $img_w - 1);
		$search_y2 = clamp($roi_cy + $search_margin, 0, $img_h - 1);
	}

	# Find brightest pixel in blue channel
	my $max_brightness = -1;
	my ($max_x, $max_y) = (0,0);
	for my $y ($search_y1 .. $search_y2) {
		for my $x ($search_x1 .. $search_x2) {
			my @pixel = $img->GetPixel(x=>$x, y=>$y); # [R,G,B] normalized 0-1
			my $b = $pixel[2]; # blue channel
			if ($b > $max_brightness) {
				$max_brightness = $b;
				($max_x,$max_y) = ($x,$y);
			}
		}
	}

	if ($max_brightness > 0.05) {
		($roi_cx,$roi_cy) = ($max_x,$max_y);
	}
	push @roi_positions, [$roi_cx,$roi_cy];

	# Average brightness in ROI
	my $roi_x1 = clamp($roi_cx - int($roi_size/2), 0, $img_w-1);
	my $roi_y1 = clamp($roi_cy - int($roi_size/2), 0, $img_h-1);
	my $roi_x2 = clamp($roi_cx + int($roi_size/2), 0, $img_w-1);
	my $roi_y2 = clamp($roi_cy + int($roi_size/2), 0, $img_h-1);

	my $sum_b = 0; my $count = 0;
	for my $y ($roi_y1 .. $roi_y2) {
		for my $x ($roi_x1 .. $roi_x2) {
			my @pixel = $img->GetPixel(x=>$x, y=>$y);
			$sum_b += $pixel[2]; # blue channel only
			$count++;
		}
	}
	my $avg_b = $count ? $sum_b / $count : 0;
	push @brightness_samples, $avg_b;

	undef $img;

	print "Frame $idx: ROI=($roi_cx,$roi_cy) Brightness=$avg_b\n" if $debug;
}

# --- Step 3: Optional smoothing (brightness) ---
if ($smooth_window && $smooth_window > 1) {
	my @smoothed;
	for my $i (0..$#brightness_samples) {
		my $sum = 0; my $count = 0;
		for my $j (-int($smooth_window/2) .. int($smooth_window/2)) {
			my $k = $i+$j;
			next if $k<0 or $k>@brightness_samples-1;
			$sum += $brightness_samples[$k]; $count++;
		}
		push @smoothed, $sum/$count;
	}
	@brightness_samples = @smoothed;
	print "Applied $smooth_window-frame brightness smoothing\n" if $debug;
}

# --- Step 3.5: Estimate frames per bit automatically using autocorrelation ---
sub autocorr {
	my ($data) = @_;
	my $n = @$data;
	my @result;
	for my $lag (1..int($n/2)) {
		my $sum = 0;
		for my $i (0..$n-$lag-1) {
			$sum += abs($data->[$i] - $data->[$i+$lag]);
		}
		$result[$lag] = $sum;
	}
	return @result;
}

my @diffs = autocorr(\@brightness_samples);

my $best_lag = 1;
my $best_val = $diffs[1] // 1e9;

for my $lag (2..$#diffs) {
	if (defined $diffs[$lag] && $diffs[$lag] < $best_val) {
		$best_val = $diffs[$lag];
		$best_lag = $lag;
	}
}

print "Estimated frames per bit: $best_lag\n" if $debug;
$frames_per_bit = $best_lag;

# --- Step 4: Auto threshold ---
my $min_val = min(@brightness_samples);
my $max_val = max(@brightness_samples);
my $threshold = ($min_val + $max_val)/2;
print "Auto threshold: min=$min_val max=$max_val threshold=$threshold\n" if $debug;

my @raw_bits = map { $_ > $threshold ? 1 : 0 } @brightness_samples;

# --- Optional bit smoothing (debounce glitches) ---
if ($bit_smooth_window && $bit_smooth_window > 1) {
	my @debounced = @raw_bits;
	for my $i (0..$#raw_bits) {
		my $sum=0; my $count=0;
		for my $j (-int($bit_smooth_window/2)..int($bit_smooth_window/2)) {
			my $k = $i+$j; next if $k<0 or $k>@raw_bits-1;
			$sum += $raw_bits[$k]; $count++;
		}
		$debounced[$i] = $sum > $count/2 ? 1:0;
	}
	@raw_bits = @debounced;
	print "Applied $bit_smooth_window-sample bit smoothing\n" if $debug;
}

print "Raw bits:\n", map { $_ ? '-' : '.' } @raw_bits, "\n" if $debug;

# --- Step 5: Manchester decode ---
my @manchester_preamble;
for my $bit (@preamble) {
	push @manchester_preamble, $bit ? (0,1) : (1,0);
}
my $man_len = @manchester_preamble;

my $sync_index = -1;
for my $i (0..@raw_bits-$man_len) {
	my $ok=1;
	for my $j (0..$man_len-1) {
		if ($raw_bits[$i+$j] != $manchester_preamble[$j]) { $ok=0; last; }
	}
	if ($ok) { $sync_index=$i; last; }
}
die "No sync found\n" if $sync_index==-1;
print "Sync at $sync_index\n" if $debug;

my @manchester_data_bits = @raw_bits[$sync_index+$man_len .. $#raw_bits];
my $decoded_bitstream="";
for (my $i=0; $i<@manchester_data_bits; $i+=2) {
	last if $i+1>=@manchester_data_bits;
	my $pair = $manchester_data_bits[$i].$manchester_data_bits[$i+1];
	if ($pair eq '10') { $decoded_bitstream.='0'; }
	elsif ($pair eq '01') { $decoded_bitstream.='1'; }
	else { last; }
}

print "Decoded bitstream: $decoded_bitstream\n";
