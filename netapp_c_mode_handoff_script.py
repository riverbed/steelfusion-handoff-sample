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
# Sample Snapshot Handoff Script for Netapp with C mode.
# This assumes the backend is Netapp
# Need the Netapp manageability sdk for this script
###############################################################################
import optparse
import sys
import errno
import subprocess

# Script DB is used to store/load the cloned lun
# information and the credentials
import script_db

# For setting up PATH
import os

# Netapp sdk path. This is the path to which you installed the 
# Netapp managebility SDK.
sys.path.append(r"C:\netapp\netapp-manageability-sdk-5.0\lib\python\NetApp")
from NaServer import *

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

	
def get_volume_path(server, serial):
    '''
    Gets the volume for the given lun

    server : Netapp hostname/ip address
    serial : lun short serial

    returns the lun serial
    '''
    api = NaElement("lun-get-iter")
    q = NaElement("query")
    api.child_add(q)
    luninfo = NaElement("lun-info")
    q.child_add(luninfo)
    luninfo.child_add_string("serial-number", serial)

    xo = server.invoke_elem(api)
    if (xo.results_status() == "failed") :
        print ("Error:\n")
        print (xo.sprintf())
        return ""

    luns = xo.child_get("attributes-list")
    if luns:
        lun = luns.child_get("lun-info")
        return lun and lun.child_get_string("path") or ''

    return ''


def get_lun_serial(server, lun_path):
    '''
    Gets the lun serial for the given lun_path

    server : Netapp hostname/ip address
    lun_path : full lun path

    returns the lun serial
    '''
    api = NaElement("lun-get-iter")
    q = NaElement("query")
    api.child_add(q)
    luninfo = NaElement("lun-info")
    q.child_add(luninfo)
    luninfo.child_add_string("path", lun_path)

    xo = server.invoke_elem(api)
    if (xo.results_status() == "failed") :
        print ("Error:\n")
        print (xo.sprintf())
        return ""

    luns = xo.child_get("attributes-list")
    if luns:
        lun = luns.child_get("lun-info")
        return lun and lun.child_get_string("serial-number") or ''

    return ''


def check_lun(server, serial):
    '''
    Checks for the presence of lun on given netapp array

    server : Netapp hostname/ip address connection
    serial : lun serial

    Exits the process with code zero if it finds the lun,
    or non-zero code otherwise
    '''
    lun_path = get_volume_path(server, serial)
    if len(lun_path) == 0:
        print ("Lun %s not found" % (serial))
        sys.exit(1)

    print ("OK")
    sys.exit(0)


def snap_operation(server, op, serial, snap_name):
    '''
    Performs a snapshot operation

    server : Netapp hostname/ip address
    op : snapshot-create/snapshot-delete
    serial : lun serial
    snap_name : the snapshot name

    Exits the process with non-zero error if it fails
    to create a snap
    '''

    # Convert lun serial to lun path
    lun_path = get_volume_path(server, serial)
    if len(lun_path) == 0:
        print ("Lun %s not found" % (serial))
        sys.exit(1)

    # lun path is of the form
    #      /vol/some_vol/lun_name
    # which will split to [ '', 'vol', 'some_vol', 'lun_name' ]
    path_parts = lun_path.split('/')
    if len(path_parts) < 3:
        print ("Could not find volume for path %s" % lun_path)
        sys.exit(1)

    if len(snap_name) == 0:
        print ("Empty snapshot name")
        sys.exit(1)

    # For Netapp, we take snapshot for the entire volume
    # on which the lun resides
    volume = path_parts[2]
    api = NaElement(op)
    api.child_add_string("snapshot", snap_name)
    api.child_add_string("volume", volume)
    xo1 = server.invoke_elem(api)

    if (xo1.results_status() == "failed" and\
        xo1.results_reason().find("copy name already exists") == -1) :
        print ("Error:\n")
        print (xo1.sprintf())
        sys.exit (1)


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

    # Take the snapshot
    snap_operation(server, "snapshot-create", serial, snap_name)
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
    snap_operation(server, "snapshot-delete", serial, snap_name)
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

    # get the lun path from the lun serial 
    lun_path = get_volume_path(server, serial)
    if len(lun_path) == 0:
        script_log("Lun %s not found" % (serial))
        sys.exit(0)

    # lun path is of the form
    #      /vol/some_vol/lun_name
    # which will split to [ '', 'vol', 'some_vol', 'lun_name' ]
    path_parts = lun_path.split('/')
    if len(path_parts) < 3:
        script_log("Could not find volume for path %s" % lun_path)
        sys.exit(0)

    if len(snap_name) == 0:
        script_log("Empty snapshot name")
        sys.exit(0)


    volume = path_parts[2]
    # Clone volume name is the name we want to give to the newly cloned volume
    clone_volume_name = (volume + "_" + snap_name).replace('-', '_')
    api = NaElement("volume-clone-create")
    api.child_add_string("parent-snapshot", snap_name)
    api.child_add_string("parent-volume", volume)
    api.child_add_string("space-reserve","none")
    api.child_add_string("volume", clone_volume_name)
    xo = server.invoke_elem(api)
    if (xo.results_status() == "failed") :
        script_log("Error:\n")
        script_log(xo.sprintf())
        sys.exit (0)

    # Clone created successfully. Now expose this lun
    # to the access_group. access_group is the initiator group
    # to which your Proxy ESXi must be mapped.
    # Old volume : /vol/old_volume_name/lun_name
    # New volume : /vol/new_volume_name/lun_name
    cloned_lun_path = "/vol/" + clone_volume_name + "/" + path_parts[3]
    api = NaElement("lun-map")
    api.child_add_string("initiator-group", access_group)
    api.child_add_string("path", cloned_lun_path)

    xo = server.invoke_elem(api)
    if (xo.results_status() == "failed") :
        script_log("Error:\n")
        script_log(xo.sprintf())
        sys.exit (0)
    
    # Finally set the lun online
    api = NaElement("lun-online")
    api.child_add_string("path", cloned_lun_path)

    xo = server.invoke_elem(api)
    if xo.results_status() == "failed" and \
       xo.results_reason().find("is not currently offline") == -1 :
        script_log("Error:\n")
        script_log(xo.sprintf())
        sys.exit (0)

    # Get the cloned lun serial
    cloned_lun_serial = get_lun_serial(server, cloned_lun_path)
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

    # Get the cloned lun path
    lun_path = get_volume_path(server, clone_serial)
    if len(lun_path) == 0:
        script_log("Lun %s not found" % (clone_serial))
        return

    # lun path is of the form
    #      /vol/some_vol/lun_name
    # which will split to [ '', 'vol', 'some_vol', 'lun_name' ]
    path_parts = lun_path.split('/')
    if len(path_parts) < 3:
        script_log("Could not find volume for path %s" % lun_path)
        return
    volume_name = path_parts[2]
 
    # offline the lun    
    api = NaElement("volume-offline")
    api.child_add_string("name", volume_name)

    xo = server.invoke_elem(api)
    if (xo.results_status() == "failed") :
        script_log("Error:\n")
        script_log(xo.sprintf())
        sys.exit(0)

    # delete the cloned lun    
    api = NaElement("volume-destroy")
    api.child_add_string("name", volume_name)

    xo = server.invoke_elem(api)
    if (xo.results_status() == "failed") :
        script_log("Error:\n")
        script_log(xo.sprintf())
        sys.exit(0)		

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

    # Connect to Netapp server
    conn = NaServer(options.storage_array, 1 , 7)
    conn.set_server_type("FILER")
    conn.set_transport_type("HTTPS")
    conn.set_port(443)
    conn.set_style("LOGIN")
    user, pwd = cdb.get_enc_info(options.storage_array)
    conn.set_admin_user(user, pwd)

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
