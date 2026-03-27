#!/usr/bin/perl -w

use strict;
use warnings;
use JSON;
use LWP::UserAgent;
use IPC::Open3;

my $REPO_URL = "https://api.github.com/repos/nabovarme/MeterLogger/commits/master";
my $CHECK_INTERVAL = 30; # seconds

my $last_sha = "";

while (1) {

	my $ua = LWP::UserAgent->new;
	my $res = $ua->get($REPO_URL);

	if ($res->is_success) {
		my $json = decode_json($res->decoded_content);
		my $sha = $json->{sha};

		if (!$last_sha || $sha ne $last_sha) {
			print "Repo updated: $sha\n";

			$last_sha = $sha;

			trigger_build($sha);
		}
		else {
			print "No changes\n";
		}
	}
	else {
		warn "GitHub check failed: " . $res->status_line;
	}

	sleep($CHECK_INTERVAL);
}

sub trigger_build {
	my ($sha) = @_;

	print "Triggering build for $sha\n";

	# HER kalder du dit eksisterende build script
	system("./build_and_flash.pl 9999999");

	# senere: du kan vælge meter serial dynamisk
}
