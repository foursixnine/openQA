#! /usr/bin/perl

# Copyright (C) 2016-2018 SUSE LLC
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

# possible reasons why this tests might fail if you run it locally:
#  * the web UI or any other openQA daemons are still running in the background
#  * a qemu instance is still running (maybe leftover from last failed test
#    execution)

use Mojo::Base -strict;

my $tempdir;
BEGIN {
    unshift @INC, 'lib';
    use FindBin;
    use Mojo::File qw(path tempdir);
    $tempdir = tempdir(DIR => path('t/full-stack.d')->realpath, TEMPLATE => 'openQA_FULLSTACK-XXXX');
    $ENV{OPENQA_BASEDIR} = $tempdir->child('t', 'full-stack.d');
    $ENV{OPENQA_CONFIG}  = path($ENV{OPENQA_BASEDIR}, 'config')->make_path;
    # Since tests depends on timing, we require the scheduler to be fixed in its actions.
    $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS}   = 4000;
    $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION} = 1;
    # ensure the web socket connection won't timeout
    $ENV{MOJO_INACTIVITY_TIMEOUT} = 10 * 60;
    path($FindBin::Bin, "data")->child("openqa.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("openqa.ini"));
    path($FindBin::Bin, "data")->child("database.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("database.ini"));
    path($FindBin::Bin, "data")->child("workers.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("workers.ini"));
    path($ENV{OPENQA_BASEDIR}, 'openqa', 'db')->make_path->child("db.lock")->spurt;
    # DO NOT SET OPENQA_IPC_TEST HERE
}

use lib "$FindBin::Bin/lib";
use Test::More;
use Test::Mojo;
use Test::Output 'stderr_like';
use Data::Dumper;
use IO::Socket::INET;
use POSIX '_exit';
use OpenQA::Worker::Cache::Client;
use Fcntl ':mode';
use DBI;
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
session->enable;
# optional but very useful
eval 'use Test::More::Color';
eval 'use Test::More::Color "foreground"';

use File::Path qw(make_path remove_tree);
use Module::Load::Conditional 'can_load';
use OpenQA::Test::Utils
  qw(create_websocket_server create_live_view_handler create_resourceallocator start_resourceallocator setup_share_dir),
  qw(cache_minion_worker cache_worker_service);
use OpenQA::Test::FullstackUtils;

plan skip_all => "set FULLSTACK=1 (be careful)" unless $ENV{FULLSTACK};
plan skip_all => 'set TEST_PG to e.g. DBI:Pg:dbname=test" to enable this test' unless $ENV{TEST_PG};

my $workerpid;
my $wspid;
my $livehandlerpid;
my $resourceallocatorpid;
my $sharedir = setup_share_dir($ENV{OPENQA_BASEDIR});

sub turn_down_stack {
    for my $pid ($workerpid, $wspid, $livehandlerpid, $resourceallocatorpid) {
        next unless $pid;
        kill TERM => $pid;
        waitpid($pid, 0);
    }
}

sub kill_worker {
    # now kill the worker
    kill TERM => $workerpid;
    is(waitpid($workerpid, 0), $workerpid, 'WORKER is done');
    $workerpid = undef;
}

use OpenQA::SeleniumTest;

# skip if appropriate modules aren't available
unless (check_driver_modules) {
    plan skip_all => $OpenQA::SeleniumTest::drivermissing;
    exit(0);
}

OpenQA::Test::FullstackUtils::setup_database();

# make sure the assets are prefetched
ok(Mojolicious::Commands->start_app('OpenQA::WebAPI', 'eval', '1+0'));

$resourceallocatorpid = start_resourceallocator;

# we don't want no fixtures
my $driver       = call_driver(sub { });
my $mojoport     = OpenQA::SeleniumTest::get_mojoport;
my $connect_args = OpenQA::Test::FullstackUtils::get_connect_args();

my $resultdir = path($ENV{OPENQA_BASEDIR}, 'openqa', 'testresults')->make_path;
ok(-d $resultdir, "resultdir \"$resultdir\" exists");

$driver->title_is("openQA", "on main page");
is($driver->find_element('#user-action a')->get_text(), 'Login', "noone logged in");
$driver->click_element_ok('Login', 'link_text');
# we're back on the main page
$driver->title_is("openQA", "back on main page");

# cleak away the tour
$driver->click_element_ok('dont-notify', 'id');
$driver->click_element_ok('confirm',     'id');

my $wsport = $mojoport + 1;
$wspid = create_websocket_server($wsport, 0, 0, 0);

$livehandlerpid = create_live_view_handler($mojoport);

my $JOB_SETUP
  = 'ISO=Core-7.2.iso DISTRI=tinycore ARCH=i386 QEMU=i386 QEMU_NO_KVM=1 '
  . 'FLAVOR=flavor BUILD=1 MACHINE=coolone QEMU_NO_TABLET=1 INTEGRATION_TESTS=1 '
  . 'QEMU_NO_FDC_SET=1 CDMODEL=ide-cd HDDMODEL=ide-drive VERSION=1 TEST=core PUBLISH_HDD_1=core-hdd.qcow2 '
  . 'UEFI_PFLASH_VARS=/usr/share/qemu/ovmf-x86_64.bin';

subtest 'schedule job' => sub {
    OpenQA::Test::FullstackUtils::client_call("jobs post $JOB_SETUP");
    OpenQA::Test::FullstackUtils::verify_one_job_displayed_as_scheduled($driver);
};

my $job_name = 'tinycore-1-flavor-i386-Build1-core@coolone';
$driver->find_element_by_link_text('core@coolone')->click();
$driver->title_is("openQA: $job_name test results", 'scheduled test page');
my $job_page_url = $driver->get_current_url();
like($driver->find_element('#result-row .card-body')->get_text(), qr/State: scheduled/, 'test 1 is scheduled');
javascript_console_has_no_warnings_or_errors;

sub start_worker {
    $workerpid = fork();
    if ($workerpid == 0) {
        exec("perl ./script/worker --instance=1 $connect_args --isotovideo=../os-autoinst/isotovideo --verbose");
        die "FAILED TO START WORKER";
    }
    else {
        ok($workerpid, "Worker started as $workerpid");
        OpenQA::Test::FullstackUtils::schedule_one_job;
    }
}


my $cache_location = path($ENV{OPENQA_BASEDIR}, 'cache')->make_path;
ok(-e $cache_location, "Setting up Cache directory");

open(my $conf, '>', path($ENV{OPENQA_CONFIG})->child("workers.ini")->to_string);
print $conf <<EOC;
[global]
CACHEDIRECTORY = $cache_location
CACHELIMIT = 50

[http://localhost:$mojoport]
TESTPOOLSERVER = $sharedir/tests
EOC
close($conf);

ok(-e path($ENV{OPENQA_CONFIG})->child("workers.ini"), "Config file created.");

# For now let's repeat the cache tests before extracting to separate test
subtest 'Cache tests' => sub {

    my $cache_service        = cache_worker_service;
    my $worker_cache_service = cache_minion_worker;

    my $db_file = $cache_location->child('cache.sqlite');
    ok(!-e $db_file, "cache.sqlite is not present");

    my $filename;
    open($filename, '>', $cache_location->child("test.file"));
    print $filename "Hello World";
    close($filename);

    path($cache_location, "test_directory")->make_path;

    $worker_cache_service->restart->restart;
    $cache_service->restart->restart;

    my $cache_client = OpenQA::Worker::Cache::Client->new;

    sleep 5 and diag "Waiting for cache service to be available"        until $cache_client->available;
    sleep 5 and diag "Waiting for cache service worker to be available" until $cache_client->available_workers;

    my $job_name = 'tinycore-1-flavor-i386-Build1-core@coolone';

    $driver->get('/tests/1');
    like($driver->find_element('#result-row .card-body')->get_text(), qr/State: scheduled/, 'test 1 is scheduled')
      or die;
    start_worker;
    OpenQA::Test::FullstackUtils::wait_for_job_running($driver, 1);
    ok(-e $db_file, "cache.sqlite file created");
    ok(!-d path($cache_location, "test_directory"), "Directory within cache, not present after deploy");
    ok(!-e $cache_location->child("test.file"), "File within cache, not present after deploy");

    like(
        readlink(path($ENV{OPENQA_BASEDIR}, 'openqa', 'pool', '1')->child("Core-7.2.iso")),
        qr($cache_location/localhost/Core-7.2.iso),
        "iso is symlinked to cache"
    );

    OpenQA::Test::FullstackUtils::wait_for_result_panel($driver, qr/Result: passed/, 'test 1 has passed');
    kill_worker;

    #  The worker is launched with --verbose, so by default in this test the level is always debug
    if (!$ENV{MOJO_LOG_LEVEL} || $ENV{MOJO_LOG_LEVEL} =~ /DEBUG|INFO/i) {
        $filename = path($resultdir, '00000', "00000005-$job_name")->child("autoinst-log.txt");
        my $autoinst_log = $filename->slurp;

        like($autoinst_log, qr/Downloading Core-7.2.iso/, 'Test 1, downloaded the right iso.');
        like($autoinst_log, qr/11116544/,                 'Test 1 Core-7.2.iso size is correct.');
        like($autoinst_log, qr/result: done/,             'Test 1 result done');
        like((split(/\n/, $autoinst_log))[0], qr/\+\+\+ setup notes \+\+\+/, 'Test 1 correct autoinst setup notes');
        like(
            (split(/\n/, $autoinst_log))[-1],
            qr/uploading autoinst-log.txt/,
            'Test 1 correct autoinst uploading autoinst'
        );
    }
    my $dbh
      = DBI->connect("dbi:SQLite:dbname=$db_file", undef, undef, {RaiseError => 1, PrintError => 1, AutoCommit => 1});
    my $sql    = "SELECT * from assets order by last_use asc";
    my $sth    = $dbh->prepare($sql);
    my $result = $dbh->selectrow_hashref($sql);
    # We know it's going to be this host because it's what was defined in
    # the worker ini
    like($result->{filename}, qr/Core-7/, "Core-7.2.iso is the first element");

    for (1 .. 5) {
        $filename = $cache_location->child("$_.qcow2");
        open(my $tmpfile, '>', $filename);
        print $tmpfile $filename;
        $sql = "INSERT INTO assets (filename,etag,last_use) VALUES ( ?, 'Not valid', strftime('%s','now'));";
        $sth = $dbh->prepare($sql);
        $sth->bind_param(1, $filename);
        $sth->execute();
        sleep 1;    # so that last_use is not the same for every item
    }

    $sql    = "SELECT * from assets order by last_use desc";
    $sth    = $dbh->prepare($sql);
    $result = $dbh->selectrow_hashref($sql);
    like($result->{filename}, qr/5.qcow2$/, "file #5 is the newest element");

    # Delete image #5 so that it gets cleaned up when the worker is initialized.
    $sql = "delete from assets where filename = ? ";
    $dbh->prepare($sql)->execute($result->{filename});

    #simple limit testing.
    OpenQA::Test::FullstackUtils::client_call(
        'jobs/1/restart post',
        qr|\Qtest_url => [{ 1 => "/tests/2\E|,
        'client returned new test_url'
    );
    #] restore syntax highlighting in Kate

    $driver->get('/tests/2');
    like($driver->find_element('#result-row .card-body')->get_text(), qr/State: scheduled/, 'test 2 is scheduled');
    start_worker;
    OpenQA::Test::FullstackUtils::wait_for_result_panel($driver, qr/Result: passed/, 'test 2 has passed');
    kill_worker;

    ok(!-e $result->{filename}, "asset 5.qcow2 removed during cache init");

    $sql    = "SELECT * from assets order by last_use desc";
    $sth    = $dbh->prepare($sql);
    $result = $dbh->selectrow_hashref($sql);

    like($result->{filename}, qr/Core-7/, "Core-7.2.iso the most recent asset again ");

    #simple limit testing.
    OpenQA::Test::FullstackUtils::client_call(
        'jobs/2/restart post',
        qr|\Qtest_url => [{ 2 => "/tests/3\E|,
        'client returned new test_url'
    );
    #] restore syntax highlighting in Kate
    $driver->get('/tests/3');
    like($driver->find_element('#result-row .card-body')->get_text(), qr/State: scheduled/, 'test 3 is scheduled');
    start_worker;
    OpenQA::Test::FullstackUtils::wait_for_result_panel($driver, qr/Result: passed/, 'test 3 has passed');

    #  The worker is launched with --verbose, so by default in this test the level is always debug
    if (!$ENV{MOJO_LOG_LEVEL} || $ENV{MOJO_LOG_LEVEL} =~ /DEBUG|INFO/i) {
        $filename = path($resultdir, '00000', "00000003-$job_name")->child("autoinst-log.txt");
        ok(-s $filename, 'Test 3 autoinst-log.txt file created');

        my $autoinst_log = $filename->slurp;

        like($autoinst_log, qr/Content has not changed/,     'Test 3 Core-7.2.iso has not changed.');
        like($autoinst_log, qr/\+\+\+\ worker notes \+\+\+/, 'Test 3 correct autoinst worker notes');
        like((split(/\n/, $autoinst_log))[0], qr/\+\+\+ setup notes \+\+\+/, 'Test 3 correct autoinst setup notes');
        like(
            (split(/\n/, $autoinst_log))[-1],
            qr/uploading autoinst-log.txt/,
            'Test 3 correct autoinst uploading autoinst'
        );
    }
    OpenQA::Test::FullstackUtils::client_call("jobs post $JOB_SETUP HDD_1=non-existent.qcow2");
    OpenQA::Test::FullstackUtils::schedule_one_job;
    $driver->get('/tests/4');
    OpenQA::Test::FullstackUtils::wait_for_result_panel($driver, qr/Result: incomplete/, 'test 4 is incomplete');

    #  The worker is launched with --verbose, so by default in this test the level is always debug
    if (!$ENV{MOJO_LOG_LEVEL} || $ENV{MOJO_LOG_LEVEL} =~ /DEBUG|INFO/i) {
        $filename = path($resultdir, '00000', "00000004-$job_name")->child("autoinst-log.txt");
        ok(-s $filename, 'Test 4 autoinst-log.txt file created');

        my $autoinst_log = $filename->slurp;

        like($autoinst_log, qr/\+\+\+\ worker notes \+\+\+/, 'Test 4 correct autoinst worker notes');
        like((split(/\n/, $autoinst_log))[0], qr/\+\+\+ setup notes \+\+\+/, 'Test 4 correct autoinst setup notes');
        like(
            (split(/\n/, $autoinst_log))[-1],
            qr/uploading autoinst-log.txt/,
            'Test 4 correct autoinst uploading autoinst'
        );

        like($autoinst_log, qr/non-existent.qcow2 failed with: 404 - Not Found/,
            'Test 8 failure message found in log.');
        like($autoinst_log, qr/result: setup failure/, 'Test 4 state correct: setup failure');
    }

    kill_worker;
};

kill_driver;
turn_down_stack;
done_testing;

# in case it dies
END {
    kill_driver;
    turn_down_stack;
    session->clean;
    $? = 0;
}
