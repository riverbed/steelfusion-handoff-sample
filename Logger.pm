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


package Logger;
use File::Basename;
#use Sys::Syslog;
#use Sys::Syslog qw(:standard :macros);

# For logging events in the Windows Event Log
use Win32::EventLog;

use warnings;
use strict;

sub new {
    my $class = shift;
    my ($progname) = @_;
	my $handle = undef;
    if (! defined($progname)) {
        $progname = basename($0);
        #Strip of extension
        $progname =~ s/\.[^.]+$//;
    }
    unless (defined $Logger::_instance) {
        #openlog($progname, 'cons.pid', 'user');
		$Logger::_handle = Win32::EventLog->new("System", $ENV{ComputerName});
        $Logger::_instance ||= bless
                                {
                                log_level_str_ => {"LOG_ERR" , EVENTLOG_ERROR_TYPE,
                                                   "LOG_DEBUG", EVENTLOG_INFORMATION_TYPE,
                                                   "LOG_INFO", EVENTLOG_INFORMATION_TYPE,
                                                   "LOG_NOTICE", EVENTLOG_INFORMATION_TYPE,
                                                   "LOG_WARNING", EVENTLOG_WARNING_TYPE }

                                }, $class;
    };
}

sub initialize {
    my ($progname) = @_;
    Logger->new($progname);
}

sub instance {
    return $Logger::_instance;
}

sub info {
    my $self = shift;
    my ($pfx, $msg) = @_;
    $self->logit("LOG_INFO", $pfx, $msg);
};

sub warn {
    my $self = shift;
    my ($pfx, $msg) = @_;
    $self->logit("LOG_WARNING", $pfx, $msg);
};

sub error {
    my $self = shift;
    my ($pfx, $msg) = @_;
    $self->logit("LOG_ERR", $pfx, $msg);
};

sub note {
    my $self = shift;
    my ($pfx, $msg) = @_;
    $self->logit("LOG_NOTICE", $pfx, $msg);
};

sub debug {
    my $self = shift;
    my ($pfx, $msg) = @_;
    $self->logit("LOG_INFO", $pfx, $msg);
};

sub logit {
    my $self = shift;
    my ($log_level_str, $pfx, $msg) = @_;
    my $log_level = $self->{log_level_str_}->{$log_level_str};
    my $log_msg = "[$pfx.$log_level_str] - $msg";
	
	my %event = ( 'EventID' , 100,
	              'EventType', $log_level,
				  'Category', "",
				  'Strings',  $log_msg,
				  'Data', $log_msg);
	
    #syslog($log_level, $log_msg);
	if (defined $Logger::_handle) {
		$Logger::_handle->Report(\%event);
	}
    print($log_msg . "\n");
};

sub DESTROY {
    if (defined $Logger::_handle) {
		$Logger::_handle->Close();
	}
}

1;
