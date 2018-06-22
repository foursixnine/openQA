# Copyright (C) 2014 SUSE Linux Products GmbH
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

package OpenQA::Schema::Result::TestSuites;
use base 'DBIx::Class::Core';
use strict;

use db_helpers;

__PACKAGE__->table('test_suites');
__PACKAGE__->load_components(qw(Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    name => {
        data_type => 'text',
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw(name)]);
__PACKAGE__->has_many(job_templates => 'OpenQA::Schema::Result::JobTemplates', 'test_suite_id');
__PACKAGE__->has_many(
    settings => 'OpenQA::Schema::Result::TestSuiteSettings',
    'test_suite_id', {order_by => {-asc => 'key'}});

=head2 is_cluster

=over
 
=item Returns list of test suites that belong to the cluster

=back

Checks if a test_suite is part of a cluster

in array context it should return a hash of chained and parallel

=cut

sub is_cluster {
    my ($self, $args) = @_;
    my $ts = $self->settings->find({key => 'PARALLEL_WITH'});
    return split /,/, $ts->value if $ts;
    return 0;
}

sub has_cycles {
    my ($self, $args) = @_;
    use feature 'say';
    use Data::Dump qw(dump pp);
    my $rsource = $self->result_source;
    my @cycles;
    my $ts_name = '%' . $self->name . '%';

    @cycles
      = map { split /,/, $_->value } $rsource->schema->resultset('OpenQA::Schema::Result::TestSuiteSettings')->search(
        {
            key   => 'PARALLEL_WITH',
            value => {like => $ts_name}})->all;
    return @cycles;
}

1;
