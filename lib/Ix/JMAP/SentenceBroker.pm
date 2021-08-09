use v5.24.0;
package Ix::JMAP::SentenceBroker;
# ABSTRACT: an object to get some sentences

use Moose;

with 'JMAP::Tester::Role::SentenceBroker';

use experimental 'signatures';

use JMAP::Tester::Response::Sentence;
use JMAP::Tester::Response::Paragraph;
use JSON::Typist;

=head1 OVERVIEW

This is an implementation of L<JMAP::Tester::Role::SentenceBroker>.
It's used internally by L<Ix::Processor::JMAP>, via
L<Ix::JMAP::SentenceCollection>.

=method client_ids_for_items($items)

Given a bunch of JMAP requests or responses, returns a list of their client
ids.

=cut

sub client_ids_for_items ($self, $items) {
  map {; $_->[1] } @$items
}

=method sentence_for_item($item)

Given a single JMAP method response, return a new
L<JMAP::Tester::Response::Sentence> for it.

=cut

sub sentence_for_item ($self, $item) {
  JMAP::Tester::Response::Sentence->new({
    name      => $item->[0]->result_type,
    arguments => $item->[0]->result_arguments,
    client_id => $item->[1],

    sentence_broker => $self,
  });
}

=method paragraph_for_items($items)

Given a set of JMAP method responses, return a new
L<JMAP::Tester::Response::Paragraph> for it.

=cut

sub paragraph_for_items {
  my ($self, $items) = @_;

  return JMAP::Tester::Response::Paragraph->new({
    sentences => [
      map {; $self->sentence_for_item($_) } @$items
    ],
  });
}

=method abort

This method will die if called.

=cut

sub abort {
  Carp::confess("abort called on Ix::JMAP::SentenceCollection; this should not happen!");
}

=method strip_json_types

Strip a reference of L<JSON::Typist> objects.

=cut

sub strip_json_types {
  state $typist = JSON::Typist->new;
  $typist->strip_types($_[1]);
}

no Moose;

1;

=head1 SEE ALSO

=for :list
* L<JMAP::Tester>
