use 5.20.0;
use warnings;
package Ix::DBIC::Result;
# ABSTRACT: a DBIC result class with JMAP smarts

use parent 'DBIx::Class';

use experimental qw(signatures postderef);

use Ix::StateComparison;
use Ix::Validators;
use Ix::Util qw(ix_new_id);
use JSON::MaybeXS;

=head1 SYNOPSIS

    package MyApp::Schema::Result::Cookie;
    use base qw/DBIx::Class::Core/;

    __PACKAGE__->load_components(qw/+Ix::DBIC::Result/);

    __PACKAGE__->table('cookies');

    __PACKAGE__->ix_add_columns;

    __PACKAGE__->ix_add_properties(
      batch      => { data_type => 'integer', client_may_init => 0, client_may_update => 0 },
      ...
    );

    __PACKAGE__->set_primary_key('id');

    sub ix_type_key { 'Cookie' }

    sub ix_account_type { 'generic' }

    ...

=head1 OVERVIEW

This class is where Ix gets most of its smarts. In your application, you define
C<DBIx::Class> result classes (here, rclasses) and load this class as a
component. Doing so gives you many extra behaviors, and allows you to hook into
various points of the operations done by L<Ix::DBIC::ResultSet> in its
implementations of the core JMAP methods.

=cut

__PACKAGE__->load_components(qw/+Ix::DBIC::AccountResult/);

=method ix_account_type

You B<must> define this method in your rclass. This is the account type that's
passed to C<with_account> in L<Ix::Context>.

(In theory, an Ix application can have multiple account types, but in practice,
we have only ever used a single one.)

=cut

sub ix_account_type { Carp::confess("ix_account_type not implemented") }

=method ix_type_key

You B<must> define this method in your rclass. This is the JMAP noun associated
with this rclass (e.g., the type key for 'Foo/get' is 'Foo').

=cut

# Checked for in ix_finalize
# sub ix_type_key { }

=method ix_query_enabled

If this returns a true value, the JMAP processor will generate handlers for
'Foo/query' and 'Foo/queryChanges'. The default is false, so these methods
will not be generated unless you ask.

=cut

sub ix_query_enabled {}


=method ix_extra_get_args

If provided by an rclass, this should return a list of keys that clients are
allowed to pass as arguments to 'Foo/get' (in addition to the JMAP-defined
I<ids> and I<properties>).

=cut

sub ix_extra_get_args { }

=method ix_account_base

This must return true if this rclass represents a new 'account': that is, if
it is the source for new accountIds for an account type.

For example: say your application might have several rclasses: User, Cookie,
and Cake. Cookies and Cakes belong to Users; the accountId field of the Cookie
and Cake tables point to a User's id. In this case, C<ix_account_base> should
return true for the User rclass, and false for the Cookie and Cake rclasses.

=cut

sub ix_is_account_base { 0 }

=method ix_virtual_property_names

This returns a list of properties defined as C<is_virtual> in the call to
C<ix_add_properties>.

=cut

sub ix_virtual_property_names ($self, @) {
  my $prop_info = $self->ix_property_info;
  return grep {; $prop_info->{$_}{is_virtual} } keys %$prop_info;
}

=method ix_property_names

This returns a list of all property names defined in the call to
C<ix_add_properties>.

=cut

sub ix_property_names ($self, @) {
  return keys $self->ix_property_info->%*;
}

=method ix_client_update_ok_properties($ctx)

This returns a list of all the property names allowed to be updated by C<$ctx>.
For normal contexts, this includes all properties defined as
C<client_may_update>, minus any virtual or immutable properties. System contexts
may update non-updateable properties, but not virtual or immutable ones.

=cut

sub ix_client_update_ok_properties ($self, $ctx) {
  my $prop_info = $self->ix_property_info;

  if ($ctx->root_context->is_system) {
    return
      grep {;    ! $prop_info->{$_}{is_virtual}
              && ! $prop_info->{$_}{is_immutable} }
      keys %$prop_info;
  }

  return
    grep {;      $prop_info->{$_}{client_may_update}
            && ! $prop_info->{$_}{is_virtual}
            && ! $prop_info->{$_}{is_immutable} }
    keys %$prop_info;
}

=method ix_client_init_ok_properties($ctx)

This returns a list of all the property names allowed to be initialized by C<$ctx>.
For normal contexts, this includes all properties defined as
C<client_may_init>, minus any virtual or immutable properties. System contexts
may always initialize properties.

=cut

sub ix_client_init_ok_properties ($self, $ctx) {
  my $prop_info = $self->ix_property_info;

  if ($ctx->root_context->is_system) {
    return keys %$prop_info;
  }

  return
    grep {; $prop_info->{$_}{client_may_init} && ! $prop_info->{$_}{is_virtual} }
    keys %$prop_info;
}

=method ix_default_properties

Rclasses can override this to define default properties. It should return a
hashref of C<< property_name => 'value' >> pairs.

=cut

sub ix_default_properties { return {} }

sub new ($class, $attrs) {
  # Are we an actual Ix result?
  if ($class->can('ix_type_key')) {
    $attrs->{id} //= ix_new_id();
  }

  return $class->next::method($attrs);
}

=method ix_add_columns

This method adds all of the default columns for JMAP operations: id, accountId,
created, modSeqCreated, modSeqChanged, dateDestroyed, and isACtive.

=cut

sub ix_add_columns ($class) {
  $class->ix_add_properties(
    id            => {
      data_type     => 'idstr',
      client_may_init   => 0,
      client_may_update => 0,
    },
  );

  $class->add_columns(
    accountId     => { data_type => 'uuid' },
    created       => { data_type => 'timestamptz', default_value => \'NOW()' },
    modSeqCreated => { data_type => 'integer' },
    modSeqChanged => { data_type => 'integer' },
    dateDestroyed => { data_type => 'timestamptz', is_nullable => 1 },
    isActive      => { data_type => 'boolean', is_nullable => 1, default_value => 1 },
  );
}

=method ix_add_unique_constraint($constraint)

=method ix_add_unique_constraints(@constraints)

These methods are wrappers around DBIC's C<add_unique_constraints>, but add
C<isActive> to the constraint. This is necessary because C<ix_destroy> does not
actually destroy rows, but simply I<marks> them destroyed. That means if you
were to add a constraint, then destroy the row, you could never add a matching
row again. Using these methods makes sure that doesn't happen.

=cut

# What we're doing here is injecting a column (isActive) into the beginning of
# the unique constraints that has only two possible values: true on create, and
# NULL when the row is destroyed. While the value is true, it allows the unique
# constraint to work.  When the value becomes NULL, it will no longer ever match
# any other rows, and so will not get in the way of active data (in Postgres,
# NULL is never equal to NULL).
sub ix_add_unique_constraints ($class, @constraints) {
  for my $c (@constraints) {
    if (ref $c) {
      unshift @$c, 'isActive';
    }
  }

  $class->add_unique_constraints(@constraints);
}

sub ix_add_unique_constraint ($class, @constraint) {
  $class->ix_add_unique_constraints(@constraint);
}

=method ix_add_properties(@pairs)

This is the method used to add properties (columns) to an rclass. It is mostly a
wrapper around DBIC's C<add_columns>, but does additional housekeeping so that
we can generate JMAP handlers with these properties later.

An example will be useful:

    package MyApp::Schema::Result::Cookie;
    use Ix::Validators qw(integer);

    __PACKAGE__->ix_add_properties(
      batch       => { data_type => 'integer', client_may_init => 0, client_may_update => 0 },
      baked_at    => { data_type => 'timestamptz', is_optional => 1 },
      stale_date  => { data_type => 'timestamptz', is_virtual => 1 },
      batch_size  => { data_type => 'integer', is_optional => 1, validator => integer(0, 100) },

    );

This code adds four properties to our rclass:

=for :list
1. batch - an integer, not updateable or initializable by the client
2. baked_at - an optional timestamp
3. stale_date - a virtual property; no database column is added, and is
   computed each time it's requested by the client
4. batch_size - an optional integer, which must be between 0 and 100.

C<data_type> defines the type of the column, and also provides automatic
validation with L<Ix::Validator>. They're shown here with their corresponding
Postgres types and which validator they use:

=for :list
* string - text, validated with C<simplestr>
* istring - citext, validated with C<simplestr> (searched case insensitively)
* timestamptz - timestamptz, not validated by Ix
* string[] - text[], not currently validated by Ix
* boolean - boolean, validated with C<boolean>
* integer - integer, is_numeric = 1, validated with C<integer>
* idstr - uuid, validated with C<idstr>.

Other keys you might use in a column definition include:

=for :list
- client_may_init - clients may set this property during creation (default: 1)
- client_may_update - clients may set this property during update (default: 1)
- is_optional - records do not have to have this property (default: 0)
- is_virtual - this property is not stored in the database (default: 0)
- validator - a different validator to use (default: per data type)
- default_value - a default value for the property

=method ix_property_info

This returns a hashref of the saved property information for the rclass.

=cut

my %IX_TYPE = (
  # idstr should get done this way in the future
  string       => { data_type => 'text' },
  istring      => { data_type => 'citext' },
  timestamptz  => { data_type => 'timestamptz' },

  # We don't provide istring[] because DBD::Pg doesn't work nicely with it yet:
  # https://rt.cpan.org/Public/Bug/Display.html?id=54224
  'string[]'   => { data_type => 'text[]' },

  boolean      => { data_type => 'boolean' },
  integer      => { data_type => 'integer', is_numeric => 1 },
  idstr        => { data_type => 'uuid', },
);

sub ix_add_properties ($class, @pairs) {
  my %info = @pairs;

  while (my ($name, $def) = splice @pairs, 0, 2) {
    next if $def->{is_virtual};

    Carp::confess("Attempt to add property $name with no data_type")
      unless defined $def->{data_type};

    my $ix_type = $IX_TYPE{ $def->{data_type} };

    Carp::confess("Attempt to add property $name with unknown data_type $def->{data_type}")
      unless $ix_type && $ix_type->{data_type};

    my $col_info = {
      is_nullable   => $def->{is_optional} ? 1 : 0,
      default_value => $def->{default_value},
      %$ix_type,

      ($def->{db_data_type} ? (data_type => $def->{db_data_type}) : ()),
    };

    $class->add_columns($name, $col_info);

    if ($def->{data_type} eq 'boolean') {
      # So differ() can compare these to API inputs sensibly
      $class->inflate_column($name, {
        inflate => sub ($raw_value_from_db, $result_object) {
          return $raw_value_from_db ? JSON->true : JSON->false;
        },
        deflate => sub ($input_value, $result_object) {
          $input_value ? 1 : 0,
        },
      });
    }
  }

  if ($class->can('ix_property_info')) {
    my $stored = $class->ix_property_info;
    for my $prop (keys %info) {
      Carp::confess("attempt to re-add property $prop") if $stored->{$prop};
      $stored->{$prop} = $info{$prop};
    }
  } else {
    my $reader = sub ($self) { return \%info };
    Sub::Install::install_sub({
      code => $reader,
      into => $class,
      as   => 'ix_property_info',
    });
  }

  return;
}

my %DEFAULT_VALIDATOR = (
  integer => Ix::Validators::integer(),
  string  => Ix::Validators::string({ oneline => 1 }),
  istring => Ix::Validators::string({ oneline => 1 }),
  boolean => Ix::Validators::boolean(),
  idstr   => Ix::Validators::idstr(),
);

=method ix_finalize

This method is called by the schema's C<ix_finalize> method. It does a bunch of
internal error checking, and throws fatal errors if you've messed up something
in your rclass definition.

=cut

my %DID_FINALIZE;
sub ix_finalize ($class) {
  if ($DID_FINALIZE{$class}++) {
    Carp::confess("tried to finalize $class a second time");
  }

  unless ($class->can('ix_type_key')) {
    Carp::confess("Class $class must define an 'ix_type_key' method");
  }

  my $prop_info = $class->ix_property_info;

  if ($class->ix_query_enabled) {
    my @missing;

    for my $method (qw(
      ix_query_check
      ix_query_changes_check
      ix_query_filter_map
      ix_query_sort_map
      ix_query_joins
    )) {
      push @missing, $method unless $class->can($method);
    }

    if (@missing) {
      Carp::confess(
          "$class - ix_query_enabled is true but these required methods are missing: "
        . join(', ', @missing)
      );
    }

    # Ensure filters are diffable. If they aren't we'll crash in
    # ix_query_changes when trying to figure out if something has changed.
    # For now, we require that either:
    #
    #  - The filter is a property of the class (it's in by ix_property_info)
    #  - The filter specifies its own custom differ
    #  - The filter contains a relationship ('this.that') and the relationship
    #    is listed as joinable in ix_query_joins. (Note that we do
    #    not verify the columns on the related tables... yet...)
    my @broken;

    my $fmap = $class->ix_query_filter_map;

    my %joins = map { $_ => 1 } $class->ix_query_joins;

    for my $k (keys %$fmap) {
      my $rel_ok;

      if ($k =~ /\./) {
        my ($rel) = $k =~ /^([^.]+?)\./;

        $rel_ok = $joins{$rel};
      }

      unless (
           $prop_info->{$k}
        || $fmap->{$k}->{differ}
        || $rel_ok
      ) {
        push @broken, $k;
      }
    }

    if (@broken) {
      Carp::confess(
          "$class - ix_query_filter_map has filters that don't match columns or have custom differs: "
        . join(', ', @broken)
      );
    }
  }

  for my $name (keys %$prop_info) {
    my $info = $prop_info->{$name};

    $info->{client_may_update} = 1 unless exists $info->{client_may_update};
    $info->{client_may_init}   = 1 unless exists $info->{client_may_init};
    $info->{validator} //= $DEFAULT_VALIDATOR{ $info->{data_type} };
  }
}

=head1 HOOK METHODS

L<Ix::DBIC::ResultSet> calls out to many methods defined in the rclass during
normal JMAP method handlers. This allows your rclasses to customize their
handling in lots of ways, without needing to subclass the ResultSet class
itself. They come in several varieties:

=begin :list

= check methods (C<ix_FOO_check>)

These are called I<before> the corresponding operation. If they return a value,
that value must be an L<Ix::Error> object (probably, generated via
C<< $ctx->error >>). This is especially useful for doing authorization checks.

= error methods (C<ix_FOO_error>)

The methods are passed any error, and expected to return a pair
C<($row, $error)>. They are useful for modifying the result of an error, or for
ignoring errors entirely. You can return a row to ignore the error, return a
different error to modify it, or return the empty list to allow error handling
to continue as normal.

= transactional hook methods (C<ix_created>, C<ix_updated>, C<ix_destroyed>)

These hooks are called inside the transaction where the create/update/destroy
occurs, and passed the row object. They are most useful for performing side
effects that might need to be rolled back if the transaction fails.

= postprocess methods (C<ix_postprocess_FOO>)

Thes hooks are called I<after> the create/update/destroy transaction occurs, and
can be used to modify the results, or to perform side effects.

=end :list

=method ix_set_check($ctx, \%arg)

A check method called before Foo/set operations.

=method ix_create_check($ctx, \%record)

A check method called before Foo/set#create operations.

=method ix_update_check($ctx, $row, \%record)

A check method called before Foo/set#update operations.

=method ix_destroy_check($ctx, $row)

A check method called before Foo/set#destroy operations.

=method ix_changes_check($ctx, \%arg)

A check method called before Foo/changes operations.

=method ix_query_check($ctx, \%arg, \%search)

A check method called before Foo/query operations. (You must define this method
if C<ix_query_enabled> is true for your rclass.)

=method ix_query_changes_check($ctx, \%arg, \%search)

A check method called before Foo/queryChanges operations. (You must define this method
if C<ix_query_enabled> is true for your rclass.)

=cut

sub ix_set_check { return; } # ($self, $ctx, \%arg)

sub ix_get_check              { } # ($self, $ctx, \%arg)
sub ix_create_check           { } # ($self, $ctx, \%rec)
sub ix_update_check           { } # ($self, $ctx, $row, \%rec)
sub ix_destroy_check          { } # ($self, $ctx, $row)
sub ix_changes_check          { } # ($self, $ctx, \%arg)

=method ix_create_error($ctx, \%error)

A hook method called when Foo/set#create encounters errors.

=method ix_update_error($ctx, \%error)

A hook method called when Foo/set#update encounters errors.

=cut

sub ix_create_error  { return; } # ($self, $ctx, \%error)
sub ix_update_error  { return; } # ($self, $ctx, \%error)

=method ix_created($ctx, $row)

A hook method called inside the Foo/set#create transaction.

=method ix_updated($ctx, $row, \%changes)

A hook method called inside the Foo/set#update transaction. C<$changes> is a
hashref with both C<old> and C<new> keys, so hooks can inspect the changes and
take action only in certain cases.

=method ix_destroyed($ctx, $row)

A hook method called inside the Foo/set#destroy transaction.

=cut

sub ix_created   { } # ($self, $ctx, $row)
sub ix_destroyed { } # ($self, $ctx, $row)

# The input to ix_updated is not trivial to compute, so it is only called if
# present, so we don't define it in the base class. -- rjbs, 2017-01-06
# sub ix_updated   { } # ($self, $ctx, $row, \%changes)

=method ix_postprocess_create($self, $ctx, \@rows)

A postprocess hook called after Foo/set#create operations.

=method ix_postprocess_update($self, $ctx, \%updated)

A postprocess hook called after Foo/set#create operations.

=method ix_postprocess_destroy($self, $ctx, \@row_ids)

A postprocess hook called after Foo/set#create operations.

=cut

sub ix_postprocess_create  { } # ($self, $ctx, \@rows)
sub ix_postprocess_update  { } # ($self, $ctx, \%updated)
sub ix_postprocess_destroy { } # ($self, $ctx, \@row_ids)

# I am not going to document this publicly, but its signature is
# ($self, $ctx, $get_arg, $results)
sub _return_ix_get   { return $_[3]->@* }

# Methods without base implementations below

=method ix_published_method_map

This method provides a way to add additional JMAP handlers to your rclasses
(in addition to the standard /get, /set, etc. handlers). If provided, it should
return a hashref of C<< $jmap_name => $subroutine_name >> pairs. The
subroutines are called with a context object and any arguments to the
JMAP method call.

For example:

    package MyApp::Schema::Result::Cookie;
    use base qw/DBIx::Class::Core/;
    __PACKAGE__->load_components(qw/+Ix::DBIC::Result/);

    # register 'Cookie/bake' as a publicly accessible JMAP method, implemented
    # by the method cookie_bake
    sub published_method_map {
      return {
        'Cookie/bake' => 'cookie_bake',
      };
    }

    sub cookie_bake ($self, $ctx, $arg) { ... }

=method ix_query_filter_map

Required for query-enabled rclasses. This should return a hashref that defines
how your rclass behaves when filtering. Its keys are properties that are valid
for filtering, and its values are hashrefs defining the filter.

Say your method returned the following hashref:

    {
      batch => { required => 1 },
      types => {
        cond_builder => sub ($types) {
          return { type => $types },
        },
        differ => sub ($entity, $filter) {
          # This difffers if its type is not in filter list
          my $found = first { ! differ($entity->type, $_) } @$filter;

          return $found ? 0 : 1;
        },
      },
    }

This means that your rclass would allow the keys 'batch' and 'types' for
filtering. You can provide a C<required> key to require a particular filter. If
C<cond_builder> is provided, its return value is used to pass into a DBIC
C<search> argument. If you don't provide C<cond_builder> (as we do here with
'batch'), the search will use simple string equality.

Finally, you can provide a C<differ> key that controls the way elements are
compared in ix_query_changes. If you don't provide one, C<differ()> from
L<Ix::Util> is used. If you do provide one, it should be a coderef, which is
passed the database entity and the relevant argument from the client-provided
filter. It should return true if the two values differ (by some arbitrary
definition), and false if they should be considered equivalent.

=method ix_query_sort_map

Required for query-enabled rclasses. This should return a hashref that defines
how your rclass sorts when filtering. Its keys are properties that are valid for
sorting, and its values are hashrefs defining each sort.

Say your method returned the following hashref:

  {
    created     => { },
    layer_count => { },
    type        => { sort_by => \"
      CASE me.type
        WHEN 'chocolate' THEN 1
        WHEN 'marble'    THEN 2
        ELSE                  3
      END
    "},
  }

This means that your rclass would allow the keys 'created', 'layer_count', and
'type' for filtering. If you do not provide a C<sort_by> key, sorting is done by
whatever means the database chooses. If you do provide one, it's passed into the
C<order_by> attribute to a DBIC C<search> method.

=method ix_query_joins

For query-enabled rclasses, an optional list of tables to join for querying.
If provided, this should return a list. (Its return value is eventually passed
in the C<join> attribute to a DBIC C<search> method.)

=method ix_update_state_string_field

This defaults to C<modSeqChanged>, but if you like, you can override it to use
some other field to define your rclass's state string.

=cut

sub ix_update_state_string_field { 'modSeqChanged' }

=method ix_state_string($state)

This is passed the context's C<state> attribute (an L<Ix::AccountState> object),
and returns the state string for this object type. You can override it if you
don't want to use the default integer state strings.

=cut

sub ix_state_string ($self, $state) {
  return $state->state_for( $self->ix_type_key ) . "";
}

=method ix_get_extra_search($ctx, $arg)

Extra search arguments run during Foo/get operations.  If provided, this should
return two hashrefs suitable for passing to DBIC's C<search> method: the first
of search conditions, the second of search attributes.

=cut

sub ix_get_extra_search ($self, $ctx, $arg = {}) {
  return (
    {},
    {},
  );
}

=method ix_update_extra_search($ctx, $arg)

Extra search arguments run during Foo/set#update operations.  If provided, this
should return two hashrefs suitable for passing to DBIC's C<search> method: the
first of search conditions, the second of search attributes.

=cut

sub ix_update_extra_search ($self, $ctx, $arg) {
  my $since = $arg->{since};

  return (
    {
      'me.modSeqChanged' => { '>' => $since },

      # Don't include rows that were created and deleted after
      # our current state
      -or => [
        'me.isActive' => 1,
        'me.modSeqCreated' => { '<=' => $since },
      ],
    },
    {},
  );
}

=method ix_update_extra_select

Extra fields to select when running Foo/set#update searches. This is useful if
your hook methods need to have access to additional data that wasn't necessarily
provided by the client. If provided, should return an arrayref.

=cut

sub ix_update_extra_select {
  return [];
}

=method ix_highest_state($since, $rows)

Returns the highest state for a given set of rows.

=cut

sub ix_highest_state ($self, $since, $rows) {
  my $state_string_field = $self->ix_update_state_string_field;
  return $rows->[-1]{$state_string_field};
}

=method ix_item_created_since($item, $since)

Returns whether or not C<$item> was created after C<$since>. (You may need to
override this method if you're not using the default state strings.)

=cut

sub ix_item_created_since ($self, $item, $since) {
  return $item->{modSeqCreated} > $since;
}

=method ix_compare_state($since, $state)

Used internally by L<Ix::DBIC::ResultSet> to determine how to act for
Foo/changes.  Returns an L<Ix::StateComparison> object.

=cut

sub ix_compare_state ($self, $since, $state) {
  my $high_ms = $state->highest_modseq_for($self->ix_type_key);
  my $low_ms  = $state->lowest_modseq_for($self->ix_type_key);

  state $bad_state = Ix::Validators::state();

  if ($bad_state->($since)) {
    return Ix::StateComparison->bogus;
  }

  if ($high_ms  < $since) { return Ix::StateComparison->bogus;   }
  if ($low_ms   > $since) { return Ix::StateComparison->resync;  }
  if ($high_ms == $since) { return Ix::StateComparison->in_sync; }

  return Ix::StateComparison->okay;
}

=method ix_create_base_state

This method is called when you create a new account (i.e., an
C<Ix::DBIC::Result> where C<ix_is_account_base> is true). After you create an
account, you must call this method to insert the appropriate rows into the
states table (so that it can be tracked by C<Ix::AccountState>.

=cut

sub ix_create_base_state ($self) {
  unless ($self->ix_is_account_base) {
    require Carp;
    Carp::croak("ix_create_base_state(): $self is not a base account type!");
  }

  my $schema = $self->result_source->schema;

  my $source_reg = $schema->source_registrations;

  for my $moniker (keys %$source_reg) {
    my $rclass = $source_reg->{$moniker}->result_class;
    next unless $rclass->can('ix_account_type');

    if ($rclass->ix_account_type eq $self->ix_account_type) {
      $schema->resultset('State')->create({
        accountId     => $self->accountId,
        type          => $rclass->ix_type_key,
        highestModSeq => 0,
        lowestModSeq  => 0,
      });
    }
  }
}

1;
