use 5.20.0;
use warnings;
use experimental qw(signatures postderef);

use lib 't/lib';

use Bakesale;
use Bakesale::App;
use Bakesale::Schema;
use Test::Deep;
use Test::Deep::JType;
use Test::More;
use Test::Abortable;

my ($app, $jmap_tester) = Bakesale::Test->new_test_app_and_tester;
my ($admin_id, $accountId) = Bakesale::Test->load_single_user($app->processor->schema_connection);
$jmap_tester->ua->set_cookie({
  api_uri => $jmap_tester->api_uri,
  name    => 'bakesaleUserId',
  value   => $admin_id,
});

# Set our base state to 1-1 so we can ensure we're told to resync if we
# pass in a sinceState lower than that (0-1 or 1-0 for example).
my $updated = $app->processor->schema_connection->resultset('State')->search({
  accountId => $accountId,
  type      => [ qw(Cake CakeRecipe) ],
})->update({
  lowestModSeq  => 1,
  highestModSeq => 1,
});
is($updated, 2, 'updated two state rows');

subtest "simple state comparisons" => sub {
  # First up, we are going to set up fudge distinct states, each with 10
  # updates. -- rjbs, 2016-05-03
  my $last_set_res;
  for my $type (qw(sugar anzac spritz fudge)) {
    $last_set_res = $jmap_tester->request([
      [
        'Cookie/set' => {
          create => { map {; $_ => { type => $type } } (1 .. 10) }
        }
      ],
    ]);
  }

  my $set_res = $last_set_res->single_sentence->as_set;
  my $state = $set_res->new_state . "";

  subtest "synchronize to current state: no-op" => sub {
    my $res = $jmap_tester->request([
      [ 'Cookie/changes' => { sinceState => "4" } ]
    ]);

    my ($type, $arg) = $res->single_sentence->as_triple->@*;
    is($type, 'Cookie/changes', 'cookie changes!!');

    is($arg->{oldState}, 4, "old state: 4");
    is($arg->{newState}, 4, "new state: 4");
    ok( ! $arg->{hasMoreUpdates}, "no more updates");
    ok(! $arg->{created}->@*, "no items created");
    ok(! $arg->{updated}->@*, "no items updated");
    ok(! $arg->{destroyed}->@*, "no items destroyed");
  };

  subtest "synchronize from lowest state on file" => sub {
    my $res = $jmap_tester->request([
      [ 'Cookie/changes' => { sinceState => "0" } ]
    ]);

    ok($res->as_triples->[0][1]{created}->@*, 'can sync from "0" state');
  };

  subtest "synchronize from the future" => sub {
    my $res = $jmap_tester->request([
      [ 'Cookie/changes' => { sinceState => "8" } ]
    ]);

    my ($type, $arg) = $res->single_sentence->as_triple->@*;
    is($type, 'error', 'can not sync from future state');

    is($arg->{type}, "invalidArguments", "error type");
  };

  subtest "synchronize (2 to 4), no maxChanges" => sub {
    my $res = $jmap_tester->request([
      [ 'Cookie/changes' => { sinceState => "2" } ]
    ]);

    my ($type, $arg) = $res->single_sentence->as_triple->@*;
    is($type, 'Cookie/changes', 'cookie changes!!');

    is($arg->{oldState}, 2, "old state: 2");
    is($arg->{newState}, 4, "new state: 4");
    ok( ! $arg->{hasMoreUpdates}, "no more updates");
    is($arg->{created}->@*, 20, "20 items created");
    ok(! $arg->{updated}->@*, "no items updated");
    ok(! $arg->{destroyed}->@*, "no items destroyed");
  };

  subtest "synchronize (2 to 4), maxChanges exceeds changes" => sub {
    my $res = $jmap_tester->request([
      [ 'Cookie/changes' => { sinceState => "2", maxChanges => 30 } ]
    ]);

    my ($type, $arg) = $res->single_sentence->as_triple->@*;
    is($type, 'Cookie/changes', 'cookie changes!!');

    is($arg->{oldState}, 2, "old state: 2");
    is($arg->{newState}, 4, "new state: 4");
    ok( ! $arg->{hasMoreUpdates}, "no more updates");
    is($arg->{created}->@*, 20, "20 items created");
    is($arg->{updated}->@*, 0, "no items updated");
    ok(! $arg->{destroyed}->@*, "no items destroyed");
  };

  subtest "synchronize (2 to 4), maxChanges equals changes" => sub {
    my $res = $jmap_tester->request([
      [ 'Cookie/changes' => { sinceState => "2", maxChanges => 20 } ]
    ]);

    my ($type, $arg) = $res->single_sentence->as_triple->@*;
    is($type, 'Cookie/changes', 'cookie changes!!');

    is($arg->{oldState}, 2, "old state: 2");
    is($arg->{newState}, 4, "new state: 4");
    ok( ! $arg->{hasMoreUpdates}, "no more updates");
    is($arg->{created}->@*, 20, "20 items created");
    ok(! $arg->{updated}->@*,   "no items updated");
    ok(! $arg->{destroyed}->@*,   "no items destroyed");
  };

  subtest "synchronize (2 to 4), maxChanges requires truncation" => sub {
    my $res = $jmap_tester->request([
      [ 'Cookie/changes' => { sinceState => "2", maxChanges => 15 } ]
    ]);

    my ($type, $arg) = $res->single_sentence->as_triple->@*;
    is($type, 'Cookie/changes', 'cookie changes!!');

    jcmp_deeply(
      $arg,
      superhashof({
        oldState => jstr(),
        newState => jstr(),
      }),
      'state strings are, in fact, strings'
    );

    is($arg->{oldState}, 2, "old state: 2");
    is($arg->{newState}, 3, "new state: 3");
    ok($arg->{hasMoreUpdates},   "more updates to get");
    is($arg->{created}->@*, 10, "10 items created");
    ok(! $arg->{updated}->@*,   "no items updated");
    ok(! $arg->{destroyed}->@*,   "no items destroyed");
  };

  subtest "synchronize (2 to 4), maxChanges must be exceeded" => sub {
    my $res = $jmap_tester->request([
      [ 'Cookie/changes' => { sinceState => "2", maxChanges => 8 } ]
    ]);

    my ($type, $arg) = $res->single_sentence->as_triple->@*;
    is($type, 'error', 'cannot exeed maxChanges');
    is($arg->{type}, "cannotCalculateChanges", "error type");
  };

  subtest "make some updates, synchronize (4 to 5)" => sub {
    # get a random cookie to play with
    my $creation_id = [ keys $set_res->created->%* ]->[0];
    my $cookie = $set_res->created->{$creation_id};

    my $update_res = $jmap_tester->request([[
      'Cookie/set' => {
        update => {
          $cookie->{id} => { delicious => 'no' },
        },
      },
    ]])->single_sentence->as_set;

    ok(exists $update_res->updated->{$cookie->{id}}, 'we updated our cookie');

    my $new_state = $update_res->arguments->{newState};
    is($new_state, 5, "new state is correct");

    my $change_res = $jmap_tester->request([
      [ 'Cookie/changes' => { sinceState => "4" } ]
    ]);

    my ($type, $arg) = $change_res->single_sentence->as_triple->@*;
    is($type, 'Cookie/changes', 'cookie changes!!');

    is($arg->{oldState}, 4, "old state: 4");
    is($arg->{newState}, 5, "new state: 5");
    ok(! $arg->{created}->@*, "no items created");
    ok(! $arg->{destroyed}->@*,  "no items destroyed");

    is($arg->{updated}->@*, 1, "one item updated");
    is($arg->{updated}->[0], $cookie->{id}, "updated item is our cookie");
  };
};

subtest "complex state comparisons" => sub {
  # Okay, here we're going to have two kinds of results, where changing the
  # parent row causes the child to seem out of sync.  Specifically, we have
  # Cakes and CakeRecipes.  If a cake changes, it has changed.  If a recipe has
  # changed, all the cakes of that recipe are also changed.  This is a rough
  # approximation of the logic that will govern mailing list members and lists.
  # -- rjbs, 2016-05-04
  my %recipe_id;
  subtest "create 5 recipes" => sub {
    for my $n (1..5) {
      my $cr_res = $jmap_tester->request([
        [
          'CakeRecipe/set' => {
            create => { $n => { type => "recipe-$n", avg_review => 75 } }
          },
        ],
      ]);

      my $recipe_res = $jmap_tester->strip_json_types(
        $cr_res->single_sentence->as_triple->[1]
      );

      $recipe_id{$n} = $recipe_res->{created}{$n}{id};

      my $cr_state = $cr_res->single_sentence->as_set->new_state . "";
      is($cr_state, $n+1, "after creating recipe $n, state is " . ($n + 1));
    }
  };

  my %cake_id;
  subtest "create 20 cakes" => sub {
    my $last_set_res;
    for my $layer_count (1 .. 4) {
      $last_set_res = $jmap_tester->request([
        [
          'Cake/set' => {
            create => { map {; $_ => {
              type     => "test $layer_count/$_",
              recipeId => $recipe_id{$_},
              layer_count => $layer_count,
            } } (1 .. 5) }
          }
        ],
      ]);

      my $payload = $jmap_tester->strip_json_types(
        $last_set_res->single_sentence->as_triple->[1]
      );

      for my $recipe (1 .. 5) {
        $cake_id{"C${layer_count}R$recipe"}
          = $payload->{created}{$recipe}{id};
      }
    }

    my $state = $last_set_res->single_sentence->as_set->new_state . "";
    is($state, "5-6", "four cake sets on recipe state 5; state is 5-6");
  };

  my %cake_id_rev = reverse %cake_id;

  subtest "synchronize to current state: no-op" => sub {
    my $res = $jmap_tester->request([
      [ 'Cake/changes' => { sinceState => "5-6" } ]
    ]);

    my ($type, $arg) = $res->single_sentence->as_triple->@*;
    is($type, 'Cake/changes', 'cake changes!!');

    is($arg->{oldState}, '5-6', "old state: 5-6");
    is($arg->{newState}, '5-6', "new state: 5-6");
    ok( ! $arg->{hasMoreUpdates}, "no more updates");
    ok(! $arg->{created}->@*, "no items created");
    ok(! $arg->{updated}->@*, "no items updated");
    ok(! $arg->{destroyed}->@*, "no items destroyed");
  };

  subtest "synchronize from non-compound state" => sub {
    my $res = $jmap_tester->request([
      [ 'Cake/changes' => { sinceState => "2" } ]
    ]);

    my ($type, $arg) = $res->single_sentence->as_triple->@*;
    is($type, 'error', 'can not sync from non-compound state');

    is($arg->{type}, "invalidArguments", "error type");
  };

  subtest "synchronize from too-low lhs state" => sub {
    my $res = $jmap_tester->request([
      [ 'Cake/changes' => { sinceState => "0-3" } ]
    ]);

    my ($type, $arg) = $res->single_sentence->as_triple->@*;
    is($type, 'error', 'can not sync from (one-part) too-low state');

    is($arg->{type}, "cannotCalculateChanges", "error type");
  };

  subtest "synchronize from too-low rhs state" => sub {
    my $res = $jmap_tester->request([
      [ 'Cake/changes' => { sinceState => "3-0" } ]
    ]);

    my ($type, $arg) = $res->single_sentence->as_triple->@*;
    is($type, 'error', 'can not sync from (one-part) too-low state');

    is($arg->{type}, "cannotCalculateChanges", "error type");
  };

  subtest "synchronize (4-6 to 5-6), no maxChanges" => sub {
    my $res = $jmap_tester->request([
      [ 'Cake/changes' => { sinceState => "4-6" } ]
    ]);

    my ($type, $arg) = $res->single_sentence->as_triple->@*;
    is($type, 'Cake/changes', 'cake changes!!');

    is($arg->{oldState}, '4-6', "old state: 4-6");
    is($arg->{newState}, '5-6', "new state: 5-6");
    ok( ! $arg->{hasMoreUpdates}, "no more updates");
    is($arg->{created}->@*, 5, "5 items created");

    is_deeply(
      [ sort $arg->{created}->@* ],
      [ sort @cake_id{qw( C4R1 C4R2 C4R3 C4R4 C4R5 )} ],
      "the five expected items updated",
    );

    ok(! $arg->{destroyed}->@*,   "no items destroyed");
  };

  subtest "synchronize (5-5 to 5-6), no maxChanges" => sub {
    my $res = $jmap_tester->request([
      [ 'Cake/changes' => { sinceState => "5-5" } ]
    ]);

    my ($type, $arg) = $res->single_sentence->as_triple->@*;
    is($type, 'Cake/changes', 'cake changes!!');

    is($arg->{oldState}, '5-5', "old state: 5-5");
    is($arg->{newState}, '5-6', "new state: 5-6");
    ok( ! $arg->{hasMoreUpdates}, "no more updates");
    is($arg->{updated}->@*, 4, "4 items changed");

    is_deeply(
      [ sort $arg->{updated}->@* ],
      [ sort @cake_id{qw( C1R5 C2R5 C3R5 C4R5 )} ],
      "the five expected items updated",
    );

    ok(! $arg->{destroyed}->@*,   "no items destroyed");
  };

  for my $test (
    [ "sync (4-5 to 5-6), no maxChanges",              {} ],
    [ "sync (4-5 to 5-6), maxChanges exceeds updates", { maxChanges => 10 } ],
    [ "sync (4-5 to 5-6), maxChanges equals updates",  { maxChanges =>  8 } ],
  ) {
    subtest $test->[0] => sub {
      my $res = $jmap_tester->request([
        [ 'Cake/changes' => { sinceState => "4-5", $test->[1]->%* } ]
      ]);

      my ($type, $arg) = $res->single_sentence->as_triple->@*;
      is($type, 'Cake/changes', 'cake changes!!');

      is($arg->{oldState}, '4-5', "old state: 4-5");
      is($arg->{newState}, '5-6', "new state: 5-6");
      ok( ! $arg->{hasMoreUpdates}, "no more updates");

      # Ok, so. We created 5 cakes at state 4-6, which bumps our state to 5-6.
      # But because in this complex state, we return both parts if either part
      # changed (all the cakes were created since recipe state 5), we're gonna
      # return all of them here. That means that 5 of them will be created
      # (because the cakes themselves were created, and the others will come
      # back as updated, because that's the only reasonable thing we can do,
      # if we're committed to returning them all. -- michael, 2018-07-03
      is($arg->{created}->@*, 5, "5 items changed");
      is($arg->{updated}->@*, 3, "3 items updated");

      is_deeply(
        [ sort $arg->{created}->@*, $arg->{updated}->@* ],
        [ sort @cake_id{qw( C4R1 C4R2 C4R3 C4R4 C4R5
                            C1R5 C2R5 C3R5 )} ],
        "the eight expected items updated",
      );

      ok(! $arg->{destroyed}->@*,   "no items destroyed");
    };
  }

  subtest "sync (4-5 to 5-6), maxChanges forces 2 passes" => sub {
    my %changed;
    my $mid_state;
    subtest "first pass at small-window update" => sub {
      my $res = $jmap_tester->request([
        [ 'Cake/changes' => { sinceState => "4-5", maxChanges => 5 } ]
      ]);

      my ($type, $arg) = $res->single_sentence->as_triple->@*;
      is($type, 'Cake/changes', 'cake changes!!');

      is($arg->{oldState}, '4-5', "old state: 4-5");
      ok(
        $arg->{newState} ne $arg->{oldState},
        "new state: $arg->{newState}",
      );
      ok($arg->{hasMoreUpdates},  "more updates await");
      ok(! $arg->{destroyed}->@*,   "no items destroyed");

      my @changed = ($arg->{created}->@*, $arg->{updated}->@*);
      cmp_ok(@changed, '<=', 5, "<= 5 items changed");

      $changed{ $cake_id_rev{$_} }++ for @changed;
      $mid_state = $arg->{newState};
    };

    subtest "second pass at small-window update" => sub {
      my $res = $jmap_tester->request([
        [ 'Cake/changes' => { sinceState => $mid_state, maxChanges => 5 } ]
      ]);

      my ($type, $arg) = $res->single_sentence->as_triple->@*;
      is($type, 'Cake/changes', 'cake changes!!');

      is($arg->{oldState}, $mid_state, "old state: $mid_state");
      ok(! $arg->{hasMoreUpdates},  "no more updates");
      ok(! $arg->{destroyed}->@*,   "no items destroyed");

      my @changed = ($arg->{created}->@*, $arg->{updated}->@*);
      cmp_ok(@changed, '<=', 5, "<= 5 items changed");

      $changed{ $cake_id_rev{$_} }++ for @changed;
    };

    is(keys %changed, 8, "eight total updates (with maybe some dupes)");
    is_deeply(
      [ sort keys %changed ],
      [ sort qw( C4R1 C4R2 C4R3 C4R4 C4R5 C1R5 C2R5 C3R5 ) ],
      "the eight expected items updated",
    );
  };

  subtest "sync (4-5 to 5-6), maxChanges smaller than first window" => sub {
    my $res = $jmap_tester->request([
      [ 'Cake/changes' => { sinceState => "4-5", maxChanges => 3 } ]
    ]);

    my ($type, $arg) = $res->single_sentence->as_triple->@*;
    is($type, 'error', 'cannot exeed maxChanges');
    is($arg->{type}, "cannotCalculateChanges", "error type is correct");
  };
};

subtest "updated null and updated Object" => sub {
  my $cookie_id;

  {
    my $res = $jmap_tester->request([
      [
        'Cookie/set' => {
          create => { foo => { type => 'macaroon' } }
        },
      ],
    ]);

    my $set = $res->assert_successful->single_sentence('Cookie/set')->as_set;
    my $cookie = $set->created->{foo};
    $cookie_id = $cookie->{id};

    jcmp_deeply(
      $cookie,
      {
        id => jstr(),
        baked_at => ignore(),
        expires_at => ignore(),
        delicious => jstr('yes'),
        batch => ignore,
        external_id => undef, # is this really needed?
      },
      "created a cookie"
    );
  }

  {
    my $res = $jmap_tester->request([
      [
        'Cookie/set' => {
          update => { $cookie_id => { delicious => 'maybe' } }
        },
      ],
    ]);

    my $set = $res->assert_successful->single_sentence('Cookie/set')->as_set;
    my $cookie = $set->updated->{ $cookie_id };

    jcmp_deeply(
      $cookie,
      undef,
      "we updated the cookie, no server-provided updates",
    );
  }

  {
    my $res = $jmap_tester->request([
      [
        'Cookie/set' => {
          update => { $cookie_id => { type => 'macaron' } }
        },
      ],
    ]);

    my $set = $res->assert_successful->single_sentence('Cookie/set')->as_set;
    my $cookie = $set->updated->{ $cookie_id };

    jcmp_deeply(
      $cookie,
      { delicious => jstr('eh') },
      "we updated the cookie, so did the server",
    );
  }
};

subtest "Foo/changes - ix_changes_check" => sub {
  {
    my $res = $jmap_tester->request([
      [
        'User/changes' => {
          sinceState => "0",
          limit      => 5,
        }
      ]
    ]);

    ok($res->single_sentence('User/changes'), 'got changes');
  }

  {
    my $res = $jmap_tester->request([
      [
        'User/changes' => {
          sinceState => "0",
          limit      => 6,
        }
      ]
    ]);

    ok(my $err = $res->single_sentence('error'), 'got error');
    is($err->{arguments}{type}, 'overLimit', 'got correct error');
  }
};

$app->_shutdown;

done_testing;
