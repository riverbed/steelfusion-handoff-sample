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

# Script DB is used to store/load the cloned lun
# information and the credentials
import script_db
import sys

DB_NAME = 'cred_db'

if __name__ == '__main__':
    # Create DB
    db = script_db.CredDB('cred_db')

    done = False
    while not done:
        # Get the operation type
        op_str = input('\n1 - Setup new DB\n'\
                        '2 - Add/Modify Host\n'\
                        '3 - Delete Host\n'\
                        '4 - Show all passwords\n'\
                        '5 - Exit\nEnter Operation: ').strip()
        op = 0
        try:
            op = int(op_str)
        except:
            print ('Invalid operation type ' + op_str + '\n')
            continue

        if op == 1 :
            # Drops all previous data and creates fresh tables
            db.setup()
        elif op == 2:
            # Adds a new entry if it does exist, modifies it if it exists
            host = input('\nHost      : ').strip()
            user = input('\nUsername  : ').strip()
            pwd  = input('\nPassword  : ').strip()
            db.insert_enc_info(host, user, pwd)

        elif op == 3:
            # Deletes an entry if it exists
            host = input('\nHost      : ').strip()
            db.delete_enc_info(host)

        elif op == 4:
            # Displays all entered information
            details = db.get_all_enc_info()
            for host, user, pwd in details:
                print('\nHost: %s User: %s Password: %s' % (host, user, pwd))

        elif op == 5:
            # Exits the program
            print ('Good Bye!')
            sys.exit(0)
        else:
            print ('Invalid operation, retry\n')
        

