# Copyright (C) 2017 SUSE LLC
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

package OpenQA::Worker::Cache;
use strict;
use warnings;

use File::Basename;
use Fcntl ':flock';
use Mojo::UserAgent;
use OpenQA::Utils qw(log_error log_info log_debug);
use OpenQA::Worker::Common;
use List::MoreUtils;
use File::Spec::Functions 'catdir';
use Data::Dumper;
use JSON;
use DBI;

use Digest::MD5 'md5_hex';

require Exporter;
our (@ISA, @EXPORT);
@ISA    = qw(Exporter);
@EXPORT = qw(get_asset);

my $cache;
my $host;
my $location;
my $limit   = 50;
my $db_file = "cache.db";
my $dsn     = "";
my $dbh;

END {
    $dbh->disconnect();
}

sub deploy_db {
    local $/;
    my $sql = <DATA>;
    say "Deploying DB: $sql";
    $dbh = DBI->connect($dsn, undef, undef, {RaiseError => 1, PrintError => 1, AutoCommit => 0})
      or die("Could not connect to the dbfile.");
    $dbh->do($sql);
    $dbh->commit;
    $dbh->disconnect;
}

sub init {
    my $class;
    ($host, $location) = @_;
    $db_file = catdir($location, 'cache.db');
    $dsn = "dbi:SQLite:dbname=$db_file";
    deploy_db unless (-e $db_file);

    $dbh = DBI->connect($dsn, undef, undef, {RaiseError => 1, PrintError => 1, AutoCommit => 0})
      or die("Could not connect to the dbfile.");
    say(__PACKAGE__ . ": Initialized with $host at $location");
}



sub update_asset {
    my ($asset, $etag, $size) = @_;
    my $sql
      = "REPLACE INTO assets (downloading, filename, etag, size, last_use) VALUES (0, ?, ?, ?, strftime('%s','now'));";
    say "updating the $asset with $etag and $size";
    eval {
        my $sth = $dbh->prepare($sql);
        $sth->bind_param(1, $asset);
        $sth->bind_param(2, $etag);
        $sth->bind_param(3, $size);
        $sth->execute;
    };

    if ($@) {
        say "Rolling back $@";
        $dbh->rollback;
        return 0;
    }
    else {
        say "Commit";
        $dbh->commit;
    }

}

sub download_asset {
    my ($id, $type, $asset, $etag) = @_;

    open(my $log, '>>', "autoinst-log.txt") or die("Cannot open autoinst-log.txt");
    local $| = 1;

    print $log "Attemping to download: $host $asset, $type, $id\n";
    my $ua = Mojo::UserAgent->new(max_redirects => 2);
    $ua->max_response_size(0);
    my $url = sprintf '%s/tests/%d/asset/%s/%s', $host, $id, $type, basename($asset);

    my $tx = $ua->build_tx(GET => $url);
    my $headers;

    $ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            my $progress     = 0;
            my $last_updated = time;
            $tx->req->headers->header('If-None-Match' => qq{$etag}) if $etag;
            $tx->res->on(
                progress => sub {
                    my $msg = shift;
                    if ($msg->code == 304) {
                        $msg->finish;
                    }
                    return unless my $len = $msg->headers->content_length;
                    my $size = $msg->content->progress;
                    my $current = int($size / ($len / 100));
                    # Don't spam the webui, update only every 5 seconds
                    if (time - $last_updated > 5) {
                        update_setup_status;
                        $last_updated = time;
                        if ($progress < $current) {
                            $progress = $current;
                            print $log "Downloading $asset :", $size == $len ? 100 : $progress, "\n";
                        }
                    }
                });
        });

    $tx = $ua->start($tx);

    if ($tx->res->code == 304) {
        if (toggle_asset_lock($asset, 0)) {
            say "CACHE: Content has not changed, not downloading the $asset but updating last use";
        }
        else {
            print $log "Abnormal situation";
        }
    }
    elsif ($tx->res->is_success) {
        $etag = $headers->etag;
        unlink($asset);
        $asset = $tx->res->content->asset->move_to($asset)->path;
        my $size = (stat $asset)[7];
        if ($size == $headers->content_length) {
            update_asset($asset, $etag, $size);
            say $log "CACHE: Asset download sucessful to $asset";
        }
        else {
            print $log "CACHE: Size of $asset differs, Expected: "
              . $headers->content_length
              . " / Downloaded "
              . $size;
            $asset = undef;
        }
    }
    else {
        print $log "CACHE: Download of $asset failed with: " . $tx->res->error->{message};
        $asset = undef;
    }

    return $asset;
}

sub toggle_asset_lock {
    my ($asset, $toggle) = @_;
    my $sql = "UPDATE assets set downloading = ?, filename=?, last_use = strftime('%s','now') where filename = ?;";

    eval { $dbh->prepare($sql)->execute($toggle, $asset, $asset) or die $dbh->errstr; };

    if ($@) {
        $dbh->rollback;
        die "Rolling back $@";
    }
    else {
        $dbh->commit;
        return 1;
    }

}

sub add_asset {
    my ($asset, $toggle) = @_;
    my $sql = "INSERT INTO assets (downloading,filename,last_use) VALUES (1, ?, strftime('%s','now'));";

    eval { $dbh->prepare($sql)->execute($asset) or die $dbh->errstr; };

    if ($@) {
        $dbh->rollback;
        die "Rolling back $@";
    }
    else {
        $dbh->commit;
        return 1;
    }

}

sub try_lock_asset {
    my ($asset) = @_;
    my $sth;
    my $sql;
    my $lock_granted;
    my $result;

    eval {

        $sql
          = "SELECT (last_use > strftime('%s','now') - 60 and downloading = 1 and etag != '') as is_fresh, etag from assets where filename = ?";
        $sth = $dbh->prepare($sql);
        $result = $dbh->selectrow_hashref($sql, undef, $asset);
        if (!$result) {
            add_asset($asset);
            $lock_granted = 1;
        }
        elsif (!$result->{is_fresh}) {
            $lock_granted = toggle_asset_lock($asset, 1);
        }
        elsif ($result->{is_fresh} == 1) {
            say "Being downloaded by another worker, sleeping.";
            $lock_granted = 0;
        }
        else {
            die "CACHE: Abnormal situation.";
        }

    };

    if ($@) {
        say "Rolling back $@";
        $dbh->rollback;
    }
    else {
        if ($lock_granted) {
            say "CACHE: Lock granted.";
            $dbh->commit;
            return $result;
        }
        else {
            $dbh->rollback;
            say "CACHE: Lock not granted.";
            return 0;
        }
    }

}

sub get_asset {
    my ($job, $asset_type, $asset) = @_;
    my $type;
    my $result;
    my $ret;
    $asset = catdir($location, basename($asset));

    while () {

        log_debug "CACHE: Aquiring lock for $asset in the database";

        unless ($result = try_lock_asset($asset)) {
            update_setup_status;
            say "CACHE: wait 5 seconds for the lock.";
            sleep 5;
            next;
        }

        $ret = download_asset($job, lc($asset_type), $asset, ($result->{etag}) ? $result->{etag} : undef);

        if (!$ret) {
            return undef;
        }

        last;
    }

    return $asset;
}

sub expire_asset {
    # currently only
    while (@{$cache->{$host}} > $limit) {
        my $count = @{$cache->{$host}};
        my $asset = pop(@{$cache->{$host}});
        if (-e $asset) {
            unlink($asset);
            if ($@) {
                log_error("Cannot purge $asset: $@");
            }
            else {
                log_debug("Purged $asset due to assets in cache ($count) being over $limit");
            }
        }
        else {
            log_debug("$asset does not exist, reference has been removed from the cache");
        }
    }
    write_db();
}

1;

__DATA__
CREATE TABLE "assets" ( `etag` TEXT, `size` INTEGER, `last_use` DATETIME NOT NULL, `downloading` boolean NOT NULL, `filename` TEXT NOT NULL UNIQUE, PRIMARY KEY(`filename`) );
