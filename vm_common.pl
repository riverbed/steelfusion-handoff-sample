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
use lib 'C:\Program Files (x86)\VMware\VMware vSphere CLI\Perl\apps';
use lib 'C:\Program Files (x86)\VMware\VMware vSphere CLI\Perl\lib\VMware';

use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path(__FILE__)).'/../perllib';

use Logger;
use LogHandle;

use VMware::VIRuntime;
use AppUtil::VMUtil;
use FileHandle;
use File::Basename;
use VMware::VILib;
use AppUtil::XMLInputUtil;
use VMware::VIRuntime;
use VMware::VIExt;
use XML::LibXML;

$Util::script_version = "1.0";
#BEGIN {
#       $ENV{PERL_NET_HTTPS_SSL_SOCKET_CLASS} = "Net::SSL";
#       $ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;
#}

#Select VMs from the specified luns 
#Input: List of lun serial, include filter, exclude filter
#Return: Returns a hash of datastore and VMs
sub locate_vms() {
    my ($luns, $include_filter, $exclude_filter, $datacenter) = @_;
    my $log = LogHandle->new("locate_vms");
    #Obtain the list of datastores corresponding to the lun
    my $lun_ds_hash = locate_datastores_for_luns($luns, $datacenter);

    my %ds_vm_hash = ();

    #For each datastore 
    for (keys %$lun_ds_hash) {
        my $ds = $lun_ds_hash->{$_};
        my $ds_name = $ds->name;
        $log->debug("Locating VMs on lun: $_ datastore: $ds_name");
        #Get Vms for each datastore.
        my $vms = get_vms_on_datastore($ds, $include_filter, $exclude_filter);
        $ds_vm_hash{$_} = {ds=>$ds, vms => $vms};
    }
    return \%ds_vm_hash;
}

#This obtains the datastore list for specified luns
sub locate_datastore_for_lun {
    my ($lun, $datacenter) = @_;
    my @luns = ($lun);
    my $lun_ds_hash = locate_datastores_for_luns(\@luns, $datacenter);
    return $lun_ds_hash->{$lun};
}

sub locate_unique_datastore_for_lun {
    my ($lun, $datacenter) = @_;
    my $log = LogHandle->new("unique_datastores");

    $log->diag("Trying to get data store for $lun");
    my $retry_count = 0;
    my $dup_data_store_exits = 0;
    my $dup_ds_name = '';
    while ($retry_count++ < 5) {
        my $datastores;
        
        # For error message when we exit
        $dup_data_store_exits = 0;
        $dup_ds_name = '';

        if (defined ($datacenter)) {
            $datastores = Vim::find_entity_views(view_type => 'Datastore', 
                                                    begin_entity => $datacenter);
        } else {
            $datastores = Vim::find_entity_views(view_type => 'Datastore');
        }
        
        my %ds_names_hash = ();
        my $dups_found = 0;
        my $data_store;
        foreach (@$datastores) {
            my $ds = $_;
            my $ds_name = $ds->name;
            my $lun_serial = datastore_lun_serial($ds);
            #Some datastores need not be on iscsi luns and such will be ignored.
            if (defined($lun_serial)) {
                $log->diag("Found datastore $ds_name with lun $lun_serial");
                #Check if the lun serial matches any the requested luns
                if ($lun_serial eq $lun) {
                    $log->info("Datastore $ds_name for $lun is the one that matches");
                    $data_store = $ds;
                }
            }
            $ds_names_hash{$ds_name}++;
        }

        # Check if we have duplicates
        if (!defined($data_store) ||
            (defined($ds_names_hash{$data_store->name}) && 
            $ds_names_hash{$data_store->name} > 1)) {
            if (defined($data_store)) {
                $dup_data_store_exits = 1;
                $dup_ds_name = $data_store->name;
                $log->info("Found datastore on more than one lun, ".
                           "rescanning and waiting for renaming the datastore");
	    } else {
                $log->info("Could not find the datastore for $lun, ".
                           "rescanning again...");
	    }
            sleep(20);
            next;
        }
        my $ds_found_name = $data_store->name;
        $log->info("Found datastore $ds_found_name successfully for $lun");
        return $data_store
    }
    if ($dup_data_store_exits == 1) {
        $log->error("Another datastore exits with the same name $dup_ds_name ".
                    "as that on the cloned lun $lun");
        die "Cannot perform data protection because of duplicate data store";
    }
    return;
}


sub locate_datastores_for_luns {
    my ($luns, $datacenter) = @_;
    my %lun_hash = ();
    my %lun_ds_hash = ();
    my $lun_cnt = scalar(@$luns);
    if ($lun_cnt == 0) {
        return \%lun_ds_hash;
    }
    my $log = LogHandle->new("datastores");
    #Build the dictionary out of the luns
    foreach (@$luns) {
        $lun_hash{$_} = 1;
    }
    my $datastores;
    if (defined ($datacenter)) {
        $datastores = Vim::find_entity_views(view_type => 'Datastore', 
                                             begin_entity => $datacenter);
    } else {
        $datastores = Vim::find_entity_views(view_type => 'Datastore');
    }
    foreach (@$datastores) {
        my $ds = $_;
        my $ds_name = $ds->name;
        my $lun_serial = datastore_lun_serial($ds);
        $log->debug("$ds_name ... $lun_serial");
        #Some datastores need not be on iscsi luns and such will be ignored.
        if (defined($lun_serial)) {
            #Check if the lun serial matches any the requested luns
            if ($lun_hash{$lun_serial}) {
                $log->diag("Datastore match for lun: $lun_serial, datastore: $ds_name");
                $lun_ds_hash{$lun_serial} = $ds;
                #If all luns are accounted for, then break
                my $out_cnt = keys(%lun_ds_hash);
                if ($out_cnt == $lun_cnt) {
                    $log->diag("Datastores located for all luns");
                    last;
                }
            }
        }
    }
    return \%lun_ds_hash;
}

sub datastore_lun_serial {
    my ($ds) = @_;
    my $ds_name = $ds->name;
    if (defined($ds->info) &&
        ref($ds->info) eq "VmfsDatastoreInfo" &&
        defined($ds->info->vmfs->extent)) {
        my $extents = $ds->info->vmfs->extent;
        my $extent_cnt = scalar(@$extents);
        if ($extent_cnt > 0) {
            #NOTE: We are just looking at the first extent, in other words we
            #don't support vmfs volumes spanning multiple luns.
            if ($extent_cnt > 1) {
                Logger::instance()->warn("/datastore_lun", 
                    "More than one lun ($extent_cnt) for datastore $ds_name");
            }
            return @$extents[0]->diskName;
        }
    }
}

#Returns vms on the specified datastore applying the inclusion and exclusion
#filter
#NOTE: exclusion takes precedence
sub get_vms_on_datastore {
    my ($datastore, $include_filter, $exclude_filter) = @_;
    #If filters are not passed use the generic
    if (! defined ($include_filter)) {
        $include_filter = ".*";
    }
    if (! defined ($exclude_filter)) {
        $exclude_filter = "";
    }
    my $vms_on_ds = $datastore->vm;
    my $vm_views;
    my $log = LogHandle->new("get_vms");
    foreach (@$vms_on_ds) {
        my $vm_view = Vim::get_view(mo_ref => $_);
        my $vm_name = $vm_view->name;
        if (! apply_filter($vm_name, $exclude_filter)) {
            if (apply_filter($vm_name, $include_filter)) {
                $log->diag("Including VM $vm_name");
                push (@$vm_views, $vm_view);
            } else {
                $log->diag("Skipping VM (include_filter): $vm_name");
            }
        } else {
            $log->diag("Skipping VM (exclude_filter): $vm_name");
        }
    }
    return $vm_views;
}

#Filter format: regex1, regex2, regex3, ....
sub apply_filter {
    my ($name, $filters) = @_;
    my @filter_arr = split('\s*,\s*', $filters);
    foreach (@filter_arr) {
        if ($name =~ m/$_/) {
            return 1;
        }
    }
    return 0;
}

sub take_vm_snapshot {
    my ($vm) = @_;
}

sub find_snapshots {
    my ($tree, $name) = @_;
    my @refs;
    my $count = 0;
    foreach my $node (@$tree) {
        if ($node->name eq $name) {
            push(@refs, $node);
            $count++;
        }
        my ($subRef, $subCount) = find_snapshots($node->childSnapshotList,
                                                 $name);
        $count = $count + $subCount;
        push(@refs, @$subRef) if ($subCount);
    }
    return (\@refs, $count);
}


sub ascii_to_dec_str {
    my $val = shift;
    my @arr = unpack("C*", $val);
    return join('', @arr);
}

sub hex_to_dec_str {
    my $val = shift;
    my @arr = pack("H*", $val);
    return ascii_to_dec_str(join('', @arr));
}

#Given the lun's serial number this routine determines the corresponding naa
#lun name
sub get_scsi_serial {
    my $scsi_device = shift;
    my $lun = $_;
    my $altNames = $lun->alternateName;
    #Alternate Name is not available if the device is not attached. 
    #In this obtain the serial by looking at naa id.
    if (defined($altNames)) {
        foreach (@$altNames) {
            my $alt = $_;
            my $namespace = $alt->namespace;
            if ($namespace eq "SERIALNUM") {
                my $data = $alt->data;
                my $data_str = join('', @$data);
                return $data_str;
            }
        }
    } else {
        #This is vendor specific and would have to be tested with all the storage
        #arrays we support. 
        #XXX Currently tested with Netapp
        my $naa_id = $lun->canonicalName;
        #Break up the naa to obtain the lun serial number
        my $naa_regex = "^naa\.........(.*)";
        if ($naa_id =~ m/$naa_regex/i) {
            my @parts = split(/\s*,\s*/, $1);
            my $serial = $parts[0];
            return hex_to_dec_str($serial);
        }
    }
    return "";
}

#Lookup datastore
sub lookup_datastore {
    my ($ds_name) = @_;
    my $datastores = lookup_datastores($ds_name);
    if (defined ($datastores)) {
        return @$datastores[0];
    }
    die "Unable to lookup the datastore $ds_name";
}

sub lookup_datastores {
    my ($ds_name) = @_;
    my $datastores = Vim::find_entity_views(view_type => 'Datastore', filter => {'name' => $ds_name});
    my $dscnt = scalar(@$datastores);
    my $log = LogHandle->new("lookup_datastores");
    if ($dscnt == 0) {
        $log->warn("WARN: Could not locate datastore $ds_name");
    }
    return $datastores;
}

#Lookup datacenter
sub lookup_datacenter {
    my ($dc_name) = @_;
    my $dc_views = Vim::find_entity_views(view_type => 'Datacenter', filter => {'name' => $dc_name});
    my $dccnt = scalar(@$dc_views);
    if ($dccnt == 0) {
        die "Unable to lookup the datacenter $dc_name";
    }
    return @$dc_views[0];
}

sub get_file {
    my ($ds_name, $remote_path, $local_path, $dc_name) = @_;
    my $log = LogHandle->new("get_file");
    $log->debug("Getting $remote_path to $local_path");
    my $resp = VIExt::http_get_file("folder", $remote_path, $ds_name, $dc_name, $local_path);
    check_http_response($resp, "Get", $log);
}

sub put_file {
    my ($ds_name, $local_path, $remote_path, $dc_name) = @_;
    my $log = LogHandle->new("put_file");
    my $dc_name_str = $dc_name;
    if (! defined ($dc_name)) {
        $dc_name_str = "";
    }
    $log->debug("Copying the file $local_path to $remote_path under ".
                "datastore: $ds_name datacenter: $dc_name_str");
    my $resp = VIExt::http_put_file("folder", $local_path, $remote_path, $ds_name, $dc_name);
    check_http_response($resp, "Put", $log);
}

sub check_http_response {
    my ($resp, $op, $log) = @_;
    if ($resp) {
        if (!$resp->is_success) {
            if($resp->code eq 404) {
                $log->error("$op operation unsuccessful: service not available");
            } else {
                $log->error("$op operation unsuccessful: response status code " .  $resp->code);
            }
        } else {
            $log->debug("$op operation completed successfully.");
            return;
        }
    } else {
      $log->error("$op operation unsuccessful: failed to get response");
    }
    die $op . " Failure";
}

sub unregister_vm {
    my $vm = shift;
    my $vm_name = $vm->name;
    $vm->UnregisterVM();
    my $log = LogHandle->new("unregister_vm");
    $log->diag("VM $vm_name successfully unregistered");
}

sub esxi_connect {
    my $log = shift;
    eval  {
        Util::connect();
    };
    if ($@) {
        $log->error("Connection error: $@");
        FAILURE("Unable to connect to ESXi/vCenter");
    }
}

sub SUCCESS {
    print "STATUS: SUCCESS\n";
    Util::disconnect();
    exit 0;
}

sub FAILURE {
    my $log = LogHandle->new("status");
    $log->error(@_);
    print "STATUS: FAILURE - @_\n";
    Util::disconnect();
    exit 1;
}

sub trim_wspace($)
{
    my $string = shift;
    $string =~ s/^\s+//;
    $string =~ s/\s+$//;
    return $string;
}
