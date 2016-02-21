package Bakesale::Schema::Result::Cakes;
use base qw/DBIx::Class::Core/;

__PACKAGE__->load_components(qw/+Ix::DBIC::Result/); # for example

__PACKAGE__->table('cakes');

__PACKAGE__->add_columns(
  id          => { data_type => 'integer', is_auto_increment => 1 },
  accountId   => { is_nullable => 0 },
  state       => { data_type => 'ingeger', is_nullable => 0 },
  type        => { is_nullable => 0 },
  layer_count => { data_type => 'integer', is_nullable => 0 },
  baked_at    => { data_type => 'datetime', is_nullable => 0 },
);

__PACKAGE__->set_primary_key('id');

sub ix_type_key { 'cakes' }

sub ix_user_property_names { qw(type layer_count) }

sub ix_default_properties {
  return { baked_at => Ix::DateTime->now };
}

1;
