#!/usr/bin/perl

###############################################################################
#
# (C) Copyright 2014 Riverbed Technology, Inc
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
###############################################################################

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use lib dirname(abs_path(__FILE__));

require "vadp_helper.pl";

#Initialize logging
Logger::initialize();


my %opts = (
    'luns' => {
    type => "=s",
    help => "Serial num of luns (comma seperated) that are being cleaned up",
    required => 1,
    },
    'datacenter' => {
    type => "=s",
    help => "Datacenter under which to look for cleaning up the snapshot lun",
    default => "",
    required => 0,
    },
    'include_hosts' => {
    type => "=s",
    help => "Comma separated host names (or regex) that are to be included for proxy setup",
    default => '.*',
    required => 0,
    },
    'exclude_hosts' => {
    type => "=s",
    help => "Comma separated host names (or regex) that are to be excluded for proxy setup NOTE: This overrides include_hosts",
,
    default => '',
    required => 0,
    },
    'fail_if_backup_in_progress' => {
    type => "=i",
    help => "Cleanup is aborted if backup is in progress.",
    default => 0,
    required => 0,
    },
    'extra_logging' => {
    type => "=i",
    help => "Set to > 0 for extra logging information",
    default => 0,
    required => 0,
    },
    #XXX This is required as this is an extra arg and has to be common to both
    #setup and cleanup. This will go away when setup and cleanup scripts get
    #seperate extra_args
    'vm_name_prefix' => {
        type => "=s",
        help => "This will be prefixed to the VM name when it is registered on the proxy",
    ,
        default => '',
        required => 0,
    }
);


Opts::add_options(%opts);

Opts::parse();
Opts::validate();

#Remaining args
my $lunlist = trim_wspace(Opts::get_option('luns'));
my $datacenter = trim_wspace(Opts::get_option('datacenter'));
my $fail_if_backup_in_progress = Opts::get_option('fail_if_backup_in_progress');
my $include_hosts = trim_wspace(Opts::get_option('include_hosts'));
my $exclude_hosts = trim_wspace(Opts::get_option('exclude_hosts'));
my $extra_logging = int(trim_wspace(Opts::get_option('extra_logging')));

my @luns = split('\s*,\s*', $lunlist);

LogHandle::set_global_params($luns[0], $extra_logging);

my $log = LogHandle->new("vadp_cleanup");

#Connect to the ESX server.
esxi_connect($log);

#Lookup datacenter
my $dc_view;
if ($datacenter ne "") {
    eval {
        $dc_view = lookup_datacenter($datacenter);
    };
    if ($@) {
        FAILURE("Error while looking up datacenter $datacenter");
    }
}

#Determine the serial
my $serial_wwn_hash;
eval {
    $serial_wwn_hash = get_wwn_names(\@luns, $dc_view, $include_hosts, $exclude_hosts);
};
if ($@) {
    FAILURE($@);
}
my @wwn_luns = {};
if (scalar(keys %$serial_wwn_hash) == 0) {
    $log->warn("Unable to locate the lun");
    SUCCESS();
}

for (keys %$serial_wwn_hash) {
    push(@wwn_luns, $serial_wwn_hash->{$_});
}

#Determine the datastore corresponding to the specified lun
my $lun_ds_hash = locate_datastores_for_luns(\@wwn_luns, $dc_view);
if (scalar(keys %$lun_ds_hash) == 0) {
    $log->warn("Unable to locate any datastores.");
    SUCCESS();
}

for (keys %$lun_ds_hash) {
    my $ds = $lun_ds_hash->{$_};
    my $ds_name = $ds->name;
    $log->debug("Located datastore $ds_name for lun $_");
}

my $umount_fail = 0;
foreach (keys %$lun_ds_hash) {
    my $other_ds_vms;
    my $datastore = $lun_ds_hash->{$_};
    eval {
        $other_ds_vms = unregister_vms($datastore, $fail_if_backup_in_progress);
    };
    if ($@) {
        $log->error("Failed to unregister the VMs, backup possibly in progress?");
        $umount_fail = 1;
    } else {
        eval {
            umount_and_detach($datastore);
        };
        if ($@) {
            $log->error("Unmount failure for $_: " . $datastore->name);
            $umount_fail = 1;
        }
        #Re-register VMs from other datastores after the unmount is complete.
        foreach (@$other_ds_vms) {
            my $vmx_path = $_;
            $log->diag("Re-registering VM $vmx_path");
            register_vm($vmx_path);
        }
    }
}

if ($umount_fail) {
    FAILURE("Unmount of datastore failed");
}

SUCCESS();
