package WWW::Crawl4AI::Request;
# ABSTRACT: builds Crawl4AI /crawl and /md request payloads
use Moo;
use Carp qw( croak );

our $VERSION = '0.001';

=head1 SYNOPSIS

  my $req = WWW::Crawl4AI::Request->new(
    urls           => 'https://example.com',
    browser_params => { enable_stealth => JSON::MaybeXS::true() },
    crawler_params => { wait_until => 'networkidle' },
  );

  my $payload = $req->to_crawl_payload;
  # { urls => [...], browser_config => { type => 'BrowserConfig', params => {...} },
  #   crawler_config => { type => 'CrawlerRunConfig', params => {...} } }

=head1 DESCRIPTION

A small value object that turns crawl options into the nested
C<browser_config>/C<crawler_config> shape the Crawl4AI Docker REST API expects.
Each L<WWW::Crawl4AI::Strategy> produces one of these with its own
browser/crawler parameters; L<WWW::Crawl4AI::Client> serializes it.

Sensible defaults are merged in unless overridden: C<headless> for the browser,
C<< stream => false >> and C<< cache_mode => 'bypass' >> for the crawler.

=cut

has urls => (
  is       => 'ro',
  required => 1,
  coerce   => sub { ref $_[0] eq 'ARRAY' ? $_[0] : [ $_[0] ] },
);

=attr urls

Required. A single URL string or an arrayref of URLs (coerced to an arrayref).

=cut

has browser_params => (
  is      => 'ro',
  default => sub { {} },
);

=attr browser_params

Hashref of C<BrowserConfig> parameters (e.g. C<enable_stealth>, C<browser_mode>,
C<cdp_url>, C<user_agent_mode>). Merged over the defaults.

=cut

has crawler_params => (
  is      => 'ro',
  default => sub { {} },
);

=attr crawler_params

Hashref of C<CrawlerRunConfig> parameters (e.g. C<wait_until>, C<cache_mode>).
Merged over the defaults.

=cut

# /md endpoint extras
has filter => ( is => 'ro' );    # fit | raw | bm25 | llm

=attr filter

Optional C</md> filter strategy: C<fit>, C<raw>, C<bm25> or C<llm>.

=cut

has query  => ( is => 'ro' );

=attr query

Optional query string for C<bm25>/C<llm> C</md> filtering.

=cut

has cache  => ( is => 'ro' );

=attr cache

Optional C</md> cache flag.

=cut

sub BUILD {
  my ( $self ) = @_;
  croak "WWW::Crawl4AI::Request needs at least one url" unless @{ $self->urls };
  return;
}

sub _default_browser_params {
  return { headless => JSON_true() };
}

sub _default_crawler_params {
  return { stream => JSON_false(), cache_mode => 'bypass' };
}

# We avoid a hard JSON::PP::Boolean dependency at build time by deferring to
# JSON::MaybeXS only where booleans are actually serialized. These helpers keep
# the payload hash JSON-true/false rather than 1/0 (Crawl4AI is strict).
my ( $TRUE, $FALSE );
sub JSON_true  { $TRUE  ||= do { require JSON::MaybeXS; JSON::MaybeXS::true() } }
sub JSON_false { $FALSE ||= do { require JSON::MaybeXS; JSON::MaybeXS::false() } }

=func JSON_true

=func JSON_false

Return the shared L<JSON::MaybeXS> boolean singletons, so payload booleans
serialize as JSON C<true>/C<false> rather than C<1>/C<0>.

=cut

sub to_crawl_payload {
  my ( $self ) = @_;
  my %browser = ( %{ $self->_default_browser_params }, %{ $self->browser_params } );
  my %crawler = ( %{ $self->_default_crawler_params }, %{ $self->crawler_params } );
  return {
    urls           => $self->urls,
    browser_config => { type => 'BrowserConfig',     params => \%browser },
    crawler_config => { type => 'CrawlerRunConfig',  params => \%crawler },
  };
}

=method to_crawl_payload

Returns the hashref body for C<POST /crawl> (and C<POST /crawl/job>).

=cut

sub to_md_payload {
  my ( $self ) = @_;
  my %p = ( url => $self->urls->[0] );
  $p{f} = $self->filter if defined $self->filter;
  $p{q} = $self->query  if defined $self->query;
  $p{c} = $self->cache  if defined $self->cache;
  return \%p;
}

=method to_md_payload

Returns the hashref body for C<POST /md> (single URL).

=cut

1;
