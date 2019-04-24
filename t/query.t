use 5.20.0;
use warnings;
use utf8;
use experimental qw(lexical_subs signatures postderef refaliasing);

use lib 't/lib';

use Bakesale;
use Bakesale::App;
use Bakesale::Schema;
use JSON::MaybeXS ();
use Test::Deep;
use Test::Deep::JType;
use Test::More;
use Test::Abortable 'subtest';
use Unicode::Normalize;

sub mkref ($result_of, $name, $path) {
  return { resultOf => $result_of, name => $name, path => $path }
}

my ($app, $jmap_tester) = Bakesale::Test->new_test_app_and_tester;
\my %account = Bakesale::Test->load_trivial_account($app->processor->schema_connection);

$jmap_tester->ua->set_cookie({
  api_uri => $jmap_tester->api_uri,
  name    => 'bakesaleUserId',
  value   => $account{users}{rjbs},
});

# Create some recipes
my $res = $jmap_tester->request([
  [
    'CakeRecipe/set' => {
      create => {
        secret1 => {
          type          => 'secret1',
          avg_review    => 0,
          is_delicious  => jtrue,
        },
        secret2 => {
          type          => 'secret2',
          avg_review    => 0,
          is_delicious  => jfalse,
        },
      },
    },
  ],
]);

my $secret1_recipe_id = $res->single_sentence->as_set->created_id('secret1');
my $secret2_recipe_id = $res->single_sentence->as_set->created_id('secret2');

ok($secret1_recipe_id, 'created a chocolate recipe');
ok($secret2_recipe_id, 'created a marble recipe');

{
  # Try to Cake/query & Cake/queryChanges - should work but return nothing
  my $res = $jmap_tester->request([
    [
      'Cake/query' => {
        filter => {
          recipeId => $secret1_recipe_id,
        },
        sort => [{ property => 'created', isAscending => jtrue }],
      },
    ],
  ]);

  jcmp_deeply(
    $res->single_sentence->arguments,
    superhashof({
      ids        => [],
      queryState => 0,
      total      => 0,
    }),
    "ix_query works with no state rows"
  );

  $res = $jmap_tester->request([
    [
      'Cake/queryChanges' => {
        filter => {
          recipeId => $secret1_recipe_id,
        },
        sort => [{ property => 'created', isAscending => jtrue }],
        sinceQueryState => 0,
      },
    ],
  ]);

  jcmp_deeply(
    $res->single_sentence->arguments,
    superhashof({
      added    => [],
      removed  => [],
      total    => 0,
      newQueryState => 0,
      oldQueryState => 0,
    }),
    "ix_query_changes works with no state rows"
  );
}

# Now create a few cakes under each one
$res = $jmap_tester->request([
  [
    'Cake/set' => {
      create => {
        'chocolate1' => {
          type => 'chocolate', layer_count => 1, recipeId => $secret1_recipe_id,
        },
        'chocolate2' => {
          type => 'chocolate', layer_count => 3, recipeId => $secret1_recipe_id,
        },
        'pb1' => {
          type => 'peanut butter', layer_count => 3, recipeId => $secret1_recipe_id,
        },
        'marble1' => {
          type => 'marble', layer_count => 1, recipeId => $secret2_recipe_id,
        },
        'marble2' => {
          type => 'marble', layer_count => 3, recipeId => $secret2_recipe_id,
        },
        'lemon1' => {
          type => 'lemon', layer_count => 3, recipeId => $secret2_recipe_id,
        },
      },
    },
  ]
]);

my %cake_id;
for my $k (qw(chocolate1 chocolate2 pb1 marble1 marble2 lemon1)) {
  ok($cake_id{$k} = $res->sentence(0)->as_set->created_id($k), "created cake $k");
}

my $state = $res->sentence(0)->arguments->{newState};
ok(defined($state), 'got state') or diag explain $res->as_stripped_triples;
$state =~ s/-\d+//;

{
  # Basic Filter/sort tests
  # Two chocolate cakes should come first in order of ids, peanut butter
  # after
  $res = $jmap_tester->request([
    [
      'Cake/query' => {
        filter => {
          recipeId => $secret1_recipe_id,
        },
        sort => [{ property => 'type', isAscending => jtrue }],
      },
    ],
  ]);

  jcmp_deeply(
    $res->single_sentence->arguments,
    {
      accountId => ignore(),
      ids => [
        ( sort { $a cmp $b } @cake_id{qw(chocolate1 chocolate2)} ),
        $cake_id{pb1},
      ],
      'filter' => {
        'recipeId' => $secret1_recipe_id
      },
      'canCalculateChanges' => jtrue,
      'position' => 0,
      'sort' => [
        { property => 'type', isAscending => jtrue },
      ],
      'queryState' => $state,
      'total' => 3,
    },
    "Cake/query with sort+filter looks right"
  ) or diag explain $res->as_stripped_triples;

  # Same but reverse sort
  $res = $jmap_tester->request([
    [
      'Cake/query' => {
        filter => {
          recipeId => $secret1_recipe_id,
        },
        sort => [{ property => 'type', isAscending => jfalse }],
      },
    ],
  ]);

  jcmp_deeply(
    $res->single_sentence->arguments,
    {
      accountId => ignore(),
      ids => [
        $cake_id{pb1},
        # These will still be in .id asc order since we always sort on id
        # last to ensure consistency between results when all other sorts
        # leave adjacent rows that could be ordered differently
        ( sort { $a cmp $b } @cake_id{qw(chocolate1 chocolate2)} ),
      ],
      'filter' => {
        'recipeId' => $secret1_recipe_id
      },
      'canCalculateChanges' => jtrue,
      'position' => 0,
      'sort' => [
        { property => 'type', isAscending => jfalse }
      ],
      'queryState' => $state,
      'total' => 3,
    },
    "Cake/query with sort+filter looks right (reverse sort)"
  );
}

subtest "custom condition builder" => sub {
  # We have two recipes.  For each recipe, we have three cakes, and one of them
  # is single-layer.
  for my $recipe_id ($secret1_recipe_id, $secret2_recipe_id) {
    my $total_res = $jmap_tester->request([
      [ 'Cake/query' => { filter => { recipeId => $recipe_id } } ],
    ]);

    jcmp_deeply(
      $total_res->single_sentence('Cake/query')->arguments,
      superhashof({ total => jnum(3) }),
      "there! are! THREE! cakes!",
    );

    my $short_res = $jmap_tester->request([
      [ 'Cake/query' => { filter => {
          recipeId => $recipe_id, isLayered => jfalse
        } }
      ],
    ]);

    jcmp_deeply(
      $short_res->single_sentence('Cake/query')->arguments,
      superhashof({ total => jnum(1) }),
      "...one cake is single-layered",
    );

    my $tall_res = $jmap_tester->request([
      [ 'Cake/query' => { filter => {
          recipeId => $recipe_id, isLayered => jtrue
        } }
      ],
    ]);

    jcmp_deeply(
      $tall_res->single_sentence('Cake/query')->arguments,
      superhashof({ total => jnum(2) }),
      "...two cakes are multi-layered",
    );
  }
};

{
  # Ensure multiple sort orders work. First, sort by layer_count asc
  # then layer_count desc
  $res = $jmap_tester->request([
    [
      'Cake/query' => {
        filter => {
          recipeId => $secret1_recipe_id,
        },
        sort => [
          { property => 'type',        isAscending => jtrue },
          { property => 'layer_count', isAscending => jtrue },
        ],
      },
    ],
  ]);

  jcmp_deeply(
    $res->single_sentence->arguments,
    {
      accountId => ignore(),
      'ids' => [
        @cake_id{qw(chocolate1 chocolate2 pb1)},
      ],
      'filter' => {
        'recipeId' => $secret1_recipe_id
      },
      'canCalculateChanges' => jtrue,
      'position' => 0,
      'sort' => [
        { property => 'type',        isAscending => jtrue },
        { property => 'layer_count', isAscending => jtrue },
      ],
      'queryState' => $state,
      'total' => 3,
    },
    "Cake/query with multi-sort + filter looks right"
  );

  $res = $jmap_tester->request([
    [
      'Cake/query' => {
        filter => {
          recipeId => $secret1_recipe_id,
        },
        sort => [
          { property => 'type',        isAscending => jtrue },
          { property => 'layer_count', isAscending => jfalse },
        ],
      },
    ],
  ]);

  jcmp_deeply(
    $res->single_sentence->arguments,
    {
      accountId => ignore(),
      'ids' => [
        @cake_id{qw(chocolate2 chocolate1 pb1)},
      ],
      'filter' => {
        'recipeId' => $secret1_recipe_id
      },
      'canCalculateChanges' => jtrue,
      'position' => 0,
      'sort' => [
        { property => 'type',        isAscending => jtrue },
        { property => 'layer_count', isAscending => jfalse },
      ],
      'queryState' => $state,
      'total' => 3,
    },
    "Cake/query with multi-sort + filter looks right"
  );
}

{
  # 2nd filter, no sort specified
  $res = $jmap_tester->request([
    [
      'Cake/query' => {
        filter => {
          recipeId => $secret1_recipe_id,
          type     => 'peanut butter',
        },
      },
    ],
  ]);

  jcmp_deeply(
    $res->single_sentence->arguments,
    {
      accountId => ignore(),
      'ids' => [
        @cake_id{qw(pb1)},
      ],
      'filter' => {
        'recipeId' => $secret1_recipe_id,
        'type'     => 'peanut butter',
      },
      'canCalculateChanges' => jtrue,
      'position' => 0,
      'sort' => undef,
      'queryState' => $state,
      'total' => 1,
    },
    "Cake/query with no sort, multi-filter"
  );
}

{
  # Pagination
  my $p = 0;

  for my $cid (sort { $a cmp $b } @cake_id{qw(chocolate1 chocolate2 pb1)}) {
    $res = $jmap_tester->request([
      [
        'Cake/query' => {
          filter => {
            recipeId => $secret1_recipe_id,
          },
          sort => [],
          position => $p++,
          limit    => 1,
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        accountId => ignore(),
        'ids' => [
          $cid,
        ],
        'filter' => {
          'recipeId' => $secret1_recipe_id
        },
        'canCalculateChanges' => jtrue,
        'position' => $p-1,
        'sort' => [],
        'queryState' => $state,
        'total' => 3,
      },
      "Cake/query with limit 1, position $p looks right (got cake $cid)"
    );
  }
}

{
  # backrefs (on old-style jmap: was fetchCakes)
  $res = $jmap_tester->request([
    [
      'Cake/query' => {
        filter => {
          recipeId   => $secret1_recipe_id,
          type       => 'peanut butter',
        },
      },
      'a',
    ],
    [
      'Cake/get' => {
        '#ids' => mkref(qw( a Cake/query /ids)),
      },
    ],
  ]);

  jcmp_deeply(
    $res->sentence(0)->arguments,
    {
      accountId => ignore(),
      'ids' => [
        @cake_id{qw(pb1)},
      ],
      'filter' => {
        'recipeId' => $secret1_recipe_id,
        'type'     => 'peanut butter',
      },
      'canCalculateChanges' => jtrue,
      'position' => 0,
      'sort' => undef,
      'queryState' => $state,
      'total' => 1,
    },
    "'Cake/query' with backrefs"
  ) or diag explain $res->as_stripped_triples;

  jcmp_deeply(
    $res->sentence(1)->arguments->{list},
    [
      superhashof({
        id => $cake_id{pb1},
        type => 'peanut butter',
      }),
    ],
    "got cake back with backrefs"
  ) or diag explain $res->as_stripped_triples;

  # Provide both
  $res = $jmap_tester->request([
    [
      'Cake/query' => {
        filter => {
          recipeId   => $secret1_recipe_id,
          type       => 'peanut butter',
        },
      },
      'a',
    ],
    [ 'Cake/get'       => { '#ids' => mkref(qw( a Cake/query /ids )) }, 'b' ],
    [ 'CakeRecipe/get' => { ids    => [ $secret1_recipe_id ]         }, 'c' ],
  ]);

  jcmp_deeply(
    $res->sentence(0)->arguments,
    {
      accountId => ignore(),
      'ids' => [
        @cake_id{qw(pb1)},
      ],
      'filter' => {
        'recipeId' => $secret1_recipe_id,
        'type'     => 'peanut butter',
      },
      'canCalculateChanges' => jtrue,
      'position' => 0,
      'sort' => undef,
      'queryState' => $state,
      'total' => 1,
    },
    "Cake/query with backrefs"
  ) or diag explain $res->as_stripped_triples;

  jcmp_deeply(
    $res->sentence(1)->arguments->{list},
    [
      superhashof({
        id => $cake_id{pb1},
        type => 'peanut butter',
      }),
    ],
    "got cake back with backref"
  ) or diag explain $res->as_stripped_triples;

  jcmp_deeply(
    $res->sentence(2)->arguments->{list},
    [
      superhashof({
        id => $secret1_recipe_id,
        type => 'secret1',
      }),
    ],
    "got recipe back with backrefs"
  ) or diag explain $res->as_stripped_triples;
}

{
  # bad forms. Missing required filter, bad second filter, missing
  # sort direction, bad sort
  $res = $jmap_tester->request([
    [
      'Cake/query' => {
        filter => {
          fake => 'not a real field',
        },
        sort => [
          { property => 'type' },   # this is fine; defaults to ascending
          { property => 'fake', isAscending => jtrue },
          { property => 'fake', isAscending => jtrue, bad => 'foo' },
          { property => 'fake', bad => 'foo' },
        ]
      },
    ],
  ]);

  jcmp_deeply(
    $res->single_sentence->arguments,
    {
      'type' => 'invalidArguments',
      'description' => 'Invalid arguments',
      'invalidFilters' => {
        'fake'     => 'unknown filter field',
        'recipeId' => 'required filter missing',
      },
      'invalidSorts' => [
        "unknown sort field 'fake'",
        "invalid sort format: unknown arguments [bad]",
        "invalid sort format: unknown arguments [bad]",
      ],
    },
    "bad /query forms detected",
  ) or diag explain $res->as_stripped_triples;
}

{
  # Delete a cake, ensure it doesn't come back in list
  $res = $jmap_tester->request([
    [
      'Cake/set' => {
        destroy => [ $cake_id{chocolate1} ],
      },
    ],
  ]);

  jcmp_deeply(
    [ $res->single_sentence->as_set->destroyed_ids() ],
    [ $cake_id{chocolate1}, ],
    'ate a cake'
  );

  $state++;

  $res = $jmap_tester->request([
    [
      'Cake/query' => {
        filter => {
          recipeId => $secret1_recipe_id,
        },
        sort => [{ property => 'type', isAscending => jtrue }],
      },
    ],
  ]);

  jcmp_deeply(
    $res->single_sentence->arguments,
    {
      accountId => ignore(),
      'ids' => [
        @cake_id{qw(chocolate2 pb1)},
      ],
      'filter' => {
        'recipeId' => $secret1_recipe_id
      },
      'canCalculateChanges' => jtrue,
      'position' => 0,
      'sort' => [
        { property => 'type', isAscending => jtrue },
      ],
      'queryState' => $state,
      'total' => 2,
    },
    "Cake/query doesn't show destroyed cakes"
  );
}

{
  # _updates. We should see two cake adds (not three, since one was
  # deleted at the end state so why bother showing the addition?
  $res = $jmap_tester->request([
    [
      'Cake/queryChanges' => {
        filter => {
          recipeId => $secret1_recipe_id,
        },
        sort => [{ property => 'type', isAscending => jtrue }],
        sinceQueryState => $state - 2,
      },
    ],
  ]);

  jcmp_deeply(
    $res->single_sentence->arguments,
    {
      accountId => ignore(),
      'added' => [
        {
          'id' => $cake_id{chocolate2},
          'index' => 0,
        },
        {
          'id' => $cake_id{pb1},
          'index' => 1,
        }
      ],
      'filter' => {
        'recipeId' => $secret1_recipe_id,
      },
      'newQueryState' => jstr($state),
      'oldQueryState' => jstr($state-2),
      'removed' => [],
      'sort' => [
        { property => 'type', isAscending => jtrue },
      ],
      'total' => 2
    },
    "Cake/queryChanges looks right for added cakes"
  ) or diag explain $res->as_stripped_triples;

  # Now try from state-1, should show removal
  $res = $jmap_tester->request([
    [
      'Cake/queryChanges' => {
        filter => {
          recipeId => $secret1_recipe_id,
        },
        sort => [{ property => 'type', isAscending => jtrue }],
        sinceQueryState => $state - 1,
      },
    ],
  ]);

  jcmp_deeply(
    $res->single_sentence->arguments,
    {
      accountId => ignore(),
      'added' => [],
      'filter' => {
        'recipeId' => $secret1_recipe_id,
      },
      'newQueryState' => jstr($state),
      'oldQueryState' => jstr($state-1),
      'removed' => [
        $cake_id{chocolate1},
      ],
      sort => [{ property => 'type', isAscending => jtrue }],
      'total' => 2
    },
    "Cake/queryChanges looks right for removed cake"
  ) or diag explain $res->as_stripped_triples;
}

{
  # No sinceState
  $res = $jmap_tester->request([
    [
      'Cake/queryChanges' => {
        filter => {
          recipeId => $secret1_recipe_id,
        },
        sort => [{ property => 'type', isAscending => jtrue }],
      },
    ],
  ]);

  jcmp_deeply(
    $res->single_sentence->arguments,
    {
      'type' => 'invalidArguments',
      'description' => 'no sinceQueryState given',
    },
    "No sinceQueryState - correct error",
  );
}

{
  # sinceQueryState up to date
  $res = $jmap_tester->request([
    [
      'Cake/queryChanges' => {
        filter => {
          recipeId => $secret1_recipe_id,
        },
        sort => [{ property => 'type', isAscending => jtrue }],
        sinceQueryState => $state,
      },
    ],
  ]);

  jcmp_deeply(
    $res->single_sentence->arguments,
    {
      accountId => ignore(),
      'added' => [],
      'filter' => {
        'recipeId' => $secret1_recipe_id,
      },
      'newQueryState' => jstr($state),
      'oldQueryState' => jstr($state),
      'removed' => [],
      'sort'    => [{ property => 'type', isAscending => jtrue }],
      'total' => 2
    },
    "Cake/queryChanges looks right for no changes"
  );
}

{
  # Update a cake
  $res = $jmap_tester->request([
    [
      'Cake/set' => {
        update => {
          $cake_id{pb1} => { layer_count => 9 },
        },
      },
    ],
  ]);

  jcmp_deeply(
    [ $res->single_sentence->as_set->updated_ids() ],
    [ "$cake_id{pb1}", ],
    'upgraded a cake'
  ) or diag explain $res->as_stripped_triples;

  $state++;
}

# And now check state
{
  $res = $jmap_tester->request([
    [
      'Cake/queryChanges' => {
        filter => {
          recipeId => $secret1_recipe_id,
        },
        sort => [{ property => 'type', isAscending => jtrue }],
        sinceQueryState => $state-1,
      },
    ],
  ]);

  # a remove/add will appear for the same cake id
  jcmp_deeply(
    $res->single_sentence->arguments,
    {
      accountId => ignore(),
      'added' => [
        {
          'id' => $cake_id{pb1},
          'index' => 1,
        },
      ],
      'filter' => {
        'recipeId' => $secret1_recipe_id,
      },
      'newQueryState' => $state,
      'oldQueryState' => $state-1,
      'removed' => [
        $cake_id{pb1},
      ],
      'sort'  => [{ property => 'type', isAscending => jtrue }],
      'total' => 2
    },
    "Cake/queryChanges looks right for no changes"
  );
}

{
  # Hooks
  $res = $jmap_tester->request([
    [
      'Cake/query' => {
        filter => {
          recipeId => 'secret',
        },
      },
    ],
    [
      'Cake/queryChanges' => {
        filter => {
          recipeId => 'secret',
        },
        sinceQueryState => $state-1,
      },
    ],
  ]);

  jcmp_deeply(
    $res->sentence(0)->arguments,
    {
      type        => 'invalidArguments',
      description => "That recipe is too secret for you",
    },
    "Cake/query ix_query_check hook works"
  );

  jcmp_deeply(
    $res->sentence(1)->arguments,
    {
      type        => 'invalidArguments',
      description => "That recipe is way too secret for you",
    },
    "Cake/queryChanges ix_query_changes_check hook works"
  );
}

{
  # backref properties
  $res = $jmap_tester->request([
    [
      'Cake/query' => {
        filter => {
          recipeId   => $secret1_recipe_id,
          type       => 'peanut butter',
        },
      },
      'a'
    ],
    [
      'Cake/get' => {
        properties => [ 'type', 'baked_at' ],
        '#ids' => mkref(qw( a Cake/query /ids )),
      },
      'b',
    ]
  ]);

  jcmp_deeply(
    $res->sentence(0)->arguments,
    {
      accountId => ignore(),
      'ids' => [
        @cake_id{qw(pb1)},
      ],
      'filter' => {
        'recipeId' => $secret1_recipe_id,
        'type'     => 'peanut butter',
      },
      'canCalculateChanges' => JSON::MaybeXS::JSON->true,
      'position' => 0,
      'sort' => undef,
      'queryState' => $state,
      'total' => 1,
    },
    "Cake/query with properties in backref"
  ) or diag explain $res->as_stripped_triples;

  jcmp_deeply(
    $res->sentence(1)->arguments->{list},
    [
      {
        id       => $cake_id{pb1},
        type     => 'peanut butter',
        baked_at => ignore(),
      },
    ],
    "got cake back with backrefs"
  ) or diag explain $res->as_stripped_triples;

  # backrefs (on old-style jmap: was fetchOtherFooProperties)
  $res = $jmap_tester->request([
    [
      'Cake/query' => {
        filter => {
          recipeId   => $secret1_recipe_id,
          type       => 'peanut butter',
        },
      },
    ],
    [
      'CakeRecipe/get' => {
        ids => [ $secret1_recipe_id ],
        properties => [ 'is_delicious' ],
      },
    ],

  ]);

  jcmp_deeply(
    $res->sentence(0)->arguments,
    {
      accountId => ignore(),
      'ids' => [
        @cake_id{qw(pb1)},
      ],
      'filter' => {
        'recipeId' => $secret1_recipe_id,
        'type'     => 'peanut butter',
      },
      'canCalculateChanges' => JSON::MaybeXS::JSON->true,
      'position' => 0,
      'sort' => undef,
      'queryState' => $state,
      'total' => 1,
    },
    "Cake/query with explicit CakeRecipe/get"
  ) or diag explain $res->as_stripped_triples;

  jcmp_deeply(
    $res->sentence(1)->arguments->{list},
    [
      {
        id           => $secret1_recipe_id,
        is_delicious => jtrue,
      },
    ],
    "got recipe back with explicit get"
  ) or diag explain $res->as_stripped_triples;
}

subtest 'custom differ, and no required filters' => sub {
  # Ensure our custom differ works. Also ensure that if we don't have
  # required filters, we limit our updates list to those that could
  # have changed, not the entire table

  my @states;

  my %cl_args = (
    filter => {
      types => [ 'oatmeal stout', 'oreo stout' ],
      batch => $Bakesale::Schema::Result::Cookie::next_batch,
    },
    sort   => [{ property => 'type', isAscending => jtrue }],
  );

  {
    # Get base state
    my $cl_res = $jmap_tester->request([[
      'Cookie/query' => \%cl_args,
    ]]);

    jcmp_deeply(
      $cl_res->single_sentence->arguments,
      superhashof({
        ids => [],
      }),
      "No cookies match our filter yet"
    ) or diag explain $cl_res->as_stripped_triples;

    my $base_state = $cl_res->single_sentence->arguments->{queryState};
    ok(defined $base_state, 'got cookie state');

    push @states, $base_state;
  }

  my ($oatmeal, $oreo, $peanut);

  {
    # Create some weird cookies
    my $set_cookies = $jmap_tester->request([
      [ 'Cookie/set' => { create => {
        oatmeal1 => { type => 'oatmeal stout' },
        oreo1    => { type => 'oreo stout'    },
        peanut1  => { type => 'peanut stout'  },
      } } ],
    ]);

    my $set = $set_cookies->sentence(0)->as_set;

    is(
      $set->created_ids,
      3,
      'created 3 cookies'
    ) or diag explain $set_cookies->as_stripped_triples;

    $oatmeal = $set->created_id('oatmeal1') . "";
    $oreo = $set->created_id('oreo1') . "";
    $peanut = $set->created_id('peanut1') . "";

    # Verify
    my $clu_res = $jmap_tester->request([[
      'Cookie/queryChanges' => {
        %cl_args,
        sinceQueryState => $states[0],
      },
    ]]);

    jcmp_deeply(
      $clu_res->single_sentence->arguments,
      superhashof({
        added => [
          {
            index => 0,
            id => $oatmeal,
          }, {
            index => 1,
            id => $oreo,
          }
        ],
        removed => [ ],
      }),
      "Got two cookies out of three"
    ) or diag explain $clu_res->as_stripped_triples;

    my $state = $clu_res->single_sentence->arguments->{newQueryState};
    ok(defined $state, 'got next cookie state')
      or diag explain $clu_res->as_stripped_triples;

    cmp_ok($state, '>', $states[-1], 'cookie state increased');

    push @states, $state;
  }

  {
    # Change two cookies, one so it no longer matches the filter, another
    # so it now matches the filter
    my $upd_res = $jmap_tester->request([[
      'Cookie/set' => {
        update => {
          $oatmeal => { type => 'banana' },
          $peanut  => { type => 'oatmeal stout' },
        },
      },
    ]]);

    is(
      $upd_res->single_sentence->as_set->updated_ids,
      2,
      'updated the type of two cookies'
    );

    # Verify
    my $clu_res = $jmap_tester->request([[
      'Cookie/queryChanges' => {
        %cl_args,
        sinceQueryState => $states[-1],
      },
    ]]);

    jcmp_deeply(
      $clu_res->single_sentence->arguments,
      superhashof({
        added => [
          {
            index => 0,
            id => $peanut,
          },
        ],
        removed => [
          $oatmeal,
          $peanut # Spurious remove, but spec says that's okay
        ],
      }),
      "Correctly reported addition of 1 cookie and removal of another"
    ) or diag explain $clu_res->as_stripped_triples;
  }
};

subtest "filters on joined tables" => sub {
  subtest "filter matches" => sub {
    $res = $jmap_tester->request([
      [
        'Cake/query' => {
          filter => {
            'recipeId' => $secret1_recipe_id,
            'recipe.is_delicious' => jtrue,
          },
          sort => [{ property => 'type', isAscending => jtrue }],
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        accountId => ignore(),
        'ids' => [
          $cake_id{chocolate2},
          $cake_id{pb1},
        ],
        'filter' => {
          'recipeId' => $secret1_recipe_id,
          'recipe.is_delicious' => jtrue,

        },
        'canCalculateChanges' => jtrue,
        'position' => 0,
        'sort'  => [{ property => 'type', isAscending => jtrue }],
        'queryState' => $state,
        'total' => 2,
      },
      "Cake/query with filter on join with match looks right"
    ) or diag explain $res->as_stripped_triples;

    $res = $jmap_tester->request([
      [
        'Cake/queryChanges' => {
          filter => {
            recipeId => $secret1_recipe_id,
            'recipe.is_delicious' => jtrue,
          },
          sort => [{ property => 'type', isAscending => jtrue }],
          sinceQueryState => $state - 3,
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        accountId => ignore(),
        'added' => [
          {
            'id' => $cake_id{chocolate2},
            'index' => 0,
          },
          {
            'id' => $cake_id{pb1},
            'index' => 1,
          }
        ],
        'filter' => {
          'recipeId' => $secret1_recipe_id,
          'recipe.is_delicious' => jtrue,
        },
        'newQueryState' => $state,
        'oldQueryState' => $state - 3,
        'removed' => [],
        'sort'  => [{ property => 'type', isAscending => jtrue }],
        'total' => 2
      },
      "Cake/queryChanges with filter on join with match looks right"
    ) or diag explain $res->as_stripped_triples;
  };

  subtest "filter doesn't match" => sub {
    $res = $jmap_tester->request([
      [
        'Cake/query' => {
          filter => {
            'recipeId' => $secret1_recipe_id,
            'recipe.is_delicious' => jfalse, # But these are delicious!
          },
          sort => [{ property => 'type', isAscending => jtrue }],
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        accountId => ignore(),
        'ids' => [],
        'filter' => {
          'recipeId' => $secret1_recipe_id,
          'recipe.is_delicious' => jfalse,
        },
        'canCalculateChanges' => jtrue,
        'position' => 0,
        'sort' => [
          { property => 'type', isAscending => jtrue },
        ],
        'queryState' => $state,
        'total' => 0,
      },
      "Cake/query with filter on join no match looks right"
    ) or diag explain $res->as_stripped_triples;

    $res = $jmap_tester->request([
      [
        'Cake/queryChanges' => {
          filter => {
            recipeId => $secret1_recipe_id,
            'recipe.is_delicious' => jfalse,
          },
          sort => [{ property => 'type', isAscending => jtrue }],
          sinceQueryState => $state - 3,
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      superhashof({
        added    => [],
        removed  => [],
        total    => 0,
        newQueryState => $state,
        oldQueryState => $state - 3,
        filter => {
          recipeId => $secret1_recipe_id,
          'recipe.is_delicious' => jfalse,
        },
        total => 0,
      }),
      "Cake/queryChanges with filter on join no match looks right"
    );
  };
};

subtest "differ boolean comparison when db row is false" => sub {
  # The above test ensured we matched booleans properly when the DB
  # value is true and the filter is true/false, this test ensures
  # we handle things properly when the DB value is false and the filter
  # is true/false
  subtest "filter is false" => sub {
    $res = $jmap_tester->request([
      [
        'Cake/queryChanges' => {
          filter => {
            recipeId => $secret2_recipe_id,
            'recipe.is_delicious' => jfalse,
          },
          sort => [{ property => 'type', isAscending => jtrue }],
          sinceQueryState => $state - 3,
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        accountId => ignore(),
        'added' => set(
          superhashof({
            'id' => $cake_id{marble1},
          }),
          superhashof({
            'id' => $cake_id{marble2},
            'index'  => ignore(),
          }),
          superhashof({
            'id' => $cake_id{lemon1},
            'index'  => ignore(),
          }),
        ),
        'filter' => {
          'recipeId' => $secret2_recipe_id,
          'recipe.is_delicious' => jfalse,
        },
        'newQueryState' => $state,
        'oldQueryState' => $state - 3,
        'removed' => [],
        'sort' => [
          { property => 'type', isAscending => jtrue },
        ],
        'total' => 3,
      },
      "Cake/queryChanges with filter on join with match looks right"
    ) or diag explain $res->as_stripped_triples;
  };

  subtest "filter is true" => sub {
    # Starting at state 0, the rows were added and removed, so
    # we should see no changes
    $res = $jmap_tester->request([
      [
        'Cake/queryChanges' => {
          filter => {
            recipeId => $secret2_recipe_id,
            'recipe.is_delicious' => jtrue,
          },
          sort => [{ property => 'type', isAscending => jtrue }],
          sinceQueryState => $state - 3,
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        accountId => ignore(),
        'added' => [],
        'filter' => {
          'recipeId' => $secret2_recipe_id,
          'recipe.is_delicious' => jtrue,
        },
        'newQueryState' => $state,
        'oldQueryState' => $state - 3,
        'removed' => [],
        'sort' => [
          { property => 'type', isAscending => jtrue },
        ],
        'total' => 0,
      },
      "Cake/queryChanges with filter on join with no match looks right"
    ) or diag explain $res->as_stripped_triples;

    # Now from the state where they were added, we should see removed
    $res = $jmap_tester->request([
      [
        'Cake/queryChanges' => {
          filter => {
            recipeId => $secret2_recipe_id,
            'recipe.is_delicious' => jtrue,
          },
          sort => [{ property => 'type', isAscending => jtrue }],
          sinceQueryState => $state - 2,
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        accountId => ignore(),
        'added' => [],
        'filter' => {
          'recipeId' => $secret2_recipe_id,
          'recipe.is_delicious' => jtrue,
        },
        'newQueryState' => $state,
        'oldQueryState' => $state - 2,
        'removed' => [],
        'sort' => [
          { property => 'type', isAscending => jtrue },
        ],
        'total' => 0,
      },
      "Cake/queryChanges with filter on join with no match looks right"
    ) or diag explain $res->as_stripped_triples;
  };
};

subtest "distinct rows only" => sub {
  # If a cake has many toppers it should still only come back once
  my $res = $jmap_tester->request([[ 'CakeTopper/set' => {
    create => {
      first  => { cakeId => $cake_id{pb1}, type => 'sprinkles' },
      second => { cakeId => $cake_id{pb1}, type => 'candles'   },
    },
  } ]]);

  is($res->single_sentence->as_set->created_ids, 2, 'created toppers');

  # This causes our generated SQL to allow for duplicate rows which
  # can happen in downstream consumers
  local $ENV{RECIPEID_NOT_REQUIRED} = 1;

  delete $cake_id{chocolate1};

  $res = $jmap_tester->request([
    [
      'Cake/query' => {
        sort => [{ property => 'id', isAscending => jtrue }],
      },
    ],
  ]);
  jcmp_deeply(
    $res->single_sentence->arguments,
    superhashof({
      ids => [
        sort { $a cmp $b } values %cake_id,
      ],
      total => 5,
    }),
    "no duplicates in Foo/query"
  ) or diag explain $res->as_stripped_triples;

  $res = $jmap_tester->request([
    [
      'Cake/queryChanges' => {
        sort => [{ property => 'id', isAscending => jtrue }],
        sinceQueryState => 0,
      },
    ],
  ]);
  jcmp_deeply(
    $res->single_sentence->arguments,
    superhashof({
      added => [
        map {;
          {
            index  => ignore(),
            id => $_
          },
        } sort { $a cmp $b } values %cake_id,
      ],
      total => 5,
    }),
    "no duplicates in Foo/queryChanges"
  ) or diag explain $res->as_stripped_triples;
};

subtest "tooManyChanges" => sub {
  subtest "Plenty of space for more changes" => sub {
    my $res = $jmap_tester->request([[
      'Cake/queryChanges' => {
        filter => { recipeId => $secret1_recipe_id, },
        sinceQueryState => 1,
        maxChanges => 100,
      },
    ]]);

    jcmp_deeply(
      $res->sentence(0)->arguments,
      superhashof({
        added => [ superhashof({ index => ignore() }) ],
        removed => [ ignore(), ignore() ],
      }),
      'got a good response, with both added/removed elements'
    ) or diag explain $res->as_stripped_triples;
  };

  subtest "Exact amount of changes" => sub {
    my $res = $jmap_tester->request([[
      'Cake/queryChanges' => {
        filter => { recipeId => $secret1_recipe_id, },
        sinceQueryState => 1,
        maxChanges => 3,
      },
    ]]);

    jcmp_deeply(
      $res->sentence(0)->arguments,
      superhashof({
        added => [ superhashof({ index => ignore() }) ],
        removed => [ ignore(), ignore() ],
      }),
      'got a good response, with both added/removed elements'
    );
  };

  subtest "Not enough room for all the changes" => sub {
    my $res = $jmap_tester->request([[
      'Cake/queryChanges' => {
        filter => { recipeId => $secret1_recipe_id, },
        sinceQueryState => 1,
        maxChanges => 2,
      },
    ]]);

    is(
      $res->sentence(0)->arguments->{type},
      'tooManyChanges',
      'got correct error'
    ) or diag explain $res->as_stripped_triples;
  };
};

subtest "custom cake differ" => sub {
  # Make sure we can get updates with this filter/custom differ
  my $res = $jmap_tester->request([
    [ 'Cake/queryChanges' => { filter => {
        recipeId => $secret1_recipe_id,
        isLayered             => jtrue,
        'recipe.is_delicious' => jtrue,
      }, sinceQueryState => 0 }
    ],
  ]);
  ok($res->http_response->is_success, 'call succeeded');
};

subtest "we do not promote undef sort or filter" => sub {
  for my $pair (
    [ '{}'    => {} ],
    [ 'null'  => undef ],
  ) {
    my ($desc, $value) = @$pair;
    subtest "filter non-promotion, filter = $desc" => sub {
      my $list_res = $jmap_tester->request([ [ 'Cookie/query' => { filter => $value } ] ]);
      my $list = $list_res->single_sentence('Cookie/query');

      jcmp_deeply($list->arguments->{filter}, $value, "Foo/query filter");

      my $state = $list->arguments->{queryState};

      my $listup_res = $jmap_tester->request([
        [ 'Cookie/queryChanges' => { sinceQueryState => $state, filter => $value } ]
      ]);

      my $listup = $listup_res->single_sentence('Cookie/queryChanges');

      jcmp_deeply($listup->arguments->{filter}, $value, "Foo/queryChanges filter");
    };
  }
};

$app->_shutdown;

done_testing;
