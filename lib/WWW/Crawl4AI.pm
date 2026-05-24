package WWW::Crawl4AI;
# ABSTRACT: Perl client and fallback orchestrator for Crawl4AI
use Moo;
use Carp qw( croak );
use Time::HiRes ();
use URI ();
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

=cut

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

=attr base_url

Crawl4AI server URL. Default C<$ENV{CRAWL4AI_URL}>, then
C<$ENV{CRAWL4AI_BASE_URL}>, then C<http://localhost:11235>.

=cut

has api_token => (
  is      => 'ro',
  default => sub { $ENV{CRAWL4AI_API_TOKEN} },
);

=attr api_token

Optional bearer token (C<$ENV{CRAWL4AI_API_TOKEN}>).

=cut

has cloakbrowser_url => (
  is      => 'ro',
  default => sub { $ENV{CLOAKBROWSER_CDP_URL} },
);

=attr cloakbrowser_url

CloakBrowser CDP endpoint (C<$ENV{CLOAKBROWSER_CDP_URL}>). When set, the
C<crawl4ai_cloakbrowser> strategy joins the chain.

=cut

has proxy_url => (
  is      => 'ro',
  default => sub { $ENV{CRAWL4AI_PROXY_URL} },
);

=attr proxy_url

Proxy URL (C<$ENV{CRAWL4AI_PROXY_URL}>). When set, the C<crawl4ai_proxy>
strategy joins the chain.

=cut

has callback => ( is => 'ro' );

=attr callback

Optional coderef, called as C<< ->($url, %opts) >> as the last resort; should
return a page-shaped hashref or C<undef>. When set, the C<external_callback>
strategy joins the chain.

=cut

# 'auto' (full applicable chain), 'plain'/'none' (Plain only), or an arrayref
# of backend names to run in that explicit order.
has fallback => ( is => 'ro', default => sub { 'auto' } );

=attr fallback

Chain selection: C<'auto'> (default; all applicable strategies),
C<'plain'>/C<'none'> (Plain only), or an arrayref of backend names to run in
that explicit order, e.g. C<['crawl4ai_plain', 'crawl4ai_stealth']>.

=cut

has timeout      => ( is => 'ro', default => sub { 120 } );

=attr timeout

Per-request timeout in seconds (default 120), passed to the client.

=cut

has min_markdown => ( is => 'ro' );

=attr min_markdown

Override the thin-content threshold (characters) for classification. Can also be
given per call as C<< markdown($url, min_markdown => N) >>.

=cut

has client => ( is => 'lazy' );

=attr client

The underlying L<WWW::Crawl4AI::Client>. Lazily built from C<base_url> /
C<api_token> / C<timeout>; inject your own to share a UA or change transport.

=cut

sub _build_client {
  my ( $self ) = @_;
  return WWW::Crawl4AI::Client->new(
    base_url  => $self->base_url,
    api_token => $self->api_token,
    timeout   => $self->timeout,
  );
}

has strategies => ( is => 'lazy' );

=attr strategies

Arrayref of instantiated, applicable L<WWW::Crawl4AI::Strategy> objects in
execution order. Lazily built from L</fallback>.

=cut

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
  return () unless @args;
  # a single hashref: { url => ..., %opts }
  if ( @args == 1 && ref $args[0] eq 'HASH' ) {
    my %a   = %{ $args[0] };
    my $url = delete $a{url};
    return ( $url, %a );
  }
  # a leading positional URL, optionally followed by named options
  if ( @args % 2 == 1 && !ref $args[0] ) {
    my ( $url, %a ) = @args;
    return ( $url, %a );
  }
  # all named: ( url => ..., %opts )
  my %a   = @args;
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

=method crawl

=method markdown

  my $result = $crawler->markdown('https://example.com');
  my $result = $crawler->crawl( url => 'https://example.com' );

Run the strategy chain against one URL and return a L<WWW::Crawl4AI::Result>.
Both are the same chain; the result always carries both C<markdown> and C<html>.
Accepts a single positional URL or named arguments with a C<url> key.

The returned C<Result> is never C<undef> — on total failure C<< $r->ok >> is
false, C<< $r->why_failed >> explains the last attempt, and C<< $r->attempts >>
holds the full history.

=cut

sub markdown { my ( $self, @args ) = @_; return $self->crawl(@args) }

# Drop the fragment so map apps (#5/lat/lon/...) and trailing-anchor links don't
# look like distinct pages during dedup.
sub _canon_url {
  my ( $self, $url ) = @_;
  my $u = eval { URI->new($url) } or return $url;
  $u->fragment(undef);
  return $u->as_string;
}

sub deep_crawl {
  my ( $self, @args ) = @_;
  my ( $start, %opts ) = $self->_normalize_args(@args);
  croak "deep_crawl needs a url" unless defined $start && length $start;

  my $max_pages  = exists $opts{max_pages}  ? delete $opts{max_pages}  : 25;
  my $max_depth  = exists $opts{max_depth}  ? delete $opts{max_depth}  : 2;
  my $same_host  = exists $opts{same_host}  ? delete $opts{same_host}  : 1;
  my $on_page    = delete $opts{on_page};     # coderef ($result, $depth)
  my $url_filter = delete $opts{url_filter};  # coderef ($url) -> bool

  my $start_host;  # locked onto the host the start URL actually resolved to
  my %seen       = ( $self->_canon_url($start) => 1 );
  my @queue      = ( { url => $start, depth => 0 } );
  my @results;

  while ( @queue && @results < $max_pages ) {
    my $node   = shift @queue;
    my $result = $self->crawl( $node->{url}, %opts );
    push @results, $result;
    $on_page->( $result, $node->{depth} ) if $on_page;

    # Take the host from the first crawl's final_url, so a scheme-less start URL
    # or a redirect to www. doesn't make same_host reject every link.
    $start_host //= lc( eval { URI->new( $result->final_url // $node->{url} )->host } // '' );

    next if $node->{depth} >= $max_depth;
    next unless $result->ok;

    for my $url ( @{ $result->urls } ) {
      my $canon = $self->_canon_url($url);
      next if $seen{$canon}++;
      if ($same_host) {
        my $host = lc( eval { URI->new($url)->host } // '' );
        next unless $host eq $start_host;
      }
      next if $url_filter && !$url_filter->($url);
      push @queue, { url => $url, depth => $node->{depth} + 1 };
    }
  }

  return \@results;
}

=method deep_crawl

  my $results = $crawler->deep_crawl('https://example.com');
  my $results = $crawler->deep_crawl(
    'https://example.com',
    max_pages  => 50,
    max_depth  => 3,
    same_host  => 1,
    url_filter => sub { $_[0] !~ m{/login} },
    on_page    => sub { my ( $result, $depth ) = @_; ... },
    min_markdown => 200,            # any crawl() option is forwarded
  );

Breadth-first crawl that follows the L<WWW::Crawl4AI::Result/urls> of each good
page. Each page goes through the full strategy chain, so C<deep_crawl> is just
L</crawl> applied across a frontier — the per-page escalation and attempt
history are unchanged.

Returns an arrayref of L<WWW::Crawl4AI::Result> in visit order (the first is the
start URL). URLs are deduplicated with the fragment stripped, so map-style
C<#lat/lon> anchors don't count as separate pages. Options:

=over

=item C<max_pages> (default C<25>) — hard cap on pages crawled.

=item C<max_depth> (default C<2>) — link-following depth; the start URL is depth C<0>.

=item C<same_host> (default true) — only follow links on the start URL's host.

=item C<url_filter> — coderef C<< ($url) -> bool >>; return false to skip a URL.

=item C<on_page> — coderef C<< ($result, $depth) >> called as each page completes (for streaming or progress).

=back

Any remaining options (such as C<min_markdown>) are forwarded to each
L</crawl>. Note that the strategy chain is fixed per crawler instance — a
per-call C<fallback> is B<not> honoured here; set it on the constructor.

=cut

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

=method health

True if the Crawl4AI server answers C<GET /health>.

=cut

sub available_backends { [ map { $_->name } @{ $_[0]->strategies } ] }

=method available_backends

Arrayref of backend names currently in the chain.

=cut

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

=method detect

Hashref describing what the orchestrator can reach: C<crawl4ai>,
C<cloakbrowser>, C<proxy>, C<callback> and the active C<backends>. Used by
C<www-crawl4ai-doctor>.

=cut

=seealso

L<WWW::Crawl4AI::Client>, L<WWW::Crawl4AI::Result>, L<WWW::Crawl4AI::Detect>,
L<Net::Async::Crawl4AI>, L<https://github.com/unclecode/crawl4ai>

=cut

1;
