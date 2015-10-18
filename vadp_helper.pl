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
require "vm_common.pl";
require "vm_fix.pl";

sub attach_and_mount_lun {
    my $log = LogHandle->new("attach_and_mount");
    my ($lun_serial, $datacenter, $include_hosts, $exclude_hosts) = @_;

    #Just pick the first host
    my $host = get_host($datacenter, $include_hosts, $exclude_hosts);
    $log->info("Starting setup operation on the host ". $host->name);
    my $storage = Vim::get_view(mo_ref => $host->configManager->storageSystem);
    my $datastore;

    my $scan_hbas = get_hbas_to_be_scanned($storage->storageDeviceInfo);
    
    my $MAX_RETRIES = 2;
    my $ds;
    my $count = 0;
    for ($count = 0; $count <= $MAX_RETRIES; $count++) {
        foreach (@$scan_hbas) {
            my $hba = $_;
            $log->debug("Scanning hba $hba");
            eval {
                $storage->RescanHba(hbaDevice => $hba);
            };
            if ($@) {
                $log->warn("Scan HBA failed for $hba: ". $@);
            }
            #XXX: More appropriate actions depending on the type of error
        }
        $storage = Vim::get_view(mo_ref => $host->configManager->storageSystem);
        #Walk through the scsi luns and the locate the lun that is of interest.
        my $scsi_device = serial_match_scsi_lun($storage, $lun_serial, $log);
        if (! defined($scsi_device)) {
            $log->info("Could not locate scsi device for $lun_serial");
            #Retry
            #Sleep before the next retry cycle
            sleep(2);
            next;
        }
        my $wwn_serial = $scsi_device->canonicalName;
        my $datastore = locate_datastore_for_lun($wwn_serial, $datacenter);

        if (defined($datastore) && $datastore->summary->accessible) {
            $log->info("Datastore for lun $wwn_serial is already mounted");
            return $datastore;
        }
        eval {
            $storage->AttachScsiLun(lunUuid => $scsi_device->uuid);
            $log->info("Successfully attached LUN " . $lun_serial);
        };
        if($@) {
            if (ref($@) eq 'SoapFault') {
                if(ref($@->detail) eq 'InvalidState') {
                    $log->diag("Device is already attached $lun_serial");
                } else {
                    $log->error("Error attaching lun $lun_serial - " . $@);
                    die $@;
               }
            } else {
                $log->error("Generic error attaching lun $lun_serial - " . $@);
                die $@;
            }
        }
        #Rescan for VMFS volumes
        eval {
            $storage->RescanVmfs();
        };
        if ($@) {
            $log->warn("Rescan VMFS volumes failed " . $@);
            #proceed forward.
        }
        #Inorder to mount the VMFS volume we need to determine the VMFS UUID 
        #Get a list of unresolved vmfs volumes and check if any of them matches the device.
        $datastore = mount_from_unresolved($host, $wwn_serial, $storage, $datacenter);
        if (defined ($datastore)) {
            return $datastore;
        }
        #If ESXi had not seen the lun before then it will not show up in 
        #unresolved volumes.  It will show up when it is looked up and it may
        #need to be mounted
        $log->debug("Trying to mount the volume by looking up datastore");
        eval {
            $storage->RescanVmfs();
        };
        if ($@) {
            $log->warn("Rescan vmfs volumes failed: " . $@);
            #proceed
        }
        $ds = locate_datastore_for_lun($wwn_serial, $datacenter);
        if (defined ($ds)) {
            my $vmfs_name = $ds->info->vmfs->name;
            eval {
                $log->info("Mounting VMFS volume: $vmfs_name");
                $storage->MountVmfsVolume(vmfsUuid => $ds->info->vmfs->uuid);
                $log->diag("VMFS volume successfully mounted: $vmfs_name");
            };
            if($@) {
                if (ref($@) eq 'SoapFault') {
                    if(ref($@->detail) eq 'InvalidState') {
                        $log->diag("Device is already mounted $vmfs_name");
                    } else {
                        $log->error("Unable to mount $vmfs_name: $@");
                        die $@;
                    }
                } else {
                    die $@;
                }
            }
        }
        #Sleep before the next retry cycle
        sleep(2);
    }
    if (! defined($ds)) {
        die "Unable to mount the datastore";
    }
}

sub mount_from_unresolved {
    my ($host, $wwn_serial, $storage_sys, $datacenter) = @_;

    my $log = LogHandle->new("mount_unresolved");
    my $dstore_sys = Vim::get_view(mo_ref => $host->configManager->datastoreSystem);
    $log->diag("Query for unresolved vmfs volumes.");
    my $uvs = $dstore_sys->QueryUnresolvedVmfsVolumes();
    foreach (@$uvs) {
        my $vmfs = $_;
        my $vmfs_label = $vmfs->vmfsLabel;
        my $extents = $vmfs->extent;
        #Match against all extents
        my $match_found = 0;
        my @device_paths;
        foreach (@$extents) {
            my $device = $_->device;
            my $disk_name = $device->diskName;
            if ($disk_name eq $wwn_serial) {
                @device_paths = ($_->devicePath);
                $log->diag("Match found: $vmfs_label");
                $match_found = 1;
            }
        }
        if ($match_found == 0) {
            next;
        }
        #We may need to take additional actions depending on the resolve
        #state.
        my $unres_msg = "Volume $vmfs_label unresolvable: ";
        if (! $vmfs->resolveStatus->resolvable) {
            if ($vmfs->resolveStatus->incompleteExtents) {
                $log->error($unres_msg . " extents are missing.");
            } elsif ($vmfs->resolveStatus->multipleCopies) {
                $log->warn($unres_msg . " duplicate extents found");
                #In this case detach all the extents but the one that we are
                #trying to mount.
            } elsif (scalar(@$extents) > 1) {
                $log->warn($unres_msg . " extra extents found");
            } else {
                $log->error($unres_msg . " Unknown error");
            }
            #Detach all devices other than the one that is being mounted
            if (scalar(@$extents) > 1) {
                $log->note("Proceeding to detach cloned luns except $wwn_serial");
                foreach (@$extents) {
                    my $disk_name = $_->device->diskName;
                    if ($disk_name ne $wwn_serial) {
                        eval {
                            lookup_and_detach_device($disk_name, $storage_sys);
                        };
                        if ($@) {
                            $log->note("Detaching device $disk_name failed");
                        }
                    }
                }
            }
        } else {
            $log->diag("Volume $vmfs_label is resolvable");
        }
        $log->diag("Force mounting unresolved: $vmfs_label");
        my $res_spec = new HostUnresolvedVmfsResolutionSpec();
        $res_spec->{"extentDevicePath"} = \@device_paths;
        $res_spec->{"uuidResolution"} = "forceMount";
        my $i = 0;
        for ($i = 0; $i < 2; ++$i) {
            eval {
                $storage_sys->ResolveMultipleUnresolvedVmfsVolumes(resolutionSpec => ($res_spec));
                $log->info("Successfully mounted VMFS $vmfs_label!");
            };
            if ($@) {
                $log->info("Resolve unresolved volumes failed: $vmfs_label: $@");
            } else {
                my $datastore = locate_datastore_for_lun($wwn_serial, $datacenter);
                if (defined ($datastore)) {
                    $log->info("Successfully located the datastore");
                    return $datastore;
                } else {
                    $log->note("Unable to lookup datastore after resolving volume");
                }
            }
        }
        last;
    }
}

sub serial_match_scsi_lun {
    my ($storage, $lun_serial, $log) = @_;
    my @lun_serials = ($lun_serial);
    my $serial_scsi_lun = serial_match_scsi_luns($storage, \@lun_serials,
                                                 $log);
    return $serial_scsi_lun->{$lun_serial};
}

sub serial_match_scsi_luns {
    my ($storage, $lun_serials, $log) = @_;
    #Here the lun serial could be in ASCII (netapp) or naa id decmial string
    #form(EMC). We try and match for several variants
    my $lun_serial_variants;
    foreach (@$lun_serials) {
        my $lun_serial = $_;
        $lun_serial_variants->{$lun_serial} = $lun_serial;
        $lun_serial_variants->{ascii_to_dec_str($lun_serial)} = $lun_serial;
        $lun_serial_variants->{"naa." . lc($lun_serial)} = $lun_serial;
    }
    for (keys %$lun_serial_variants) {
        $log->debug("Looking for serial num: $_");
    }
    my $scsi_luns = $storage->storageDeviceInfo->scsiLun;
    my %serial_scsi_hash = ();
    foreach (@$scsi_luns) {
        my $scsi_device = $_;
        my $serial = get_scsi_serial($scsi_device);
        my $wwn_serial = lc($scsi_device->canonicalName);
        $log->debug("LUNS: $serial...$wwn_serial");
        my $matching_key;
        if ($lun_serial_variants->{$serial}) {
            $matching_key = $serial;
            $log->diag("Match found $serial");
        } elsif ($lun_serial_variants->{$wwn_serial}) {
            $matching_key = $wwn_serial;
            $log->diag("Match found $wwn_serial");
        }
        if (defined($matching_key)) {
            my $incoming_serial = $lun_serial_variants->{$matching_key};
            # Save the match against the incoming scsi device
            $serial_scsi_hash{$incoming_serial} = $scsi_device;

            #Check if we can wrap
            if (keys(%serial_scsi_hash) == scalar(@$lun_serials)) {
                $log->diag("All luns lookedup");
                last;
            }
        }
    }
    return \%serial_scsi_hash;
}

sub prepare_vms_for_backup {
    my ($ds, $datacenter, $include_hosts, $exclude_hosts,
        $include_filter, $exclude_filter, $vm_name_prefix) = @_;
    my $log = LogHandle->new("prepare_vms");
    #Browse the VMs and collect vmx paths.
    my $vmx_paths = get_vmx_paths($ds);
    my @vms;
    foreach (@$vmx_paths) {
        my $vm;
        my $vm_name;
        $log->debug("Located VMX: $_" );
        my $skipped = 0;
        eval {
            $vm = register_vm($_, $datacenter, $include_hosts, $exclude_hosts);
        };
        if ($@) {
            $log->error("Error while registering VM: $_: $@");
            next;
        }
        if (! defined($vm)) {
            next;
        }
        $vm_name = $vm->name;
        #Check if the VM has to be skipped
        if (apply_filter($vm_name, $exclude_filter) || 
                !(apply_filter($vm_name, $include_filter))) {
            $log->diag("Skipping VM: $vm_name");
            $skipped = 1;
            #Unregister
            eval {
                unregister_vm($vm);
            };
            if ($@) {
                #Log error and continue;
                $log->error("Error while unregistering VM $vm_name: $@");
            }
            next;
        }
        eval {
            rename_vm_name($vm, $vm_name_prefix, $log);
        };
        if ($@) {
            $log->error("Error while renaming the snapshot for VM $vm_name: $@");
        }
        eval {
            fix_vm($ds, $vm, $datacenter, 0);
        };
        if ($@) {
            $log->error("Error while fixing the snapshot for VM $vm_name: $@");
        }
    }
}

sub get_vmx_paths {
    my ($ds) = shift;
    my $ds_browser = Vim::get_view(mo_ref => $ds->browser);
    my $log = LogHandle->new("get_vmx_paths");
            
    #For each of vmx paths collected register the VM.
    my $browse_task;
    eval {
        $browse_task = $ds_browser->SearchDatastoreSubFolders(datastorePath => '[' . $ds->summary->name . ']');
    };
    if ($@) {
        if (ref($@) eq 'SoapFault') {
            if (ref($@->detail) eq 'FileNotFound') {
                $log->error("The folder specified by "
                             . "datastorePath is not found");
            } elsif (ref($@->detail) eq 'InvalidDatastore') {
                $log->error("Operation cannot be performed on the target datastores");
            } else {
                $log->error("Error: $@");
            }
        } else {
            $log->error("Generic error: $@");
        }
        die $@;
    }
    my $vmx_files;
    foreach(@$browse_task) {
        if(defined $_->file) {
            foreach my $x (@{$_->file}) {
                my $ext = (fileparse($x->path, qr/\.[^.]*/))[2];
                if ($ext eq ".vmx") {
                    push (@$vmx_files, $_->folderPath . "/" . $x->path);
                }
            }
        }
    }
    return $vmx_files;
}

sub register_vm() {
    my ($vmxpath, $datacenter, $include_hosts, $exclude_hosts) = @_;
    if (! defined($datacenter)) {
        $datacenter = Vim::find_entity_view(view_type => 'Datacenter');
    }

    my $host = get_host($datacenter, $include_hosts, $exclude_hosts);
    # Find the resource pools which contain the host,
    # and select the first resource pool amongst it.
    my $resource_pools = Vim::find_entity_views(view_type => 'ResourcePool',
                                                begin_entity => $host->parent,
                                                filter => {'name' => "Resources"});
    my $resource_pool = $resource_pools->[0];

    my $folder_view = Vim::get_view(mo_ref => $datacenter->vmFolder);
    my $log = LogHandle->new("register_vm");
    my $vm;
    eval {
        my $task_ref = $folder_view->RegisterVM(path => $vmxpath, asTemplate => 0, pool => $resource_pool);
        $vm = Vim::get_view(mo_ref => $task_ref);
        $log->diag("Registered VM '$vmxpath' ");
    };
    if ($@) {
        if (ref($@) eq 'SoapFault') {
            if (ref($@->detail) eq 'AlreadyExists') {
                $log->note("VM $vmxpath already registered.");
                return;
            } elsif (ref($@->detail) eq 'OutOfBounds') {
                $log->error("Maximum Number of Virtual Machines has been exceeded");
            } elsif (ref($@->detail) eq 'InvalidArgument') {
                $log->error("A specified parameter was not correct.");
            } elsif (ref($@->detail) eq 'DatacenterMismatch') {
                $log->error("Datacenter Mismatch: The input arguments had entities "
                         . "that did not belong to the same datacenter.");
            } elsif (ref($@->detail) eq "InvalidDatastore") {
                $log->error("Invalid datastore path: $vmxpath");
            } elsif (ref($@->detail) eq 'NotSupported') {
                $log->error(0,"Operation is not supported");
            } elsif (ref($@->detail) eq 'InvalidState') {
                $log->error("The operation is not allowed in the current state"); 
            } else {
                $log->error("Error: $@");
            }
        } else {
            $log->error("Generic error: $@");
        }
        die $@;
    }
    return $vm;
}

sub check_if_vm_in_use {
    my $vm = shift;
    my $vm_name = $vm->name;
    my $nRefs = 0;
    my $log = LogHandle->new("check_vm_in_use");
    my $refs;
    $log->info("Checking if vm in use");
    if (defined $vm->snapshot) {
        ($refs, $nRefs) = find_snapshots($vm->snapshot->rootSnapshotList,
                                         "granite_snapshot");
    }
    if($nRefs == 0) {
        $log->info("no snapshot found if vm in use");
        return 0;
    }
    #Find if the granite snapshot has a child
    foreach (@$refs) {
        my $child_snapshots = $_->childSnapshotList;
        if (defined($child_snapshots) && scalar(@$child_snapshots) > 0) {
            $log->note("VM $vm_name has other non-granite snapshots");
            return 1;
        }
    }
    return 0;
}

sub unregister_vms {
    my ($ds, $fail_if_in_use) = @_;
    my $vm_views = get_vms_on_datastore($ds);
    my $ds_name = $ds->name;
    my $log = LogHandle->new("unregister_vms");
    my $other_ds_vms;
    foreach (@$vm_views) {
        my $vm = $_;
        my $vm_name = $vm->name;
        #Make a note of the VM it is hosted on some other datastore.
        my $vmx_file_path = $vm->config->files->vmPathName;
        my ($vmx_ds_name, $vmx_dirname, $vmx_filename) = split_file_path($vmx_file_path);
        if ($vmx_ds_name ne $ds_name) {
            $log->diag("VMX for $vm_name in $vmx_ds_name");
            push(@$other_ds_vms, $vmx_file_path);
        }
        #Dump changeids before cleaning up the VM
        dump_changeid_info($vm);

        #If requested, check if the VM is in use.
        if ($fail_if_in_use) {
            if (check_if_vm_in_use($vm)) {
                die "VM $vm_name is in use.";
            }
        }
        eval {
            unregister_vm($vm);
        };
        if ($@) {
            #Log error and continue;
            $log->error("Error while unregistering VM $vm_name : $@");
        }
    }
    return $other_ds_vms;
}

sub dump_changeid_info {
    my $vm = shift;
    my $log = LogHandle->new("changeid_info");
    my $snapshot_chain = $vm->snapshot;
    my $snapshot;
    if (defined($snapshot_chain) && defined($snapshot_chain->currentSnapshot)) {
        $snapshot = Vim::get_view(mo_ref => $snapshot_chain->currentSnapshot);
    } else {
        $log->info("No snapshots");
        return;
    }
    if (! defined($snapshot)) {
        $log->warn("Could not lookup current snapshot");
        return;
    }
    my $devices = $snapshot->config->hardware->device;
    $log->info("VM: ". $vm->name);
    foreach (@$devices) {
        my $device = $_;
        my $device_id = $device->key;
        if (ref($device) eq "VirtualDisk") {
            $log->info("Disk: " . $device_id . ", ChangeId: ".
                       $device->backing->changeId);
        }
    }
}

sub lookup_and_detach_device {
    my ($lun_serial, $storage_sys) = @_;
    $lun_serial = lc($lun_serial);
    if (index($lun_serial, "naa.") == -1) {
        $lun_serial = "naa." . $lun_serial;
    }
    my $log = LogHandle->new("detach");
    $log->diag("Looking to detach $lun_serial");
    my $devices = eval{$storage_sys->storageDeviceInfo->scsiLun || []};
    if (scalar(@$devices) == 0) {
        $log->warn("No devices found");
    }
    foreach my $device (@$devices) {
        if($device->canonicalName eq $lun_serial) {
            detach_device($storage_sys, $device, $log);
            last;
        }
    }
}

sub detach_device {
    my ($storage_sys, $device, $log) = @_;
    my $lunUuid = $device->uuid;
    my $lun_serial = $device->canonicalName;
    $log->diag("Detaching LUN \"$lun_serial\"");
    eval {
        $storage_sys->DetachScsiLun(lunUuid => $lunUuid);
    };
    if($@) {
        my $detach_err = 1;
        if (ref($@) eq 'SoapFault') {
            if(ref($@->detail) eq 'InvalidState') {
                $log->note("Device is already detached $lun_serial");
                $detach_err = 0;
            }
        } 
        if ($detach_err) {
            $log->error("Unable to detach LUN $@");
            die $@;
        }
    } else {
        $log->info("Successfully detached LUN $lun_serial");
    }
    #Now remove the device from ESXi
    eval {
        $storage_sys->DeleteScsiLunState(lunCanonicalName => $lun_serial);
    };
    if($@) {
        $log->error("Unable to delete lunstate " . $@);
    } else {
        $log->diag("Successfully deleted lunstate for $lun_serial");
    }
}

sub umount_and_detach {
    my $ds = shift;
    my $ds_name = $ds->name;
    my $disk_name = $ds->info->vmfs->extent->[0]->diskName;
    my $log = LogHandle->new("umount_and_detach");
    if(! $ds->host) {
        $log->error("Host entry not present");
        return;
    }
    my $attached_hosts = $ds->host;
    my $num_hosts = scalar(@$attached_hosts);
    if ($num_hosts == 0) {
        $log->note("No hosts are attached to the datastore: $ds_name");
        return;
    } elsif($num_hosts > 1) {
        $log->error("More than one hosts are attached to the datastore
                     $ds_name: $num_hosts");
        die;
    }
    my $host = $attached_hosts->[0];
    my $hostView = Vim::get_view(mo_ref => $host->key, properties => ['name','configManager.storageSystem']);
    my $storageSys = Vim::get_view(mo_ref => $hostView->{'configManager.storageSystem'});
    $log->debug("Unmounting VMFS Datastore $ds_name from Host ".  $hostView->{'name'});
    eval {
        $storageSys->UnmountVmfsVolume(vmfsUuid => $ds->info->vmfs->uuid);
    };
    if($@) {
        if (ref($@) eq 'SoapFault') {
            if(ref($@->detail) eq 'InvalidState') {
                $log->note("Device is already unmounted");
                last;
            }
        } else {
            $log->error("Unable to unmount VMFS datastore $ds_name: " . $@);
            die $@;
        }
    } else {
        $log->info("Successfully unmounted VMFS datastore $ds_name");
    }
    lookup_and_detach_device($disk_name, $storageSys);

    #Scan the hbas to clear the vmfs volume from vcenter/esxi's view
    my $scan_hbas = get_hbas_to_be_scanned($storageSys->storageDeviceInfo);
    foreach (@$scan_hbas) {
        my $hba = $_;
        $log->debug("Scanning hba $hba");
        eval {
            $storageSys->RescanHba(hbaDevice => $hba);
        };
        if ($@) {
            $log->warn("Scan HBA failed for $hba: ". $@);
        }
    }
}

sub get_wwn_name {
    my ($lun_serial, $datacenter) = shift;
    my @luns = ($lun_serial);
    my $lun_wwn = get_wwn_names(\@luns, $datacenter);
    return $lun_wwn->{$lun_serial};
}

sub get_wwn_names {
    my ($luns, $datacenter, $include_hosts, $exclude_hosts) = @_;
    my $log = LogHandle->new("get_wwn_names");
    my %serial_wwn_hash = ();
    my $lun_cnt = scalar(@$luns);
    if ($lun_cnt == 0) {
        return \%serial_wwn_hash;
    }
    my $host_list = get_host_list($datacenter, $include_hosts, $exclude_hosts);
    if (scalar(@$host_list) == 0) {
        $log->warn("Unable to locate ESXi Hosts");
        die "Unable to locate ESXi hosts";
    }
    #Build the list walking through all the hosts under the datacenter
    foreach (@$host_list) {
        my $host = $_;
        my $storage = Vim::get_view(mo_ref => $host->configManager->storageSystem);
        my $dstore_sys = Vim::get_view(mo_ref => $host->configManager->datastoreSystem);
        
        my $serial_scsi_hash = serial_match_scsi_luns($storage, $luns, $log);
        foreach (keys(%$serial_scsi_hash)) {
            my $scsi_device = $serial_scsi_hash->{$_};
            $log->debug("MATCH: $_ -> ". $scsi_device->canonicalName);
            $serial_wwn_hash{$_} = $scsi_device->canonicalName;
        }
    }
    return \%serial_wwn_hash;
}

sub get_hbas_to_be_scanned {
    my $storage_device = shift;
    my $all_hbas = $storage_device->hostBusAdapter;
    my $selected_hbas;
    my $log = LogHandle->new("select_hbas");
    foreach (@$all_hbas) {
        my $hba = $_;
        my $hba_type = ref($hba);
        if ($hba_type eq "HostInternetScsiHba" || $hba_type eq "HostFibreChannelHba") {
            my $hba_name = $hba->device;
            $log->diag("Selecting $hba_name of type $hba_type");
            push(@$selected_hbas, $hba_name);
        }
    }
    return $selected_hbas;
}

sub get_host_list {
    my ($datacenter, $include_filter, $exclude_filter) = @_;
    my $host_list;
    my $log = LogHandle->new("get_host_list");
    if (defined($datacenter)) {
        $host_list = Vim::find_entity_views(view_type => 'HostSystem',
                                            begin_entity => $datacenter);
    } else {
        $host_list = Vim::find_entity_views(view_type => 'HostSystem');
    }
    if (! defined ($include_filter)) {
        $include_filter = ".*";
    }
    if (! defined ($exclude_filter)) {
        $exclude_filter = "";
    }
    #Now apply the filter
    my @filtered_hosts;
    foreach (@$host_list) {
        my $host = $_;
        my $host_name = $host->name;
        if (! apply_filter($host_name, $exclude_filter)) {
            if (apply_filter($host_name, $include_filter)) {
                push (@filtered_hosts, $host);
            } else {
                $log->diag("Skipping host (include_filter): $host_name");
            }
        } else {
            $log->diag("Skipping host (exclude_filter): $host_name");
        }
    }
    return \@filtered_hosts;
}

sub get_host {
    my ($datacenter, $include_hosts, $exclude_hosts) = @_;
    my $log = LogHandle->new("get_host");
    my $host_list = get_host_list($datacenter, $include_hosts, $exclude_hosts);
    if (scalar(@$host_list) == 0) {
        $log->warn("Unable to locate ESXi Hosts");
        die "Unable to locate ESXi hosts";
    }
    #Just pick the first host
    return $host_list->[0];
}

sub rename_vm_name {
    my ($vm, $vm_name_prefix, $log) = @_;
    if ($vm_name_prefix eq "") {
        return;
    }
    my $vm_name = $vm->name;
    my $new_name = $vm_name_prefix . $vm_name;
    my $config_spec = VirtualMachineConfigSpec->
                              new(name => $new_name );

    eval {
        $vm->ReconfigVM(spec => $config_spec);
    };
    if ($@) {
        $log->error("Error while renaming display name name for $vm_name: $@");
        die $@;
    }
}
