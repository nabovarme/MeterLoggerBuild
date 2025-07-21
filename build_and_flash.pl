#!/usr/bin/perl -w

use strict;
use Data::Dumper;

use lib qw( MeterLogger/perl );
use Nabovarme::Db;

use constant SERIAL_PORT => $ENV{SERIAL_PORT} || '/dev/ttyUSB0';
use constant DOCKER_IMAGE => 'meterlogger:latest';
use constant BUILD_COMMAND => 'make firmware';
use constant FLASH_COMMAND => 'make flash PORT=' . SERIAL_PORT;
my $DEFAULT_BUILD_VARS = 'AP=1';

my $meter_serial = $ARGV[0] || '9999999';

# connect to db
my $dbh;
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
}

my $sth = $dbh->prepare(qq[SELECT `key`, `sw_version` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
$sth->execute;
if ($sth->rows) {
	$_ = $sth->fetchrow_hashref;
	my $key = $_->{key} || warn "no aes key found\n";
	my $sw_version = $_->{sw_version} || warn "no sw_version found\n";

	# parse options
	if ($_->{sw_version} =~ /NO_AUTO_CLOSE/) {
		$DEFAULT_BUILD_VARS .= ' AUTO_CLOSE=0';
	}

	if ($_->{sw_version} =~ /NO_CRON/) {
		$DEFAULT_BUILD_VARS .= ' NO_CRON=1';
	}

	if ($_->{sw_version} =~ /DEBUG_STACK_TRACE/) {
		$DEFAULT_BUILD_VARS .= ' DEBUG_STACK_TRACE=1';
	}

	if ($_->{sw_version} =~ /THERMO_ON_AC_2/) {
		$DEFAULT_BUILD_VARS .= ' THERMO_ON_AC_2=1';
	}

	# parse hw models
	if ($_->{sw_version} =~ /MC-B/) {
		print BUILD_COMMAND . " $DEFAULT_BUILD_VARS MC_66B=1 SERIAL=$meter_serial KEY=$key\n";
		system BUILD_COMMAND . " $DEFAULT_BUILD_VARS MC_66B=1 SERIAL=$meter_serial KEY=$key";
	}
	elsif ($_->{sw_version} =~ /MC/) {
		print BUILD_COMMAND . " $DEFAULT_BUILD_VARS EN61107=1 SERIAL=$meter_serial KEY=$key\n";
		system BUILD_COMMAND . " $DEFAULT_BUILD_VARS EN61107=1 SERIAL=$meter_serial KEY=$key";
	}
	elsif ($_->{sw_version} =~ /NO_METER/) {
		print BUILD_COMMAND . " $DEFAULT_BUILD_VARS DEBUG=1 DEBUG_NO_METER=1 SERIAL=$meter_serial KEY=$key\n";
		system BUILD_COMMAND . " $DEFAULT_BUILD_VARS DEBUG=1 DEBUG_NO_METER=1 SERIAL=$meter_serial KEY=$key";
	}
	else {
		print BUILD_COMMAND . " $DEFAULT_BUILD_VARS SERIAL=$meter_serial KEY=$key\n";
		system BUILD_COMMAND . " $DEFAULT_BUILD_VARS SERIAL=$meter_serial KEY=$key";
	}
	print FLASH_COMMAND . "\n";
	system 'echo ' . FLASH_COMMAND . ' | pbcopy';	# copy command to clipboard for repeated use
	system FLASH_COMMAND;
}

# end of main


__END__
