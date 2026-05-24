package WWW::Crawl4AI::Strategy;
# ABSTRACT: role for a single crawl strategy in the WWW::Crawl4AI fallback chain
use Moo::Role;
use WWW::Crawl4AI::Request ();

our $VERSION = '0.001';

requires 'name';
requires 'cost_class';

# Whether this strategy belongs in the chain for the given crawler.
# Plain/Browser/Stealth are always applicable; CloakBrowser/Proxy/Callback
# override this to gate on configuration.
sub applicable { 1 }

# Default execution: build a Request and run it through the client, returning a
# single normalized page. Strategies that don't fetch via Crawl4AI (Callback)
# override this instead of providing build_request.
sub crawl {
  my ( $self, $crawler, $url, %opts ) = @_;
  my $req   = $self->build_request( $crawler, $url, %opts );
  my $pages = $crawler->client->crawl( $req, $self->name );
  return $pages->[0];
}

# Helper for build_request implementations.
sub _request {
  my ( $self, $url, %p ) = @_;
  return WWW::Crawl4AI::Request->new(
    urls           => $url,
    browser_params => $p{browser} || {},
    crawler_params => $p{crawler} || {},
  );
}

1;

=head1 SYNOPSIS

  package WWW::Crawl4AI::Strategy::Mine;
  use Moo;
  with 'WWW::Crawl4AI::Strategy';
  sub name       { 'crawl4ai_mine' }
  sub cost_class { 'browser' }
  sub build_request {
    my ( $self, $crawler, $url, %opts ) = @_;
    return $self->_request( $url, browser => { headless => 1 } );
  }

=head1 DESCRIPTION

A L<Moo::Role> implemented by every strategy in the chain. Each strategy maps a
URL onto a Crawl4AI request with a particular browser/crawler configuration, and
declares its cost tier. The chain in L<WWW::Crawl4AI> runs applicable strategies
in cost order until one returns a page that L<WWW::Crawl4AI::Detect> rates good.

=method name

Required. The backend identifier, e.g. C<crawl4ai_plain>.

=method cost_class

Required. One of C<cheap>, C<browser>, C<stealth>, C<paid>.

=method applicable

Returns true if the strategy should be in the chain for C<$crawler>. Default
true; gated strategies override it.

=method build_request

Consumers implement this (unless they override L</crawl>): given
C<< ($crawler, $url, %opts) >>, return a L<WWW::Crawl4AI::Request>.

=method crawl

Runs the strategy and returns a single normalized page hashref (or throws a
L<WWW::Crawl4AI::Error>). The default implementation calls L</build_request> and
the crawler's client.

=method _request

Convenience for L</build_request>: C<< $self->_request($url, browser => {...},
crawler => {...}) >> builds a L<WWW::Crawl4AI::Request>.

=cut
