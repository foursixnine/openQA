package DBIx::Class::Timestamps;
use base 'DBIx::Class';
use DateTime;
use strict;

require Exporter;
our (@ISA, @EXPORT_OK);
@ISA       = qw(Exporter);
@EXPORT_OK = qw(now);

sub add_timestamps {
    my $self = shift;

    $self->load_components(qw(InflateColumn::DateTime DynamicDefault));

    $self->add_columns(
        t_created => {
            data_type                 => 'timestamp',
            dynamic_default_on_create => 'now'
        },
        t_updated => {
            data_type                 => 'timestamp',
            dynamic_default_on_create => 'now',
            dynamic_default_on_update => 'now'
        },
    );
}

sub now {
    DateTime->now(time_zone => 'UTC');
}

1;