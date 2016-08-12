use 5.20.0;
package Ix::App;

use Moose::Role;
use experimental qw(signatures postderef);

use Data::GUID qw(guid_string);
use JSON;
use Plack::Request;

use namespace::autoclean;

has json_codec => (
  is => 'ro',
  default => sub {
    JSON->new->utf8->pretty->allow_blessed->convert_blessed->canonical
  },
  handles => {
    encode_json => 'encode',
    decode_json => 'decode',
  },
);

has processor => (
  is => 'ro',
  required => 1,
);

has _logger => (
  is  => 'ro',
  isa => 'CodeRef',
);

has psgi_app => (
  is  => 'ro',
  isa => 'CodeRef',
  lazy => 1,
  builder => '_build_psgi_app',
);

sub to_app ($self) { $self->psgi_app }

sub _build_psgi_app ($self) {
  my $logger = $self->_logger;

  return sub ($env) {
    my $req = Plack::Request->new($env);

    if ($req->method eq 'OPTIONS') {
      return [
        200,
        [
          'Access-Control-Allow-Origin' => '*',
          'Access-Control-Allow-Methods' => 'POST,GET,OPTIONS',
          'Access-Control-Allow-Headers' => 'Accept,Authorization,Content-Type,X-ME-ClientVersion,X-ME-LastActivity',
          'Access-Control-Allow-Max-Age' => 60
        ],
        [ '' ],
      ];
    }

    my $ctx = $self->processor->context_from_plack_request($req);

    my $content = $req->raw_body;

    my $request_time = Ix::DateTime->now->iso8601;

    my $guid;
    if ($logger) {
      state $request_number;
      $request_number++;
      $guid = guid_string;
      $logger->( "<<< BEGIN REQUEST $guid\n"
               . "||| TIME: $request_time\n"
               . "||| SEQ : $$ $request_number\n"
               . ($content // "")
               . "\n"
               . ">>> END REQUEST $guid\n");
    }

    my $res = eval {
      my $calls;
      unless (eval { $calls = $self->decode_json( $content ); 1 }) {
        return [
          400,
          [
            'Content-Type', 'application/json',
            'Access-Control-Allow-Origin' => '*',
            ($guid ? ('Ix-Request-GUID' => $guid) : ()),
          ],
          [ '{"error":"could not decode request"}' ],
        ];
      }

      my $result  = $ctx->process_request( $calls );
      my $json    = $self->encode_json($result);

      if ($logger) {
        $logger->( "<<< BEGIN RESPONSE\n"
                 . "$json\n"
                 . ">>> END RESPONSE\n" );
      }

      return [
        200,
        [
          'Content-Type', 'application/json',
          'Access-Control-Allow-Origin' => '*',
          ($guid ? ('Ix-Request-GUID' => $guid) : ()),
        ],
        [ $json ],
      ];
    };

    # TODO: handle HTTP::Throwable..? -- rjbs, 2016-08-12
    unless ($res) {
      my $error = $@;
      my $guid  = $ctx->report_exception($error);
      $res = [
        500,
        [
          'Content-Type', 'application/json',
          'Access-Control-Allow-Origin' => '*', # ?
          ($guid ? ('Ix-Request-GUID' => $guid) : ()),
        ],
        [ qq<{"error":"internal","guid":"$guid"}> ],
      ];
    }

    if (my @guids = $ctx->logged_exception_guids) {
      $env->{'psgi.errors'}->print("exception was reported: $_\n") for @guids;
    }

    return $res;
  }
}

1;
