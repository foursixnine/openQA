# Copyright (C) 2015-2017 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Worker;
use 5.018;
use warnings;

use Mojolicious::Lite;
use Mojo::Server::Daemon;
use Mojo::IOLoop;

use File::Spec::Functions 'catdir';

use OpenQA::Client;
use OpenQA::Utils qw(log_error log_info log_debug);
use OpenQA::Worker::Common;
use OpenQA::Worker::Commands;
use OpenQA::Worker::Pool qw(lockit clean_pool);
use OpenQA::Worker::Jobs;

sub init {
    my ($worker_options, $host_settings, %options) = @_;
    $worker_settings = $worker_options;
    $instance        = $options{instance} if defined $options{instance};
    $pooldir         = $OpenQA::Utils::prjdir . '/pool/' . $instance;
    $nocleanup       = $options{"no-cleanup"};
    $verbose         = $options{verbose} if defined $options{verbose};

    OpenQA::Worker::Common::api_init($host_settings, \%options);
    OpenQA::Worker::Engines::isotovideo::set_engine_exec($options{isotovideo}) if $options{isotovideo};
}

sub main {
    my ($host_settings) = @_;
    my $lockfd = lockit();

    clean_pool();
    ## register worker at startup to all webuis
    for my $h (@{$host_settings->{HOSTS}}) {
        # check if host`s working directory exists
        my @dirs = (
            $host_settings->{$h}{SHARE_DIRECTORY},
            catdir($OpenQA::Utils::prjdir, $h),
            catdir($OpenQA::Utils::prjdir, 'share'));
        my ($dir) = grep { $_ && -d } @dirs;
        unless ($dir) {
            log_error("Can not find working directory for host $h. Ignoring host");
            next;
        }
        log_debug("Using dir $dir for host $h") if $verbose;
        Mojo::IOLoop->next_tick(sub { OpenQA::Worker::Common::register_worker($h, $dir) });
    }

    # start event loop - this will block until stop is called
    Mojo::IOLoop->start;

    return 0;
}

sub catch_exit {
    my ($sig) = @_;
    log_info("quit due to signal $sig");
    if ($job) {
        Mojo::IOLoop->next_tick(
            sub {
                stop_job('quit');
            });
    }
    else {
        Mojo::IOLoop->stop;
    }
}

sub coroner {
    if (-d $crash_file){
        check_job_status if -e $jobfile;
        check_pool_status if -e $autoinst_log;
        update_job_cause_of_death $crash_file;
    }
}

sub update_job_cause_of_death {
    
}

$SIG{HUP}  = \*catch_exit;
$SIG{TERM} = \*catch_exit;
$SIG{INT}  = \*catch_exit;

1;
