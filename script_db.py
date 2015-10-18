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
import sqlite3

class CredDB(object):

    def __init__(self, path):
        self.conn_ = sqlite3.connect(path)

    def setup(self):
        '''
        Deletes all existing tables and creates fresh
        tables
        '''
        c = self.conn_.cursor()
		
        # Cleanup existing tables if they exist
        tables = []
        for row in c.execute("SELECT name FROM sqlite_master WHERE type='table' "):
            tables.append(row[0])
		
        for table in tables:
            c.execute("DROP table %s" % table)
		
        c.execute('''CREATE TABLE pwd (host text, user text, pass text)''')
        self.conn_.commit()

    def insert_enc_info(self, hostname, user, pwd):
        c = self.conn_.cursor()
        host = (hostname,)
        c.execute("DELETE FROM pwd where host=?", host)
        c.execute("INSERT INTO pwd VALUES ('%s', '%s', '%s')" % \
				 (hostname, user, pwd))
        self.conn_.commit()

    def delete_enc_info(self, hostname):
        c = self.conn_.cursor()
        host = (hostname,)
        c.execute("DELETE FROM pwd where host=?", host)
        self.conn_.commit()

    def get_all_enc_info(self):
        c = self.conn_.cursor()
        details = []
        for row in c.execute("SELECT host, user, pass FROM pwd"):
            details.append((row[0], row[1], row[2]))

        self.conn_.commit()
        return details

    def get_enc_info(self, hostname):
        c = self.conn_.cursor()
        host = (hostname,)
        c.execute("SELECT user, pass FROM pwd where host=?", host)
        details = c.fetchone()
        self.conn_.commit()
        return details or ('', '')

    def close(self):
        self.conn_.close()
		
		
class ScriptDB(object):

    def __init__(self, path):
        self.conn_ = sqlite3.connect(path)

    def setup(self):
        '''
        Creates database tables if they do not exist
        '''
        c = self.conn_.cursor()
        table_exists = False
        for row in c.execute("SELECT name FROM sqlite_master WHERE type='table' "):
            if row[0] == 'clone_info':
                table_exists = True
                break

        if not table_exists:
            c.execute('CREATE TABLE clone_info (lun text, clone text, '\
			          'snap_name text, access_group text)')
        self.conn_.commit()

    def insert_clone_info(self, lun, clone, snap_name, group):
        c = self.conn_.cursor()
        c.execute("INSERT INTO clone_info VALUES ('%s', '%s', '%s', '%s')" % \
                  (lun, clone, snap_name, group))
        self.conn_.commit()

    def get_clone_info(self, lun_serial):
        c = self.conn_.cursor()
        lun = (lun_serial,)
        c.execute("SELECT clone, snap_name, access_group "\
		          "FROM clone_info where lun=?", lun)
        data = c.fetchone()
        self.conn_.commit()
        return data or ('', '', '')

    def delete_clone_info(self, lun_serial):
        c = self.conn_.cursor()
        lun = (lun_serial,)
        c.execute("DELETE FROM clone_info where lun=?", lun)
        self.conn_.commit()

    def close(self):
        self.conn_.close()
