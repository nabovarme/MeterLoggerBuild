#!/usr/bin/perl
# LED decode script with auto bit timing detection and smoothing
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);
use List::Util qw(min max);
use Image::Magick;

# --- CONFIGURATION ---
my $bits_per_sec	= 10;	# default bits per second (approx), will be auto detected
my $roi_size		= 12;	# ROI size (square in pixels)
my $search_margin   = 20;	# search window around last position
my $debug		   = 1;	 # print debug info
my $bit_smooth_window = 0;   # bit-level smoothing window (0 = off)
my $brightness_smooth_window = 5; # brightness smoothing window (must be odd)

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
		$fps = 30;  # fallback
	}
}
print "Detected FPS: $fps\n" if $debug;

# --- Step 1: Extract frames (downscale only) ---
my $frame_dir = tempdir(CLEANUP => 1);
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

my ($roi_cx, $roi_cy);
my @brightness_samples;

sub clamp {
	my ($val,$minv,$maxv) = @_;
	return $val < $minv ? $minv : ($val > $maxv ? $maxv : $val);
}

foreach my $idx (0..$#frames) {
	my $frame_file = "$frame_dir/$frames[$idx]";
	my $img = Image::Magick->new;
	$img->Read($frame_file);
	my ($img_w, $img_h) = $img->Get('width','height');

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

# --- Step 2.5: Brightness smoothing (moving average) ---
my @smoothed;
if ($brightness_smooth_window > 1 && $brightness_smooth_window % 2 == 1) {
	for my $i (0..$#brightness_samples) {
		my $start = $i - int($brightness_smooth_window/2);
		my $end   = $i + int($brightness_smooth_window/2);
		$start = 0 if $start < 0;
		$end   = $#brightness_samples if $end > $#brightness_samples;
		my $sum = 0;
		my $count = 0;
		for my $j ($start..$end) {
			$sum += $brightness_samples[$j];
			$count++;
		}
		push @smoothed, $sum / $count;
	}
} else {
	@smoothed = @brightness_samples;
}

# --- Step 3: Auto threshold ---
my $min_val = min(@smoothed);
my $max_val = max(@smoothed);
my $threshold = ($min_val + $max_val)/2;
print "Auto threshold: min=$min_val max=$max_val threshold=$threshold\n" if $debug;

my @raw_bits = map { $_ > $threshold ? 1 : 0 } @smoothed;

# --- Step 4: Detect frames per bit automatically using autocorrelation ---
sub autocorr {
	my ($data, $lag) = @_;
	my $n = @$data;
	return 0 if $lag <= 0 || $lag >= $n;

	my $mean = 0;
	$mean += $_ for @$data;
	$mean /= $n;

	my $num = 0;
	my $den = 0;
	for (my $i=0; $i < $n - $lag; $i++) {
		$num += (($data->[$i] - $mean) * ($data->[$i + $lag] - $mean));
		$den += ($data->[$i] - $mean)**2;
	}
	return $den == 0 ? 0 : $num / $den;
}

my $max_lag = int($fps / 2);  # max lag to search for autocorrelation peak
my $best_lag = 1;
my $best_corr = -1;

for my $lag (1..$max_lag) {
	my $corr = autocorr(\@smoothed, $lag);
	if ($corr > $best_corr) {
		$best_corr = $corr;
		$best_lag = $lag;
	}
}
my $frames_per_bit = $best_lag;
my $detected_bps = $fps / $frames_per_bit;
print "Auto detected frames per bit: $frames_per_bit (~$detected_bps bps)\n" if $debug;

# --- Step 5: Optional bit smoothing (debounce glitches) ---
if ($bit_smooth_window && $bit_smooth_window > 1) {
	my @smoothed_bits;
	for my $i (0..$#raw_bits) {
		my $start = $i - int($bit_smooth_window/2);
		my $end = $i + int($bit_smooth_window/2);
		$start = 0 if $start < 0;
		$end = $#raw_bits if $end > $#raw_bits;
		my $sum = 0;
		for my $j ($start..$end) {
			$sum += $raw_bits[$j];
		}
		push @smoothed_bits, ($sum > (($end-$start+1)/2) ? 1 : 0);
	}
	@raw_bits = @smoothed_bits;
}

# --- Step 6: Decode bits from frames ---
my @decoded_bits;
for (my $i=0; $i < @raw_bits; $i += $frames_per_bit) {
	# Take majority bit in window
	my $ones = 0;
	my $total = 0;
	for my $j ($i..$i + $frames_per_bit - 1) {
		last if $j > $#raw_bits;
		$ones += $raw_bits[$j];
		$total++;
	}
	my $bit = ($ones > $total/2) ? 1 : 0;
	push @decoded_bits, $bit;
}

print "Decoded bits: " . join('', @decoded_bits) . "\n";

# --- Step 7: Save CSV ---
open my $csv, '>', "brightness_trace.csv" or die "Can't open CSV for writing: $!\n";
print $csv "frame,raw_brightness,smoothed_brightness,threshold,bit\n";
for my $i (0..$#brightness_samples) {
	print $csv join(',', $i, $brightness_samples[$i], $smoothed[$i], $threshold, $raw_bits[$i]) . "\n";
}
close $csv;
print "Saved brightness trace to brightness_trace.csv\n";

# --- Step 8: Generate plot of brightness and bits ---
eval {
	require GD::Graph::lines;
	my @plot_data = (
		[0..$#brightness_samples],
		\@brightness_samples,
		\@smoothed,
		[ map { $_ ? $max_val : $min_val } @raw_bits ],
	);
	my $graph = GD::Graph::lines->new(800,400);
	$graph->set(
		x_label		   => 'Frame',
		y_label		   => 'Brightness',
		title			 => 'LED Brightness Trace',
		y_min_value	   => 0,
		y_max_value	   => 1,
		y_tick_number	 => 10,
		line_types		=> [1,2,3],
		line_width		=> 2,
		legend_placement  => 'RC',
		legend			=> ['Raw', 'Smoothed', 'Bit'],
	);
	my $gd = $graph->plot(\@plot_data);
	open my $png, '>', 'brightness_plot.png' or die "Can't save plot PNG: $!";
	binmode $png;
	print $png $gd->png;
	close $png;
	print "Saved brightness plot to brightness_plot.png\n";
};
warn "Could not generate plot: $@" if $@;

# --- DONE ---
print "Processing complete.\n";
