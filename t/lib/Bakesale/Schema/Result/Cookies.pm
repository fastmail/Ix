package Bakesale::Schema::Result::Cookies;
use base qw/DBIx::Class::Core/;

__PACKAGE__->load_components(qw/+Ix::DBIC::Result/); # for example

__PACKAGE__->table('cookies');

__PACKAGE__->add_columns(
  id         => { data_type => 'integer', is_auto_increment => 1 },
  account_id => { is_nullable => 0 },
  state      => { is_nullable => 0 },
  type       => { is_nullable => 0 },
  baked_at   => { is_nullable => 0 },
);

__PACKAGE__->set_primary_key('id');

sub ix_type_key { 'cookies' }

sub ix_user_property_names { qw(type) }

sub ix_default_properties {
  return { baked_at => time };
}

1;