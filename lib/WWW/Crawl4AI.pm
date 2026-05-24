package WWW::Crawl4AI;
# ABSTRACT: Perl client and fallback orchestrator for Crawl4AI
use Moo;
use Carp qw( croak );
use Time::HiRes ();
use WWW::Crawl4AI::Client ();
use WWW::Crawl4AI::Result ();
use WWW::Crawl4AI::Attempt ();
use WWW::Crawl4AI::Error ();
use WWW::Crawl4AI::Detect ();
use WWW::Crawl4AI::Strategy::Plain ();
use WWW::Crawl4AI::Strategy::Browser ();
use WWW::Crawl4AI::Strategy::Stealth ();
use WWW::Crawl4AI::Strategy::CloakBrowser ();
use WWW::Crawl4AI::Strategy::Proxy ();
use WWW::Crawl4AI::Strategy::Callback ();

our $VERSION = '0.001';

# Default chain order, cheapest first.
my @CHAIN_CLASSES = qw(
  WWW::Crawl4AI::Strategy::Plain
  WWW::Crawl4AI::Strategy::Browser
  WWW::Crawl4AI::Strategy::Stealth
  WWW::Crawl4AI::Strategy::CloakBrowser
  WWW::Crawl4AI::Strategy::Proxy
  WWW::Crawl4AI::Strategy::Callback
);

has base_url => (
  is      => 'ro',
  default => sub { $ENV{CRAWL4AI_URL} || $ENV{CRAWL4AI_BASE_URL} || 'http://localhost:11235' },
);

has api_token => (
  is      => 'ro',
  default => sub { $ENV{CRAWL4AI_API_TOKEN} },
);

has cloakbrowser_url => (
  is      => 'ro',
  default => sub { $ENV{CLOAKBROWSER_CDP_URL} },
);

has proxy_url => (
  is      => 'ro',
  default => sub { $ENV{CRAWL4AI_PROXY_URL} },
);

has callback => ( is => 'ro' );

# 'auto' (full applicable chain), 'plain'/'none' (Plain only), or an arrayref
# of backend names to run in that explicit order.
has fallback => ( is => 'ro', default => sub { 'auto' } );

has timeout      => ( is => 'ro', default => sub { 120 } );
has min_markdown => ( is => 'ro' );

has client => ( is => 'lazy' );

sub _build_client {
  my ( $self ) = @_;
  return WWW::Crawl4AI::Client->new(
    base_url  => $self->base_url,
    api_token => $self->api_token,
    timeout   => $self->timeout,
  );
}

has strategies => ( is => 'lazy' );

sub _build_strategies {
  my ( $self ) = @_;
  my @all = map { $_->new } @CHAIN_CLASSES;
  my $fb  = $self->fallback;

  if ( ref $fb eq 'ARRAY' ) {
    my %by_name = map { $_->name => $_ } @all;
    return [ grep { $_ && $_->applicable($self) } map { $by_name{$_} } @$fb ];
  }
  if ( !$fb || $fb eq 'none' || $fb eq 'plain' ) {
    return [ grep { $_->name eq 'crawl4ai_plain' } @all ];
  }
  return [ grep { $_->applicable($self) } @all ];
}

sub _normalize_args {
  my ( $self, @args ) = @_;
  return ( $args[0] ) if @args == 1 && !ref $args[0];
  my %a = @args == 1 && ref $args[0] eq 'HASH' ? %{ $args[0] } : @args;
  my $url = delete $a{url};
  return ( $url, %a );
}

# Build the detect option hash (just min_markdown for now) from a per-call
# %opts plus the instance default. Shared with Net::Async::Crawl4AI.
sub _detect_opts {
  my ( $self, %opts ) = @_;
  my $min = defined $opts{min_markdown} ? $opts{min_markdown} : $self->min_markdown;
  return defined $min ? { min_markdown => $min } : {};
}

# Turn one strategy run — its page, error, and timing — into an Attempt,
# classifying the page via Detect. Shared with Net::Async::Crawl4AI so the sync
# and async chains build identical attempt history.
sub _attempt_for {
  my ( $self, $strategy, $page, $err, $elapsed, $detect ) = @_;
  $detect ||= {};
  return WWW::Crawl4AI::Attempt->new(
    backend    => $strategy->name,
    cost_class => $strategy->cost_class,
    ok         => 0,
    error      => $err,
    why_failed => 'error',
    elapsed    => $elapsed,
  ) if $err;
  return WWW::Crawl4AI::Attempt->new(
    backend    => $strategy->name,
    cost_class => $strategy->cost_class,
    ok         => 0,
    why_failed => 'empty',
    elapsed    => $elapsed,
  ) unless defined $page;

  my $good = WWW::Crawl4AI::Detect::is_good( $page, %$detect );
  return WWW::Crawl4AI::Attempt->new(
    backend    => $strategy->name,
    cost_class => $strategy->cost_class,
    ok         => $good,
    page       => $page,
    signals    => WWW::Crawl4AI::Detect::signals( $page, %$detect ),
    why_failed => ( $good ? undef : WWW::Crawl4AI::Detect::why_failed( $page, %$detect ) ),
    elapsed    => $elapsed,
  );
}

sub crawl {
  my ( $self, @args ) = @_;
  my ( $url, %opts ) = $self->_normalize_args(@args);
  croak "crawl needs a url" unless defined $url && length $url;
  my $detect = $self->_detect_opts(%opts);

  my @attempts;
  for my $strategy ( @{ $self->strategies } ) {
    my $t0   = Time::HiRes::time();
    my $page = eval { $strategy->crawl( $self, $url, %opts ) };
    my $err  = $@;
    my $elapsed = sprintf( '%.3f', Time::HiRes::time() - $t0 ) + 0;

    my $attempt = $self->_attempt_for( $strategy, $page, $err, $elapsed, $detect );
    push @attempts, $attempt;
    return WWW::Crawl4AI::Result->from_attempt( $attempt, attempts => \@attempts ) if $attempt->ok;
  }

  return $self->_failed_result( $url, \@attempts );
}

sub markdown { my ( $self, @args ) = @_; return $self->crawl(@args) }

sub _failed_result {
  my ( $self, $url, $attempts ) = @_;
  my $last = $attempts->[-1];
  return WWW::Crawl4AI::Result->new(
    ok       => 0,
    url      => $url,
    attempts => $attempts,
    error    => WWW::Crawl4AI::Error->new(
      type    => 'content',
      message => 'all crawl strategies failed',
      url     => $url,
    ),
    why_failed => 'no_strategies',
  ) unless $last;

  return WWW::Crawl4AI::Result->new(
    ok         => 0,
    url        => $url,
    final_url  => ( $last->page ? $last->page->{final_url} : undef ),
    status     => ( $last->page ? $last->page->{status_code} : undef ),
    backend    => $last->backend,
    cost_class => $last->cost_class,
    signals    => $last->signals,
    why_failed => $last->why_failed,
    attempts   => $attempts,
    error      => (
      $last->error || WWW::Crawl4AI::Error->new(
        type    => 'content',
        message => 'all crawl strategies failed (last: ' . ( $last->why_failed // 'unknown' ) . ')',
        url     => $url,
        backend => $last->backend,
      )
    ),
  );
}

sub health { $_[0]->client->health }

sub available_backends { [ map { $_->name } @{ $_[0]->strategies } ] }

sub detect {
  my ( $self ) = @_;
  return {
    crawl4ai         => $self->health,
    crawl4ai_url     => $self->base_url,
    cloakbrowser     => ( $self->cloakbrowser_url ? WWW::Crawl4AI::Detect::probe_cloakbrowser( $self->cloakbrowser_url ) : 0 ),
    cloakbrowser_url => $self->cloakbrowser_url,
    proxy            => ( $self->proxy_url ? 1 : 0 ),
    proxy_url        => $self->proxy_url,
    callback         => ( $self->callback ? 1 : 0 ),
    backends         => $self->available_backends,
  };
}

1;

=head1 SYNOPSIS

  use WWW::Crawl4AI;

  my $crawler = WWW::Crawl4AI->new(
    base_url         => 'http://localhost:11235',
    cloakbrowser_url => $ENV{CLOAKBROWSER_CDP_URL},  # optional
    proxy_url        => $ENV{CRAWL4AI_PROXY_URL},    # optional
    fallback         => 'auto',
  );

  my $result = $crawler->markdown('https://example.com');

  say $result->markdown;
  say $result->backend;       # crawl4ai_plain / crawl4ai_stealth / crawl4ai_cloakbrowser
  say $result->final_url;
  say $result->cost_class;    # cheap / browser / stealth / paid
  say $result->attempts_json;

=head1 DESCRIPTION

A Perl interface to a self-hosted L<Crawl4AI|https://github.com/unclecode/crawl4ai>
service that escalates crawling through a B<visible strategy chain> and returns
a normalized, agent-friendly L<WWW::Crawl4AI::Result>.

Crawl4AI does the fetch and Markdown extraction; C<WWW::Crawl4AI> decides
policy. Rather than hiding fallback inside Crawl4AI, every attempt is modelled
on the Perl side as a L<WWW::Crawl4AI::Attempt>, so a caller can see which
backend won, what it cost, and — on failure — exactly why.

=head2 The chain

C<markdown>/C<crawl> walk strategies in cost order and stop at the first result
that L<WWW::Crawl4AI::Detect> rates good:

  crawl4ai_plain        cheap     headless text mode
  crawl4ai_browser      browser   full JS render, wait for networkidle
  crawl4ai_stealth      stealth   enable_stealth + random user agent
  crawl4ai_cloakbrowser stealth   attach to CloakBrowser via cdp_url   (if configured)
  crawl4ai_proxy        paid      stealth via proxy_config             (if configured)
  external_callback     paid      user coderef                         (if configured)

For raw, single-shot REST access without the chain, use
L<WWW::Crawl4AI::Client> directly.

=attr base_url

Crawl4AI server URL. Default C<$ENV{CRAWL4AI_URL}>, then
C<$ENV{CRAWL4AI_BASE_URL}>, then C<http://localhost:11235>.

=attr api_token

Optional bearer token (C<$ENV{CRAWL4AI_API_TOKEN}>).

=attr cloakbrowser_url

CloakBrowser CDP endpoint (C<$ENV{CLOAKBROWSER_CDP_URL}>). When set, the
C<crawl4ai_cloakbrowser> strategy joins the chain.

=attr proxy_url

Proxy URL (C<$ENV{CRAWL4AI_PROXY_URL}>). When set, the C<crawl4ai_proxy>
strategy joins the chain.

=attr callback

Optional coderef, called as C<< ->($url, %opts) >> as the last resort; should
return a page-shaped hashref or C<undef>. When set, the C<external_callback>
strategy joins the chain.

=attr fallback

Chain selection: C<'auto'> (default; all applicable strategies),
C<'plain'>/C<'none'> (Plain only), or an arrayref of backend names to run in
that explicit order, e.g. C<['crawl4ai_plain', 'crawl4ai_stealth']>.

=attr timeout

Per-request timeout in seconds (default 120), passed to the client.

=attr min_markdown

Override the thin-content threshold (characters) for classification. Can also be
given per call as C<< markdown($url, min_markdown => N) >>.

=attr client

The underlying L<WWW::Crawl4AI::Client>. Lazily built from C<base_url> /
C<api_token> / C<timeout>; inject your own to share a UA or change transport.

=attr strategies

Arrayref of instantiated, applicable L<WWW::Crawl4AI::Strategy> objects in
execution order. Lazily built from L</fallback>.

=method markdown

=method crawl

  my $result = $crawler->markdown('https://example.com');
  my $result = $crawler->crawl( url => 'https://example.com' );

Run the strategy chain against one URL and return a L<WWW::Crawl4AI::Result>.
Both are the same chain; the result always carries both C<markdown> and C<html>.
Accepts a single positional URL or named arguments with a C<url> key.

=method health

True if the Crawl4AI server answers C<GET /health>.

=method available_backends

Arrayref of backend names currently in the chain.

=method detect

Hashref describing what the orchestrator can reach: C<crawl4ai>,
C<cloakbrowser>, C<proxy>, C<callback> and the active C<backends>. Used by
C<www-crawl4ai-doctor>.

=seealso

L<WWW::Crawl4AI::Client>, L<WWW::Crawl4AI::Result>, L<WWW::Crawl4AI::Detect>,
L<Net::Async::Crawl4AI>, L<https://github.com/unclecode/crawl4ai>

=cut
