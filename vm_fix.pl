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
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path(__FILE__)).'/';
use POSIX;

require "vm_common.pl";
use File::Temp qw/ tempfile tempdir /;

sub fix_vm {
    my ($ds, $vm, $datacenter, $no_overwrite) = @_;
    my $vm_name = $vm->name;
    my $dc_name;
    if (defined($datacenter)) {
        $dc_name = $datacenter->name;
    }
    my $log = LogHandle->new("fix_vm");


    my $ds_name = $ds->name;
    my $disk_ids = get_current_disks($ds, $vm);
    for (keys %$disk_ids) {
        $log->debug("disk_ids: $_ : " . $disk_ids->{$_});
    }
    my $disk_snaps = get_latest_disk_snaps($ds, $vm);
    if (! defined($disk_snaps)) {
        $log->debug("No snapshots for VM: $vm_name, nothing more to be done");
        return;
    }
    for (keys %$disk_snaps) {
        $log->debug("disk_snaps: $_ : " . $disk_snaps->{$_});
    }

    #Fetch the vmx file from the esxi
    my ($vm_dir, $vmx_filename) = get_vmx_file_info($vm);
    my $remote_vmx_path = "$vm_dir/$vmx_filename";
    my $tmpfile_dir = "/var/tmp";
    my $tmpfile_template = "$vmx_filename". "XXXXX";
    my ($discard, $vmx_file) = tempfile($tmpfile_template,
                                        DIR => $tmpfile_dir,
                                        SUFFIX => '.vmx' );
    my $fixed_vmx_file = $vmx_file . ".fixed";

    #Obtain the vmx file from the esxi
    eval {
        get_file($ds->name, $remote_vmx_path, $vmx_file, $dc_name);
    };
    if ($@) {
        $log->error("Unable to obtain the vmx file $vmx_file: $@");
        die $@;
    }
    $log->diag("Obtained the vmx file $remote_vmx_path at $vmx_file");
    # Start parsing the vmx file and substitute the disks
    open (in_fh, "<$vmx_file") or die "cannot open $vmx_file";
    open (out_fh, "+>$fixed_vmx_file") or die "cannot open $fixed_vmx_file";

    print out_fh "#Updated by Riverbed Granite at: ". strftime "%F %T", localtime $^T;
    print out_fh "\n";
    while (<in_fh>) {
        chomp;
        my $line = $_;
        #XXX REGEX
        my $scsi_idx = index($line, "scsi0:");
        if ($scsi_idx != -1) {
            my $locate_str = "\.fileName = \"";
            my $fpath_idx = index($line, $locate_str);
            if ($fpath_idx != -1) {
                #XXX Fix to use REGEX
                $fpath_idx += length($locate_str);
                my $file_path = substr($line, $fpath_idx, length($line) - ($fpath_idx + 1));
                my $dir_path = "";
                my $fname = $file_path;
                my $fname_idx = rindex($file_path, "/");
                if ($fname_idx != -1) {
                    $fname = substr($file_path, $fname_idx + 1);
                    $dir_path = substr($file_path, 0, $fname_idx) . "/";
                }
                my $fixed_fname = $dir_path . $fname;
                # Check if the disk is present in the disk id list, 
                if ($disk_ids->{$fname}) {
                    my $disk_id = $disk_ids->{$fname};
                    # Determine the new name
                    if ($disk_snaps->{$disk_id}) {
                        $fixed_fname = $dir_path . $disk_snaps->{$disk_id};
                        #Update the line to include the snapshot disk name
                        my $updated_line = substr($line, 0, $fpath_idx) .
                                                    $fixed_fname . "\"";
                        $log->diag("Updating disk name:$line -> $updated_line");
                        $line = $updated_line;
                    }
                } else {
                    $log->debug("Disk $fname is not present in the list");
                }
            }
        }
        print out_fh "$line\n";
    }
    close(out_fh);
    $log->debug("Fixed vmx file at $fixed_vmx_file");
    #Now upload the file to ESXi. Do not overwrite the vmx file if explicitly
    #requested
    my $dest_file = $remote_vmx_path;
    if (defined($no_overwrite) && $no_overwrite == 1) {
        $dest_file = $remote_vmx_path . ".fixed";
    }
    $log->diag("Pushing the file $dest_file");
    #Send both the original and the fixed vmx files
    eval {
        put_file($ds->name, $vmx_file, $remote_vmx_path . ".orig", $dc_name);
        put_file($ds->name, $fixed_vmx_file, $dest_file, $dc_name);
    };
    if ($@) {
        $log->error("Unable to upload modified vmx file: $@");
        die $@;
    }
    #remove temp files
    unlink($fixed_vmx_file);
    unlink($vmx_file);
}

sub get_current_disks {
    my ($ds, $vm) = @_;
    my $files = $vm->layoutEx->file;
    my $log = LogHandle->new("current_disks");
    my %disk_id_hash = ();
    foreach (@{$vm->layoutEx->disk}) {
        my $disk = $_;
        my $id = $disk->key;
        # Determine the latest name of the disk 
        my $chain = $disk->chain;
        my $top_vmdk = $chain->[-1];
        my $filekeys = $top_vmdk->fileKey;
        my $vmdk_desc_id = $filekeys->[0];
        $log->debug("VMDK descriptor_id: $vmdk_desc_id");
        my $filepath = $files->[$vmdk_desc_id]->name;
        $log->debug("VMDK descriptor for $id: $filepath");
        my ($ds_name, $dirname, $filename) = split_file_path($filepath);
        $log->debug("DS: $ds_name, Directory: $dirname, Filename: $filename");
        $disk_id_hash{$filename} = $id;
    }
    return \%disk_id_hash;
}

#Returns a hash map of disk id to disk descriptor name of the latest snapshot
#that was taken.
sub get_latest_disk_snaps {
    my ($ds, $vm) = @_;
    my $files = $vm->layoutEx->file;
    my $log = LogHandle->new("latest_snap");
    my %disk_snapshot_hash = ();
    my $snapshots = $vm->layoutEx->snapshot;
    my $num_snapshots = 0;
    if (defined($snapshots)) {
        $num_snapshots = scalar(@$snapshots);
    }
    if ($num_snapshots == 0) {
        $log->info("No snapshots present for ". $vm->name);
        return;
    }
    my $latest_snapshot = $snapshots->[-1];
    foreach (@{$latest_snapshot->disk} ) {
        my $disk = $_;
        my $id = $disk->key;
        # Determine the latest name of the disk 
        my $chain = $disk->chain;
        my $top_vmdk = $chain->[-1];
        my $filekeys = $top_vmdk->fileKey;
        my $vmdk_desc_id = $filekeys->[0];
        $log->diag("VMDK descriptor_id: $vmdk_desc_id");
        my $filepath = $files->[$vmdk_desc_id]->name;
        $log->diag("VMDK descriptor for $id: $filepath");
        my ($ds_name, $dirname, $filename) = split_file_path($filepath);
        $log->diag("DS: $ds_name, Directory: $dirname, Filename: $filename");
        $disk_snapshot_hash{$id} = $filename;
    }
    return \%disk_snapshot_hash;
}

# The file names within the vmx have datastore name as follows: 
# [<ds_name>] <vm_dir>/<filepath>
# This function splits this and returns each of them
sub split_file_path {
    my ($filepath) = @_;
    #XXX use regex
    # my $fname_regex = ".* .*/.*";
    my $ds_idx = index($filepath, "] ");
    my $ds_name = substr($filepath, 1, $ds_idx - 1);

    my $fname_idx = rindex($filepath, "/");
    my $fname = substr($filepath, $fname_idx + 1);

    my $dirname = substr($filepath, $ds_idx + 2, $fname_idx - ($ds_idx + 2));
    return ($ds_name, $dirname, $fname);
}

#Return the vmx file path
sub get_vmx_file_info {
    my $vm = shift;
    my $files = $vm->layoutEx->file;
    foreach (@$files) {
        my $name = $_->name;
        if (index($name, ".vmx") != -1) {
            my ($ds_name, $dir, $fname) = split_file_path($name);
            return ($dir, $fname);
        }
    }
    die "Unable to locate the vmx file";
}
