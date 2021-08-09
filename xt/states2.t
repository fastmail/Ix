use 5.20.0;
use warnings;
use utf8;
use experimental qw(lexical_subs signatures postderef refaliasing);

use lib 't/lib';

use Bakesale;

BEGIN {
  no warnings qw(redefine);

  # So we don't hit the for update lock timeout of 2s
  *Bakesale::database_defaults = sub {
    return (
      "SET LOCK_TIMEOUT TO '50s'",
    );
  }
}

use Bakesale::App;
use Bakesale::Schema;
use JSON;
use Test::Deep;
use Test::Deep::JType;
use Test::More;
use Unicode::Normalize;
use Data::Dumper;
use Process::Status;
use Path::Tiny;

my ($app, $jmap_tester) = Bakesale::Test->new_test_app_and_tester;
\my %account = Bakesale::Test->load_trivial_account($app->processor->schema_connection);

$jmap_tester->ua->set_cookie({
  api_uri => $jmap_tester->api_uri,
  name    => 'bakesaleUserId',
  value   => $account{users}{rjbs},
});

# Clear our states table
$app->processor->schema_connection->storage->dbh->do("DELETE FROM states");
$app->processor->schema_connection->storage->dbh->do("DELETE FROM cookies");

my %children;
my $parent_pid = $$;

# Each child needs to send us a different signal or we may miss a
# signal if more than one child sends it to us at the same time
my @SIGNALS = qw(USR1 USR2 TERM HUP);

my $signaled = 0;

for my $sig (@SIGNALS) {
  $SIG{$sig} = sub { $signaled++; };
}

sub with_child :prototype(&) ($code) {
  my $sig = shift @SIGNALS;

  my $res = fork;
  if ($res) {
    $children{$res} = 1;

    return $res;
  }

  # Let parent know we started
  kill $sig => $parent_pid;

  # unblock_child() will take us passed this
  sleep 30;

  $code->();

  # Signal our parent we're done
  kill $sig => $parent_pid;

  exit;
}

sub unblock_child ($child) {
  kill 'USR1' => $child;
}

sub end_child ($child) {
  kill 'KILL' => $child;
}

END {
  for my $k (keys %children) {
    waitpid($k, 0);
  }

  # Clean up $? or our test reports a failure
  exit;
}

# Start 2 processes. Have them both try to create a cookie which will
# set the cookie state. One should succeed, one should fail, and the
# failed ones should not leave cookies behind

my $lock = with_child {
  my $schema = $app->processor->schema_connection;

  $schema->txn_do(sub {
    $schema->storage->dbh->do("LOCK TABLE states IN ACCESS EXCLUSIVE MODE");

    # Let parent know we have the lock
    kill 'USR1' => $parent_pid;

    # main proc will take us passed this
    sleep 60;
  });
};

while (!$signaled) {
  note("waiting for locker to start up\n");
  sleep 1;
}

$signaled = 0;

unblock_child($lock);

while (!$signaled) {
  note("waiting for locker to lock\n");
  sleep 1;
}

$signaled = 0;

my $c1f = Path::Tiny->tempfile;

# Our first set cookies
my $child1 = with_child {
  my $res = $jmap_tester->request([
    [
      'Cookie/set' => {
        create => { raw => { type => 'first', baked_at => undef } },
      },
    ],
  ]);

  $c1f->spew($res->http_response->decoded_content);
};

my $c2f = Path::Tiny->tempfile;

# Our second set cookies
my $child2 = with_child {
  my $res = $jmap_tester->request([
    [
      'Cookie/set' => {
        create => { raw => { type => 'second', baked_at => undef } },
      },
    ],
  ]);

  $c2f->spew($res->http_response->decoded_content);
};

while ($signaled != 2) {
  note("waiting for our children to start up");
  sleep 1;
}

for my $child ($child1, $child2) {
  unblock_child($child);
}

note 'children are blocked on our lock, waiting a second and releasing';

sleep 1;

$signaled = 0;

end_child($lock);

# These have been freed up when we released the lock and should
# do their thing then exit
for my $pid ($child1, $child2) {
  ok(waitpid($pid, 0), "child exited");
}

# And they should have signaled us before exiting
is($signaled, 2, 'both children completed');

# This should give us one cookie, state increased by 1
my $res = $jmap_tester->request([
  [ 'Cookie/get' => {} ],
]);

my $fail = 0;

is(
  $res->single_sentence('Cookie/get')->arguments->{list}->@*,
  1,
  'only created one cookie'
) or $fail++;

is(
  $res->single_sentence('Cookie/get')->arguments->{state},
  1,
  'state only incremented once'
) or $fail++;

diag explain $res->as_stripped_triples if $fail;

my $res1 = $c1f->slurp;
my $res2 = $c2f->slurp;

ok($res1, 'got child 1 output');
ok($res2, 'got child2 output');

$res1 = decode_json($res1);
$res2 = decode_json($res2);

my $res1type = $res1->{methodResponses}[0][0];
my $res2type = $res2->{methodResponses}[0][0];

jcmp_deeply(
  [ $res1type, $res2type ],
  set('Cookie/set', 'error'),
  'got one success, one fail'
);

my $err = $res1type eq 'error'
            ? $res1->{methodResponses}[0][1]
            : $res2->{methodResponses}[0][1];

is($err->{type}, 'tryAgain', 'got correct error');

$app->_shutdown;

done_testing;
