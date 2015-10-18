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
    help => "Serial num of luns (comma seperated) that are being protected",
    required => 1,
    },
    'include_vms' => {
    type => "=s",
    help => "Comma separated vm names (or regex) that are to be registered",
    default => '.*',
    required => 0,
    },
    'exclude_vms' => {
    type => "=s",
    help => "Comma separated vm names (or regex) that are to be excluded. NOTE: This overrides include_vms",
    default => '',
    required => 0,
    },
    'datacenter' => {
    type => "=s",
    help => "Datacenter under which to mount the snapshot lun",
    default => '',
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
    'vm_name_prefix' => {
        type => "=s",
        help => "This will be prefixed to the VM name when it is registered on the proxy",
    ,
        default => 'granite_clone_',
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
    'fail_if_backup_in_progress' => {
    type => "=i",
    help => "Cleanup is aborted if backup is in progress.",
    default => 0,
    required => 0,
    },
);

print ("Args are: @ARGV"); 
Opts::add_options(%opts);

Opts::parse();
Opts::validate();


my $lunlist = trim_wspace(Opts::get_option('luns'));
my $include_vms = trim_wspace(Opts::get_option('include_vms'));
my $exclude_vms = trim_wspace(Opts::get_option('exclude_vms'));
my $datacenter = trim_wspace(Opts::get_option('datacenter'));
my $include_hosts = trim_wspace(Opts::get_option('include_hosts'));
my $exclude_hosts = trim_wspace(Opts::get_option('exclude_hosts'));
my $vm_name_prefix = trim_wspace(Opts::get_option('vm_name_prefix'));
my $extra_logging = int(trim_wspace(Opts::get_option('extra_logging')));

my @luns = split('\s*,\s*', $lunlist);

LogHandle::set_global_params($luns[0], $extra_logging);

my $log = LogHandle->new("vadp_setup");

#Connect to the ESX server.
esxi_connect($log);

sleep(30);
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

#Mount each of the above luns on the specified ESXi server.
my $lun_mount_err = 0;
my $prepare_vm_err = 0;
my $fail_msg = "";
foreach (@luns) {
    my $lun = $_;
    my $ds;
    eval {
        $ds = attach_and_mount_lun($lun, $dc_view, $include_hosts, $exclude_hosts);
    };
    if ($@) {
        $fail_msg = "Error while mounting the lun $_";
        $log->error("$fail_msg : $@");
        $lun_mount_err = 1;
    } else {
        eval {
            $log->info("Mounted successfully, preparing VMs for backup");
            prepare_vms_for_backup($ds, $dc_view, $include_hosts, $exclude_hosts,
                                   $include_vms, $exclude_vms, $vm_name_prefix);
        };
        if ($@) {
            $fail_msg = "Error while preparing VMs in the lun $_";
            $log->error("$fail_msg : $@");
            $prepare_vm_err = 1;
        }
    }
}

if ($lun_mount_err || $prepare_vm_err) {
    FAILURE($fail_msg);
}
SUCCESS();
