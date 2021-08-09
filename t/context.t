use 5.20.0;
use warnings;
use utf8;
use experimental qw(lexical_subs signatures postderef refaliasing);

use lib 't/lib';

use Bakesale;
use Bakesale::App;
use Bakesale::Schema;
use Test::Deep;
use Test::More;
use Ix::Util qw(ix_new_id);

my ($app, $jmap_tester) = Bakesale::Test->new_test_app_and_tester;

{
  # No user cookie, should get 410 response
  my $res = $jmap_tester->request([[ 'Cookie/get' => {} ]])->http_response;
  is($res->code, 410, 'got 410 with no cookie');
  is($res->decoded_content, '{}', 'empty json object');
}

{
  # Bad user cookie, should get 410 response with error. Make sure headers
  # are filled in
  local %ENV;

  my $bad_id = $ENV{BAD_ID} = ix_new_id();
  $jmap_tester->ua->set_cookie({
    api_uri => $jmap_tester->api_uri,
    name    => 'bakesaleUserId',
    value   => $bad_id,
  });

  $jmap_tester->ua->set_default_header('Origin' => 'example.net');

  my $res = $jmap_tester->request([[ 'Cookie/get' => {} ]])->http_response;
  is($res->code, 410, 'got 410 with bad cookie');
  is($res->decoded_content, '{"error":"bad auth"}', 'got error in body');

  is($res->header('Vary'), 'Origin', 'Vary header is correct');
  ok($res->header('Ix-Transaction-ID'), 'we have a request guid!');
}

{
  my $ctx = $app->processor->get_system_context;
  $ctx = $ctx->with_account('generic' => 'some-id');

  my $res1 = $ctx->result('Foo/get' => { arg => 'value' });

  cmp_deeply(
    $res1->result_arguments,
    {
      accountId => 'some-id',
      arg => 'value',
    },
    '->result adds our account id',
  );

  my $res2 = $ctx->result_without_accountid('Foo/get' => { arg => 'value' });
  cmp_deeply(
    $res2->result_arguments,
    { arg => 'value' },
    '->result_without_accountid does not add an account id',
  );
}

done_testing;
