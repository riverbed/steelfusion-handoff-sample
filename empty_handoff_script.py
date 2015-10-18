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


###############################################################################
# Sample Snapshot Handoff Script
# All operations are a no-op.
# Since we do not really create a clone, the mount operation
# and the unmount operation are going to fail on ESX.
###############################################################################
import optparse
import sys
import errno
import subprocess

# These are used for generating random clone serial
import string
import random

# Script DB is used to store/load the cloned lun
# information and the credentials
import script_db

# For setting up PATH
import os

# Paths for VADP scripts
PERL_EXE = r'"C:\Program Files (x86)\VMware\VMware vSphere CLI\Perl\bin\perl.exe" '
WORK_DIR =  r'C:\rvbd_handoff_scripts'
VADP_CLEANUP = WORK_DIR + r'\vadp_cleanup.pl'
VADP_SETUP = WORK_DIR + r'\vadp_setup.pl'


def script_log(msg):
    '''
    Local logs are sent to std err
	
	msg : the log message
    '''
    sys.stderr.write(msg)


def set_script_path(prefix):
    '''
	Sets the paths accroding to the prefix.
	
	prefix : full path of directory in which the VADP scripts reside
    '''
    global WORK_DIR, VADP_CLEANUP, VADP_SETUP
    WORK_DIR = prefix
    VADP_CLEANUP = WORK_DIR + r'\vadp_cleanup.pl'
    VADP_SETUP = WORK_DIR + r'\vadp_setup.pl'

	
def check_lun(server, serial):
    '''
    Checks for the presence of lun on given netapp array

    server : Netapp hostname/ip address connection
    serial : lun serial

    Exits the process with code zero if it finds the lun,
    or non-zero code otherwise
    '''
    print ("OK")
    sys.exit(0)


def create_snap(cdb, sdb, server, serial, snap_name, 
                access_group, proxy_host, category, protect_category):
    '''
    Creates a snapshot

    cdb : credentials db
    sdb : script db
    server : Netapp hostname/ip address connection
    serial : lun serial
    snap_name : the snapshot name
    access_group : the initiator group to which cloned lun is mapped
    proxy_host : the host on which clone lun is mounted
    category : snapshot category
    protect_category : the snapshot category for which proxy backup is run

    Prints the snapshot name on the output if successful
    and exits the process.
    If unsuccessful, exits the process with non-zero error code.

    If the snapshot category matches the protected category, we run
    data protection for this snapshot.
    '''

    print (snap_name)
   
    # Run proxy backup on this snapshot if its category matches
    # protected snapshot category
    if category == protect_category:
        # Un-mount the previously mounted cloned lun from proxy host
        unmount_proxy_backup(cdb, sdb, serial, proxy_host)
        # Delete the cloned snapshot
        delete_cloned_lun(cdb, sdb, server, serial)
        # Create a cloned snapshot lun form the snapshot
        cloned_lun_serial = create_snap_clone(cdb, sdb, server, serial, snap_name, access_group)
        # Mount the snapshot on the proxy host
        mount_proxy_backup(cdb, sdb, cloned_lun_serial, snap_name, access_group, proxy_host)        


def remove_snap(cdb, sdb, server, serial, snap_name, proxy_host):
    '''
    Removes a snapshot

    cdb : credentials db
    sdb : script db
    server : Netapp hostname/ip address
    serial : lun serial
    snap_name : the snapshot name
    proxy_host : proxy host

    If unsuccessful, exits the process with non-zero error code,
    else exits with zero error code.

    If we are removing a protected snapshot, we un-mount and cleanup
    the cloned snapshot lun and then remove the snapshot.
    '''

    clone_serial, protected_snap, group = sdb.get_clone_info(serial)
 
	# Check if we are removing a protected snapshot
    if protected_snap == snap_name:
        # Deleting a protected snap. Un-mount the clone from the proxy host
        unmount_proxy_backup(cdb, sdb, serial, proxy_host)
        # Delete the snapshot cloned lun
        delete_cloned_lun(cdb, sdb, server, serial)
 
    # Remove the snapshot from the storage array
    sys.exit(0)


def create_snap_clone(cdb, sdb, server, serial, snap_name, access_group):
    '''
    Creates a lun out of a snapshot
   
    cbd : credentials db
    sdb : script db
    server : the storage array
    serial : the original lun serial
    snap_name : the name of the snapshot from which lun must be created
    access_group : initiator group for Netapp, Storage Group for EMC

    Since this step is run as part of proxy backup, on errors,
    we exit with status zero so that Granite Core ACKs the Edge.
    '''
    cloned_lun_serial = ''.join(random.choice(string.ascii_uppercase +\
                                             string.digits)\
                                             for x in range(10))
    script_log("Cloned serial is " + cloned_lun_serial)
    # Store this information in a local database. 
    # This is needed because when you are running cleanup,
    # the script must find out which cloned lun needs to me un-mapped.
    sdb.insert_clone_info(serial, cloned_lun_serial, snap_name, access_group)
    return cloned_lun_serial        

 
def delete_cloned_lun(cdb, sdb, server, lun_serial):
    '''
    For the given serial, finds the last cloned lun
    and delete it.

    Note that it does not delete the snapshot, the snapshot is left behind.

    cdb : credentials db
	sdb : script db
    lun_serial : the lun serial for which we find the last cloned lun
    '''
    clone_serial, snap_name, group = sdb.get_clone_info(lun_serial)
    script_log("Deleting cloned lun with serial " + clone_serial)
    sdb.delete_clone_info(lun_serial)

    if not clone_serial:
         script_log("No clone serial found, returning")
         return

    script_log("Cloned lun %s deleted successfully" % clone_serial)


def mount_proxy_backup(cdb, sdb, cloned_lun_serial, snap_name,
                       access_group, proxy_host):
    '''
    Mounts the proxy backup on the proxy host

    cdb : credentials db
    sdb : script db
    cloned_lun_serial : the lun serial of the cloned snapshot lun
    snap_name : snapshot name
    access_group : initiator group   
    proxy_host : the ESX proxy host

    '''
    # Get credentials for the proxy host
    username, password = cdb.get_enc_info(proxy_host)

    # Create the command to be run
    cmd = ('%s "%s" --server %s --username %s --password %s --luns %s' %\
           (PERL_EXE, VADP_SETUP, proxy_host, 
           username, password, cloned_lun_serial))
    
    script_log("Command is: " + cmd)
    proc = subprocess.Popen(cmd,
                            stdin = subprocess.PIPE,
                            stdout = subprocess.PIPE,
                            stderr = subprocess.PIPE)

    out, err = proc.communicate()
    if proc.wait() != 0:
        script_log("Failed to mount the cloned lun: " + str(err))
    else:
        script_log("Mounted the cloned lun successfully")

		
def unmount_proxy_backup(cdb, sdb, lun_serial, proxy_host):
    '''
    Un-mounts the previously mounted clone lun from the proxy host

    cdb : credentials db
    sbd : script db
    lun_serial : the lun serial   
    proxy_host : the ESX proxy host

    '''
    # Get the credentials for proxy host
    username, password = cdb.get_enc_info(proxy_host)

    # Find the cloned lun from the script db for given lun
    clone_serial, snap_name, group = sdb.get_clone_info(lun_serial)

    if not clone_serial:
         script_log("No clone serial found, returning")
         return	
	
    cmd = ('%s "%s" --server %s --username %s --password %s --luns %s' \
           % (PERL_EXE, VADP_CLEANUP,
           proxy_host, username, password, clone_serial))

    script_log("Command is: " + cmd)
    proc = subprocess.Popen(cmd,
                            stdin = subprocess.PIPE,
                            stdout = subprocess.PIPE,
                            stderr = subprocess.PIPE)

    out, err = proc.communicate()
    if proc.wait() != 0:
        script_log("Failed to un-mount the cloned lun: " + str(err))
    else:
        script_log("Un-mounted the clone lun successfully")


def get_option_parser():
    '''
    Returns argument parser
    '''
    global WORK_DIR
    parser = optparse.OptionParser()

    # These are script specific parameters that can be passed as
    # script arguments from the Granite Core.
    parser.add_option("--storage-array",
                      type="string",
                      default="chief-netapp1",
                      help="storage array ip address or dns name")
    parser.add_option("--username",
                      type="string",
                      default="root",
                      help="log username")
    parser.add_option("--password",
                      type="string",
                      default="",
                      help="login password")
    parser.add_option("--access-group",
                      type="string",
                      default="",
                      help="Access group to protect")
    parser.add_option("--proxy-host",
                      type="string",
                      default="",
                      help="Proxy Host Server")
    parser.add_option("--work-dir",
                      type="string",
                      default=WORK_DIR,
                      help="Directory path to the VADP scripts")
    parser.add_option("--protect-category",
                      type="string",
                      default="daily",
                      help="Directory path to the VADP scripts")

    # These arguments are always passed by Granite Core
    parser.add_option("--serial",
                      type="string",
                      help="serial of the lun")
    parser.add_option("--operation",
                      type="string",
                      help="Operation to perform (HELLO/SNAP/REMOVE)")
    parser.add_option("--snap-name",
                      type="string",
                      default="",
                      help="snapshot name")
    parser.add_option("--issue-time",
                      type="string",
                      default="",
                      help="Snapshot issue time")
    parser.add_option("--category",
                      type="string",
                      default="manual",
                      help="Snapshot Category")
    return parser


if __name__ == '__main__':
    options, argsleft = get_option_parser().parse_args()

    # Set the working dir prefix
    set_script_path(options.work_dir)

    # Credentials db must be initialized using the cred_mgmt.py file
    cdb = script_db.CredDB(options.work_dir + r'\cred_db')
	
    # Initialize the script database
    sdb = script_db.ScriptDB(options.work_dir + r'\script_db')
    sdb.setup()

    # Connect to server
    conn = options.storage_array

    if options.operation == 'HELLO':
        check_lun(conn, options.serial)
    elif options.operation == 'CREATE_SNAP':   
        create_snap(cdb, sdb, conn, options.serial, options.snap_name, 
                    options.access_group, options.proxy_host,
					options.category, options.protect_category)
    elif options.operation == 'REMOVE_SNAP':
        remove_snap(cdb, sdb, conn, options.serial,
		            options.snap_name, options.proxy_host)
    else:
        print ('Invalid operation: %s' % str(options.operation))
        cdb.close()
        sdb.close()
        sys.exit(errno.EINVAL)

    sdb.close()
    cdb.close()
