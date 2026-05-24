package WWW::Crawl4AI::Strategy::Stealth;
# ABSTRACT: Crawl4AI strategy with enable_stealth and randomized fingerprint
use Moo;
use WWW::Crawl4AI::Request ();
with 'WWW::Crawl4AI::Strategy';

our $VERSION = '0.001';

sub name       { 'crawl4ai_stealth' }
sub cost_class { 'stealth' }

sub build_request {
  my ( $self, $crawler, $url ) = @_;
  return $self->_request(
    $url,
    browser => {
      enable_stealth  => WWW::Crawl4AI::Request::JSON_true(),
      user_agent_mode => 'random',
    },
    crawler => { wait_until => 'networkidle' },
  );
}

1;

=head1 DESCRIPTION

Turns on Crawl4AI's C<enable_stealth> (Playwright-stealth-style fingerprint
adjustment) and a randomized user agent. Aimed at sites with light bot
protection that reject a vanilla headless browser.

=method name

C<crawl4ai_stealth>.

=method cost_class

C<stealth>.

=cut
