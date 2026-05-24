package WWW::Crawl4AI::Strategy::CloakBrowser;
# ABSTRACT: Crawl4AI strategy attaching to CloakBrowser over CDP
use Moo;
use URI ();
use WWW::Crawl4AI::Request ();
with 'WWW::Crawl4AI::Strategy';

our $VERSION = '0.001';

=head1 DESCRIPTION

Tells Crawl4AI to drive an external CloakBrowser via C<browser_mode: custom> and
a C<cdp_url>, rather than its own bundled browser. Only enters the chain when
the crawler has a C<cloakbrowser_url>.

If that URL has no query string, a per-domain C<?fingerprint=E<lt>hostE<gt>> is
appended so each target gets a stable CloakBrowser identity (CloakBrowser also
accepts C<timezone>, C<locale>, C<platform>, C<proxy>, C<geoip> there).

B<Security:> the CDP port grants full browser control — never expose it to the
public internet.

=cut

sub name       { 'crawl4ai_cloakbrowser' }

=method name

C<crawl4ai_cloakbrowser>.

=cut

sub cost_class { 'stealth' }

=method cost_class

C<stealth>.

=cut

sub applicable {
  my ( $self, $crawler ) = @_;
  return $crawler->cloakbrowser_url ? 1 : 0;
}

=method applicable

True only when C<< $crawler->cloakbrowser_url >> is set.

=cut

sub build_request {
  my ( $self, $crawler, $url ) = @_;
  return $self->_request(
    $url,
    browser => {
      browser_mode            => 'custom',
      cdp_url                 => $self->_cdp_url( $crawler, $url ),
      cache_cdp_connection    => WWW::Crawl4AI::Request::JSON_true(),
      create_isolated_context => WWW::Crawl4AI::Request::JSON_true(),
    },
    crawler => { wait_until => 'networkidle' },
  );
}

# Per-domain stable fingerprint: if the configured CDP URL has no query string,
# append ?fingerprint=<host> so each domain gets a consistent CloakBrowser
# identity. A URL that already carries query params is used verbatim.
sub _cdp_url {
  my ( $self, $crawler, $url ) = @_;
  my $cdp = $crawler->cloakbrowser_url;
  return $cdp if $cdp =~ /\?/;
  my $host = eval { URI->new($url)->host } || 'default';
  ( my $base = $cdp ) =~ s{/+$}{};
  return "$base?fingerprint=$host";
}

1;
