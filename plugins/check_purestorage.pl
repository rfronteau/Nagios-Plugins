#!/usr/bin/perl

# ------------------------------------------------------------------------
# Program: check_purestorage
# Version: 0.03
# Author:  Romuald Fronteau - rfronteau@cfsl-asso.org
# License: GPLv3
# Copyright (c) 2016 Romuald Fronteau (http://www.tontonitch.com)

# COPYRIGHT:
# This software and the additional scripts provided with this software are
# Copyright (c) 2016 Romuald Fronteau (rfronteau@cfsl-asso.org)
# (Except where explicitly superseded by other copyright notices)
#
# LICENSE:
# This work is made available to you under the terms of version 3 of
# the GNU General Public License. A copy of that license should have
# been provided with this software.
# If not, see <http://www.gnu.org/licenses/>.
#
# This work is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# Nagios and the Nagios logo are registered trademarks of Ethan Galstad.
# ------------------------------------------------------------------------

use Data::Dumper;
use REST::Client;
use JSON;
use Net::SSL;
use strict;
use Getopt::Std;
use Switch;
 
# declare the perl command line flags/options we want to allow
my %optarg;
my $getopt_result;
my $api_tokens;
my $host;
my $mode;
my $debug = 0;
my $performance_data;
my $array_warn_percent;
my $array_crit_percent;
my $status;
my $drive;
my $listdegraded;
my $listfailed;
my $message;
my $drivetype;
my $componentlabel;
my $componentprobe;
my $nbalert;
my $longoutputalert;
sub do_help {
        print <<EOF;
Usage:
        $0 [-d] [-H hostname] [-t token_user_id] [-m mode] [-w warningthreshold] [-c criticalthreshold]

        -H  ... Hostname and Host
        -m  ... Mode : 
			iostat
				Control Global IOPS of PureStorage Array

			array-size
				Must have option -w and -c to fix Warning and Critical Threshold
				This mode control Volume size used in PureSotrage Array

			bandwidth
				This mode control bandwidth in and out of PureStorage Array

			array-latency
				This mode control latency read and write of PureStorage Array

			hardware
				This mode control health of Hardware components of PureStorage Array

			drive
				This mode control NVRAM & SSD Health

        -t  ... Token User Id
	-d  ... debug mode
Example:
        $0 -H DBA00099 -t c7d8bgdjb-bdghy-cgf67cbhn -m iostat
	$0 -H DBA00099 -t c7d8bgdjb-bdghy-cgf67cbhn -m array-size -w 85 -c 90'
	$0 -H DBA00099 -t c7d8bgdjb-bdghy-cgf67cbhn -m array-latency
	$0 -H DBA00099 -t c7d8bgdjb-bdghy-cgf67cbhn -m bandwidth
	$0 -H DBA00099 -t c7d8bgdjb-bdghy-cgf67cbhn -m hardware
	$0 -H DBA00099 -t c7d8bgdjb-bdghy-cgf67cbhn -m drive

EOF
}

$getopt_result = getopts('hH:t:m:dw:c:', \%optarg) ;

# Any invalid options?
if ( $getopt_result == 0 ) {
        do_help();
        exit 1;
}
if ( $optarg{h} ) {
        do_help();
        exit 0;
}

if ( defined($optarg{t}) ) {
        $api_tokens = $optarg{t};
}

if ( defined($optarg{m}) ) {
        $mode = $optarg{m};
	#print $mode;
}

if ( defined($optarg{H}) ) {
        $host = $optarg{H};
	#print $host;
}
if ( defined($optarg{d}) ) {
	$debug++;
}

if ( defined($optarg{w}) && defined($optarg{c})) {
	if(  $mode eq "array-size" ) {
        	$array_warn_percent = $optarg{w};
		$array_crit_percent = $optarg{c};
	}
}	
 

### Config

my $cookie_file = "/tmp/cookies.txt";

my $max_system_percent = 10;

our %ENV;
$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;

### Nagios exit codes

my $OKAY     = 0;
my $WARNING  = 1;
my $CRITICAL = 2;
my $UNKNOWN  = 3;

### Bootstrap

unless ( $host ) {
  print "No hostname given to check\n";
  exit $UNKNOWN
}

#my $token = $api_tokens{$host};

unless ( $api_tokens ) {
  print "No API token for host $host\n";
  exit $UNKNOWN
}

my @critical;
my @warning;
my @info;

### Start RESTing

my $client = REST::Client->new( follow => 1 );
$client->setHost('https://'.$host);

$client->addHeader('Content-Type', 'application/json');

$client->getUseragent()->cookie_jar({ file => $cookie_file });
$client->getUseragent()->ssl_opts(verify_hostname => 0);

### Check for API 1.4 support

my $ref = &api_get('/api/api_version');

my %api_versions;
for my $version (@{$ref->{version}}) {
  $api_versions{$version}++;
}

my $api_version = $api_versions{'1.4'} ? '1.4' :
                  $api_versions{'1.3'} ? '1.3' :
                  $api_versions{'1.1'} ? '1.1' :
                  $api_versions{'1.0'} ? '1.0' :
                  undef;

unless ( $api_version ) {
  print "API version 1.3 or 1.4 is not supported by host: $host\n";
  exit $UNKNOWN
}

### Set the Session Cookie

my $ret = &api_post("/api/$api_version/auth/session", { api_token => $api_tokens });


if ($mode eq "array-size") {
	if ( defined($optarg{w}) && defined($optarg{c})) {

		### Check the Array overall

		my $array_info = &api_get("/api/$api_version/array?space=true");

		for my $param (qw/system capacity total/) {
	  	  next if defined $array_info->{$param};
	  	  print "Array data lacks parameter: $param";
	  	  exit $UNKNOWN
		}

		if ( (100 * $array_info->{system} / $array_info->{capacity}) >= $max_system_percent ) {
	   	  my $percent = sprintf('%0.2f%%', (100 * $array_info->{system} / $array_info->{capacity}));
	   	  my $usage = human_readable_bytes($array_info->{system});
	   	  push @warning, "System space in use: $usage / $percent";
		}

		my $array_percent_used = sprintf('%0.2f', (100 * $array_info->{total} / $array_info->{capacity}));
		my $message = "Array is used at $array_percent_used\% | used=$array_percent_used\%;";

		if ( $array_percent_used > $array_crit_percent ) {
	  	  push @critical, $message;
		} elsif ( $array_percent_used > $array_warn_percent ) {
	  	  push @warning, $message;
		} else {
	  	  push @info, $message;
		}
	}else {
		do_help();
		exit 1;
	}
	
}

if ( $mode eq "iostat" ) {
	### Check the System Stats

	my $monitor_info = &api_get("/api/$api_version/array?action=monitor");
	for my $monitor (@$monitor_info) {
          for my $stats (qw/writes_per_sec reads_per_sec/) {
            next if defined $monitor->{$stats};
            print "Volume data lacks parameter: $stats";
            exit $UNKNOWN
          }
        }
	for my $monitor (@$monitor_info) {
	  $performance_data = "read_iops=$monitor->{reads_per_sec}; write_iops=$monitor->{writes_per_sec};";
	  my $message = "IOPs is (" . $monitor->{reads_per_sec} . "/" . $monitor->{writes_per_sec} . ") on Array | " . $performance_data;
	  push @info, $message
	}
}

if ( $mode eq "array-latency" ) {
        ### Check the Array Latency

        my $monitor_info = &api_get("/api/$api_version/array?action=monitor");
        for my $monitor (@$monitor_info) {
          for my $stats (qw/usec_per_read_op usec_per_write_op/) {
            next if defined $monitor->{$stats};
            print "Volume data lacks parameter: $stats";
            exit $UNKNOWN
          }
        }
        for my $monitor (@$monitor_info) {
          $performance_data = "read_latency=$monitor->{usec_per_read_op}µs; write_latency=$monitor->{usec_per_write_op}µs;";
	  my $message = "Latency is (" . $monitor->{usec_per_read_op} . "µs/" . $monitor->{usec_per_write_op} . "µs) on Array | " . $performance_data;
          push @info, $message
        }
}

if ( $mode eq "bandwidth" ) {
        ### Check the bandwith Array

        my $monitor_info = &api_get("/api/$api_version/array?action=monitor");
        for my $monitor (@$monitor_info) {
          for my $stats (qw/output_per_sec input_per_sec/) {
            next if defined $monitor->{$stats};
            print "Volume data lacks parameter: $stats";
            exit $UNKNOWN
          }
        }
        for my $monitor (@$monitor_info) {
          $performance_data = "bandwidth_in=$monitor->{input_per_sec}bps; bandwidth_out=$monitor->{output_per_sec}bps;";
          my $message = "Bandwith I/O is (" . $monitor->{input_per_sec} . "bps/" . $monitor->{output_per_sec} . "bps) on Array | " . $performance_data;
          push @info, $message
        }
}

if ( $mode eq "hardware" ) {
        ### Check the Hardware Health Array

        my $hardware_info = &api_get("/api/$api_version/hardware");
        for my $hardware (@$hardware_info) {
          for my $component (qw/name status/) {
            next if defined $hardware->{$component};
            print "Volume data lacks parameter: $component";
            exit $UNKNOWN
          }
        }
	
        for my $hardware (@$hardware_info) {
	  #print $hardware->{name} . " : " . $hardware->{status} . "\n";
	  if ( $hardware->{status} ne "ok" ){
	    my @tabhard = split /\./, $hardware->{name};
	    switch ($tabhard[0]) {
		case (/^SH.*/) { 
			$componentlabel = "Shelf " . $tabhard[0];
			#$componentslot .= $tab[1];
			#print $componentlabel . " " . $componentslot;
		}
		case (/^CT.*/) {
			$componentlabel = "Controller " . $tabhard[0];
		}
                case (/^CH.*/) {
                        $componentlabel = "Chassis " . $tabhard[0];
                }
	    }
	    switch ($tabhard[1]) {
                case (/^TMP.*/) {
                        $componentprobe = "Temperature " . $tabhard[1];
                }
                case (/^PWR.*/) {
                        $componentprobe = "Power Supply " . $tabhard[1];
                }
                case (/^FAN.*/) {
                        $componentprobe = "FAN " . $tabhard[1];
                }
		case (/^FC.*/) {
                        $componentprobe = "Fiber Channel Port " . $tabhard[1];
                }
		case (/^ETH.*/) {
                        $componentprobe = "Ethernet Port " . $tabhard[1];
                }
		case (/^IOM.*/) {
                        $componentprobe = "IO Module " . $tabhard[1];
                }
		case (/^SAS.*/) {
                        $componentprobe = "SAS Port " . $tabhard[1];
                }
            }
	    $listfailed .= $componentlabel . "-" . $componentprobe . "; ";
	    $status = 2
	  }
        }
	if ( $status == 1 ){
          $message = "Modules " . $drivetype . " are degraded (" . $listdegraded . ")\n";
          push @warning, $message
        } elsif ( $status == 2 ){
          $message = "Hardware components" . $drivetype . " are failed (" . $listfailed . ")\n";
          push @critical, $message
        } else {
          $message = "Hardware components are Healthy \n";
          push @info, $message
        }
}

if ( $mode eq "drive" ) {
        ### Check the Drive Health Array

        my $drive_info = &api_get("/api/$api_version/drive");
        for my $drive (@$drive_info) {
          for my $component (qw/name type degraded status/) {
            next if defined $drive->{$component};
            print "Volume data lacks parameter: $component";
            exit $UNKNOWN
          }
        }

        for my $drive (@$drive_info) {
          #print $drive->{type} . " " . $drive->{name} . " : " . $drive->{status} . "(degraded : " . $drive->{degraded} . ")\n";
	  if ( $drive->{degraded} != 0 ) {
	    $listdegraded .= $drive->{name} . " ";
	    $drivetype = $drive->{type};
	    $status = 1;
	  }
	  if ( $drive->{status} ne "healthy" ) {
            $listfailed .= $drive->{name} . " ";
	    $drivetype = $drive->{type};
	    $status = 2;
	  }
        }
	if ( $status == 1 ){
	  $message = "Modules " . $drivetype . " are degraded (" . $listdegraded . ")\n";
	  push @warning, $message
	} elsif ( $status == 2 ){
	  $message = "Modules " . $drivetype . " are failed (" . $listfailed . ")\n";
	  push @critical, $message
	} else {
	  $message = "Modules NVRAM & SSD are Healthy \n";
	  push @info, $message

	}
}

if ( $mode eq "alert" ) {
        ### Check the Alert Message Array

        my $alert_info = &api_get("/api/$api_version/message?flagged=true");
        for my $alert (@$alert_info) {
          for my $alert_message (qw/current_severity event component_name opened category id/) {
            next if defined $alert->{$alert_message};
            print "Volume data lacks parameter: $alert_message";
            exit $UNKNOWN
          }
        }
	for my $alert (@$alert_info) {
	  if ( $alert->{current_severity} eq "warning" ){
	    $status = 1;
	  }
	  if ( $alert->{current_severity} eq "critical" ){
            $status = 2;
          }
	  $nbalert++;
	  $longoutputalert .= $alert->{opened} . " - [CAT: " . $alert->{category} . "][ID:" . $alert->{id} . "] : " . $alert->{component_name} . " " . $alert->{event} . "\n";
        }
	if ( $status == 1 ){
          $message = $nbalert . " new(s) alert(s) are detected\n" . $longoutputalert;
          push @warning, $message
        } elsif ( $status == 2 ){
          $message = $nbalert . " new(s) alert(s) are detected\n" . $longoutputalert;
          push @critical, $message
        } else {
          $message = "Everythings are fine !\n";
          push @info, $message
        }
}
# Kill the session

$ret = $client->DELETE("/api/$api_version/auth/session");
unlink($cookie_file);

if ( scalar(@critical) > 0 ) {
  print 'CRITICAL : '.(shift @critical).' '.join(' ', map { '[ '.$_.' ]' } (@critical,@warning));
  exit $CRITICAL;
} elsif ( scalar(@warning) > 0 ) {
  print 'WARNING : '.(shift @warning).' '.join(' ', map { '[ '.$_.' ]' } @warning);
  exit $WARNING;
} else {
  print 'OK : '.(shift @info).' '.join(' ', map { '[ '.$_.' ]' } @info);
  exit $OKAY;
}

### Subs

sub api_get {
  my $url = shift @_;
  my $ret = $client->GET($url);
  my $num = $ret->responseCode();
  my $con = $ret->responseContent();
  if ( $num == 500 ) {
    print "API returned error 500 for '$url' - $con\n";
    exit $UNKNOWN
  }
  if ( $num != 200 ) {
    print "API returned code $num for URL '$url'\n";
    exit $UNKNOWN
  }
  print 'DEBUG: GET ', $url, ' -> ', $num, ":\n", Dumper(from_json($con)), "\n" if $debug;
  return from_json($con);
}

sub api_post {
  my $url = shift @_;
  my $con = shift @_;
  my $ret = $client->POST($url, to_json($con));
  my $num = $ret->responseCode();
  my $con = $ret->responseContent();
  if ( $num == 500 ) {
    print "API returned error 500 for '$url' - $con\n";
    exit $UNKNOWN
  }
  if ( $num != 200 ) {
    print "API returned code $num for URL '$url'\n";
    exit $UNKNOWN
  }
  print 'DEBUG: POST ', $url, ' -> ', $num, ":\n", Dumper(from_json($con)), "\n" if $debug;
  return from_json($con);
}

sub human_readable_bytes {
  my $raw = shift @_;
  if ( $raw > 500_000_000_000 ) {
    return sprintf('%.2f TB', ($raw/1_000_000_000_000));
  } elsif ( $raw > 500_000_000 ) {
    return sprintf('%.2f GB', ($raw/1_000_000_000));
  } else {
    return sprintf('%.2f MB', ($raw/1_000_000));
  }
}
