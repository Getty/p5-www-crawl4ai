package WWW::Crawl4AI::Strategy::Plain;
# ABSTRACT: cheapest Crawl4AI strategy — headless text mode, no escalation
use Moo;
use WWW::Crawl4AI::Request ();
with 'WWW::Crawl4AI::Strategy';

our $VERSION = '0.001';

sub name       { 'crawl4ai_plain' }
sub cost_class { 'cheap' }

sub build_request {
  my ( $self, $crawler, $url ) = @_;
  return $self->_request(
    $url,
    browser => { text_mode => WWW::Crawl4AI::Request::JSON_true() },
  );
}

1;

=head1 DESCRIPTION

The first link in the chain: a plain Crawl4AI call with C<text_mode> on and no
special browser. Cheapest and fastest; good enough for most static pages.

=method name

C<crawl4ai_plain>.

=method cost_class

C<cheap>.

=cut
