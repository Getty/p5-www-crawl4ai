package WWW::Crawl4AI::Strategy::Proxy;
# ABSTRACT: Crawl4AI strategy routing through a configured proxy
use Moo;
use WWW::Crawl4AI::Request ();
with 'WWW::Crawl4AI::Strategy';

our $VERSION = '0.001';

sub name       { 'crawl4ai_proxy' }
sub cost_class { 'paid' }

sub applicable {
  my ( $self, $crawler ) = @_;
  return $crawler->proxy_url ? 1 : 0;
}

sub build_request {
  my ( $self, $crawler, $url ) = @_;
  return $self->_request(
    $url,
    browser => {
      enable_stealth  => WWW::Crawl4AI::Request::JSON_true(),
      user_agent_mode => 'random',
      proxy_config    => { server => $crawler->proxy_url },
    },
    crawler => { wait_until => 'networkidle' },
  );
}

1;

=head1 DESCRIPTION

The escalation tier: a stealth crawl routed through Crawl4AI's C<proxy_config>.
Only enters the chain when the crawler has a C<proxy_url> (proxies usually cost
money or bandwidth, hence C<cost_class> C<paid>).

=method name

C<crawl4ai_proxy>.

=method cost_class

C<paid>.

=method applicable

True only when C<< $crawler->proxy_url >> is set.

=cut
