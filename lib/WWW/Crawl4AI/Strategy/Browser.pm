package WWW::Crawl4AI::Strategy::Browser;
# ABSTRACT: Crawl4AI strategy with full JS rendering (wait for networkidle)
use Moo;
use WWW::Crawl4AI::Request ();
with 'WWW::Crawl4AI::Strategy';

our $VERSION = '0.001';

sub name       { 'crawl4ai_browser' }
sub cost_class { 'browser' }

sub build_request {
  my ( $self, $crawler, $url ) = @_;
  return $self->_request(
    $url,
    browser => { headless => WWW::Crawl4AI::Request::JSON_true() },
    crawler => { wait_until => 'networkidle' },
  );
}

1;

=head1 DESCRIPTION

Full browser rendering: drops C<text_mode> and waits for C<networkidle>, so
script-heavy pages that come back thin or empty from
L<WWW::Crawl4AI::Strategy::Plain> get a real render.

=method name

C<crawl4ai_browser>.

=method cost_class

C<browser>.

=cut
