use strict;
use warnings;
use experimental qw(postderef signatures);
package Bakesale::Schema::Result::Cake;
use base qw/DBIx::Class::Core/;

use Ix::Validators qw(integer nonemptystr idstr);
use List::Util qw(max);

__PACKAGE__->load_components(qw/+Ix::DBIC::Result/);

__PACKAGE__->table('cakes');

__PACKAGE__->ix_add_columns;

__PACKAGE__->ix_add_properties(
  type        => { data_type => 'string',     },
  layer_count => { data_type => 'integer',  validator => integer(1, 10)  },
  baked_at    => { data_type => 'timestamptz', client_may_init => 0, client_may_update => 0 },
  recipeId    => {
    data_type    => 'idstr',
    xref_to      => 'CakeRecipe',
  },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
  recipe => 'Bakesale::Schema::Result::CakeRecipe',
  { 'foreign.id' => 'self.recipeId' },
);

__PACKAGE__->has_many(
  topper => 'Bakesale::Schema::Result::CakeTopper',
  { 'foreign.cakeId' => 'self.id' },
);

sub ix_type_key { 'Cake' }

sub ix_account_type { 'generic' }

sub ix_default_properties {
  return { baked_at => Ix::DateTime->now };
}

sub ix_get_check ($self, $ctx, $arg) {
  return if $arg->{ids};

  return $ctx->error(invalidArguments => {
    description => "required parameter 'ids' not present",
  });
}

sub ix_state_string ($self, $state) {
  return join q{-},
    $state->state_for($self->ix_type_key),
    $state->state_for('CakeRecipe');
}

sub ix_compare_state ($self, $since, $state) {
  my ($cake_since, $recipe_since) = split /-/, $since, 2;

  return Ix::StateComparison->bogus
    unless ($cake_since//'')    =~ /\A[0-9]+\z/
        && ($recipe_since//'')  =~ /\A[0-9]+\z/;

  my $cake_high   = $state->highest_modseq_for('Cake');
  my $recipe_high = $state->highest_modseq_for('CakeRecipe');

  my $cake_low    = $state->lowest_modseq_for('Cake');
  my $recipe_low  = $state->lowest_modseq_for('CakeRecipe');

  if ($cake_high < $cake_since || $recipe_high < $recipe_since) {
    return Ix::StateComparison->bogus;
  }

  if ($cake_low > $cake_since || $recipe_low > $recipe_since) {
    return Ix::StateComparison->resync;
  }

  if ($cake_high == $cake_since && $recipe_high == $recipe_since) {
    return Ix::StateComparison->in_sync;
  }

  return Ix::StateComparison->okay;
}

sub ix_update_state_string_field { 'jointModSeq' }

sub ix_item_created_since ($self, $item, $since) {
  my ($cake_since,  $recipe_since)  = split /-/, $since, 2;
  return $item->{modSeqCreated} > $cake_since;
}

sub ix_highest_state ($self, $since, $rows) {
  my ($cake_since,  $recipe_since)  = split /-/, $since, 2;

  my @r_updates = grep { $_->{jointModSeq} =~ /A-/ } @$rows;
  my @c_updates = grep { $_->{jointModSeq} =~ /B-/ } @$rows;

  my ($r_max) = @r_updates ? ($r_updates[-1]{jointModSeq} =~ /-([0-9]+)\z/) : $recipe_since;
  my ($c_max) = @c_updates ? ($c_updates[-1]{jointModSeq} =~ /-([0-9]+)\z/) : $cake_since;

  return "$c_max-$r_max";
}

sub ix_update_extra_search ($self, $ctx, $arg) {
  my $since = $arg->{since};

  my ($cake_since, $recipe_since) = split /-/, $since, 2;
  die "bogus state?!"
    unless ($cake_since//'')    =~ /\A[0-9]+\z/
        && ($recipe_since//'')  =~ /\A[0-9]+\z/;

  return(
    {
      -or => [
        'me.modSeqChanged'     => { '>' => $cake_since },
        'recipe.modSeqChanged' => { '>' => $recipe_since },
      ],
    },
    {
      '+columns' => {
        jointModSeq  => \[
          q{(CASE WHEN ? < recipe."modSeqChanged" THEN ('A-' || recipe."modSeqChanged") ELSE ('B-' || me."modSeqChanged") END)},
          $recipe_since,
        ],
      },
      join => [ 'recipe' ],

      order_by => [
        # Here, we only do A/B because we can't sort by A-n/B-n, because A-11
        # will sort before A-2.  On the other hand, we only use the jointModSeq
        # above for checking equality, not ordering, so it is appropriate to
        # use a string. -- rjbs, 2016-05-09
        \[
          q{(CASE WHEN ? < recipe."modSeqChanged" THEN 'A' ELSE 'B' END)},
          $recipe_since,
        ],
        \[
          q{(CASE WHEN ? < recipe."modSeqChanged" THEN recipe."modSeqChanged" ELSE me."modSeqChanged" END)},
          $recipe_since,
        ],
      ],
    },
  );
}

sub ix_created ($self, $ctx, $row) {
  return unless $row->type eq 'wedding';

  my $handler = $ctx->processor->handler_for('CakeTopper/set');

  my @results = $ctx->processor->$handler($ctx, {
    create => { $row->id => { cakeId => $row->id } },
  });

  for my $result (@results) {
    if ($result->{not_created} || $ENV{NO_CAKE_TOPPERS}) {
      die $ctx->internal_error("failed to create cake topper");
    }
  }

  return;
}

sub ix_postprocess_set ($self, $ctx, $results) {
  # Wedding cakes have toppers maybe!
  for my $result (@$results) {
    my @cake_ids = map { $_->{id} } values $result->{created}->%*;
    next unless @cake_ids;

    my @tids = $ctx->schema->resultset('CakeTopper')->search(
      { cakeId => [ @cake_ids ] },
    )->get_column('id')->all;
    next unless @tids;

    my $handler = $ctx->processor->handler_for('CakeTopper/get');
    push @$results, $ctx->processor->$handler($ctx, { ids => [ @tids ] });
  }

  return;
}

sub ix_query_sort_map {
  return {
    created     => { },
    id          => { },
    layer_count => { },
    baked_at    => { },
    recipeId    => { },
    type        => { sort_by => \"
      CASE me.type
        WHEN 'chocolate' THEN 1
        WHEN 'marble'    THEN 2
        ELSE                  3
      END
    "},
  };
}

sub ix_query_filter_map {
  return {
    recipeId    => {
      $ENV{RECIPEID_NOT_REQUIRED} ? () : (required => 1)
    },
    type        => { },
    layer_count => { },
    isLayered   => {
      cond_builder => sub ($is_layered) {
        return $is_layered ? { layer_count => { '>'  => 1 } }
                           : { layer_count => { '<=' => 1 } };
      },
      differ => sub ($entity, $filter) {
        # It differs if it's layered when isLayered is false,
        # or if it's not layered when isLayered is true
        my $diff;

        if ($filter) {
          $diff = 1 if $entity->layer_count <= 1;
        } else {
          $diff = 1 if $entity->layer_count > 1;
        }

        return $diff;
      },
    },
    'recipe.is_delicious' => { },
  };
}

sub ix_query_joins {
  return $ENV{RECIPEID_NOT_REQUIRED}
    ? ('topper')
    : ('recipe', 'topper');
}

sub ix_query_check ($self, $ctx, $arg, $search) {
  if (
       exists $arg->{filter}
    && exists $arg->{filter}{recipeId}
    && ($arg->{filter}{recipeId} // '') eq 'secret'
  ) {
    return $ctx->error(invalidArguments => {
      description => "That recipe is too secret for you",
    });
  }

  # Hide wedding cakes, they are secrets I guess...
  push $search->{filter}->{'-and'}->@*, { -or => [
    'me.type'     => { '!=', 'wedding', },
    'topper.type' => { '!=', 'wedding', },
  ] };

  return;
}

sub ix_query_changes_check ($self, $ctx, $arg, $search) {
  if (
       exists $arg->{filter}
    && exists $arg->{filter}{recipeId}
    && ($arg->{filter}{recipeId} // '') eq 'secret'
  ) {
    return $ctx->error(invalidArguments => {
      description => "That recipe is way too secret for you",
    });
  }

  # Hide wedding cakes, they are secrets I guess...
  push $search->{filter}->{'-and'}->@*, { -or => [
    'me.type'     => { '!=', 'wedding', },
    'topper.type' => { '!=', 'wedding', },
  ] };

  return;
}

sub ix_query_enabled { 1 }

sub ix_published_method_map {
  return {
    areCakesDelicious => 'are_cakes_delicious',
  };
}

sub are_cakes_delicious ($self, $ctx, $arg) {
  return Ix::Result::Generic->new({
    result_type       => 'cakesAreDelicious',
    result_arguments  => { howDelicious => 'very' },
  });
}

1;
