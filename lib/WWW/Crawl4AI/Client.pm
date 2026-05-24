package WWW::Crawl4AI::Client;
# ABSTRACT: UA-agnostic REST client for the Crawl4AI Docker API
use Moo;
use Carp qw( croak );
use HTTP::Request ();
use JSON::MaybeXS ();
use URI ();
use Safe::Isa;
use WWW::Crawl4AI::Request ();
use WWW::Crawl4AI::Error ();

our $VERSION = '0.001';

=head1 SYNOPSIS

  my $client = WWW::Crawl4AI::Client->new( base_url => 'http://localhost:11235' );

  my $pages = $client->crawl(
    WWW::Crawl4AI::Request->new( urls => 'https://example.com' )
  );
  print $pages->[0]{markdown};

  my $job = $client->job_submit($request);
  my $st  = $client->job_status( $job->{task_id} );   # { status => 'COMPLETED', pages => [...] }

=head1 DESCRIPTION

A thin, UA-agnostic wrapper over the Crawl4AI Docker REST API (default port
11235). Every endpoint comes in three flavours:

  foo_request(...)          → builds an HTTP::Request (no I/O)
  parse_foo_response($res)  → decodes/normalizes (no I/O)
  foo(...)                  → convenience: build + fire (LWP, with retry) + parse

Page results are normalized to a flat hash (C<url>, C<final_url>,
C<status_code>, C<markdown>, C<html>, C<title>, C<metadata>, C<error>, C<raw>)
across the several response shapes Crawl4AI has used.

=cut

has base_url => (
  is      => 'ro',
  default => sub { $ENV{CRAWL4AI_URL} || $ENV{CRAWL4AI_BASE_URL} || 'http://localhost:11235' },
);

=attr base_url

Crawl4AI server URL. Defaults to C<$ENV{CRAWL4AI_URL}>, then
C<$ENV{CRAWL4AI_BASE_URL}>, then C<http://localhost:11235>.

=cut

has api_token => (
  is      => 'ro',
  default => sub { $ENV{CRAWL4AI_API_TOKEN} },
);

=attr api_token

Optional bearer token (C<$ENV{CRAWL4AI_API_TOKEN}>). Only needed when the
server has JWT auth enabled.

=cut

has _json => (
  is      => 'lazy',
  default => sub { JSON::MaybeXS->new( utf8 => 1, canonical => 1, convert_blessed => 1 ) },
);

has user_agent_string => (
  is      => 'ro',
  default => sub { "WWW-Crawl4AI/$VERSION" },
);

=attr user_agent_string

The C<User-Agent> string sent with every request (default
C<< WWW-Crawl4AI/$VERSION >>). L<Net::Async::Crawl4AI> reads this to configure
its L<Net::Async::HTTP>.

=cut

has timeout => ( is => 'ro', default => sub { 120 } );

=attr timeout

LWP request timeout in seconds (default 120). Crawling can be slow.

=cut

has ua => ( is => 'lazy' );

=attr ua

The L<LWP::UserAgent>. Lazily built; inject your own to swap transports.

=cut

has max_attempts   => ( is => 'ro', default => sub { 3 } );

=attr max_attempts

Number of request attempts before giving up (default 3). Retries apply to
transport failures and retryable HTTP statuses (see L</retry_statuses>).

=cut

has retry_backoff  => ( is => 'ro', default => sub { [ 1, 2, 4 ] } );

=attr retry_backoff

Arrayref of inter-attempt delays in seconds (default C<[1, 2, 4]>). The last
value is reused when there are more retries than entries. Overridden by a
numeric C<Retry-After> header.

=cut

has retry_statuses => ( is => 'ro', default => sub { [ 429, 502, 503, 504 ] } );

=attr retry_statuses

Arrayref of HTTP status codes that trigger a retry (default
C<[429, 502, 503, 504]>).

=cut

has on_retry       => ( is => 'ro' );

=attr on_retry

Optional CodeRef called before each retry, with C<($attempt, $delay, $response)>.
Useful for logging.

=cut

has sleep_sub => (
  is      => 'ro',
  default => sub {
    require Time::HiRes;
    return sub { Time::HiRes::sleep( $_[0] ) };
  },
);

=attr sleep_sub

CodeRef that performs the inter-attempt sleep. Defaults to
C<Time::HiRes::sleep>. Override in tests to avoid wall-clock delays.

=cut

has _retry_status_set => ( is => 'lazy' );
sub _build__retry_status_set {
  return { map { $_ => 1 } @{ $_[0]->retry_statuses } };
}

sub _build_ua {
  my ( $self ) = @_;
  require LWP::UserAgent;
  return LWP::UserAgent->new(
    agent   => $self->user_agent_string,
    timeout => $self->timeout,
  );
}

sub is_request { $_[1]->$_isa('HTTP::Request') }

=method is_request

True if the argument is an L<HTTP::Request>.

=cut

sub _uri {
  my ( $self, $path ) = @_;
  ( my $base = $self->base_url ) =~ s{/+$}{};
  return URI->new( $base . $path );
}

sub _request {
  my ( $self, $method, $path, $body ) = @_;
  my $req = HTTP::Request->new( $method => $self->_uri($path) );
  $req->header( Accept => 'application/json' );
  $req->header( Authorization => 'Bearer ' . $self->api_token ) if defined $self->api_token;
  if ( defined $body ) {
    $req->header( 'Content-Type' => 'application/json' );
    $req->content( $self->_json->encode($body) );
  }
  return $req;
}

#----------------------------------------------------------------------
# Request builders (no I/O)
#----------------------------------------------------------------------

sub crawl_request {
  my ( $self, $request ) = @_;
  return $self->_request( POST => '/crawl', $self->_payload( $request, 'to_crawl_payload' ) );
}

=method crawl_request

=method md_request

=method job_submit_request

=method job_status_request

=method health_request

Build the L<HTTP::Request> for each endpoint without performing I/O.

=cut

sub md_request {
  my ( $self, $request ) = @_;
  return $self->_request( POST => '/md', $self->_payload( $request, 'to_md_payload' ) );
}

sub job_submit_request {
  my ( $self, $request ) = @_;
  return $self->_request( POST => '/crawl/job', $self->_payload( $request, 'to_crawl_payload' ) );
}

sub job_status_request {
  my ( $self, $task_id ) = @_;
  croak "job_status_request needs a task_id" unless defined $task_id && length $task_id;
  return $self->_request( GET => '/crawl/job/' . $task_id );
}

sub health_request { $_[0]->_request( GET => '/health' ) }

sub _payload {
  my ( $self, $request, $method ) = @_;
  return $request->$method if $request->$_isa('WWW::Crawl4AI::Request');
  return $request if ref $request eq 'HASH';
  croak "expected a WWW::Crawl4AI::Request or hashref payload";
}

#----------------------------------------------------------------------
# Response parsers (no I/O)
#----------------------------------------------------------------------

sub _decode {
  my ( $self, $res, $backend ) = @_;
  my $code = $res->code;
  my $body = $res->decoded_content // $res->content // '';
  my $data = eval { length $body ? $self->_json->decode($body) : undef };
  if ( !$res->is_success ) {
    die WWW::Crawl4AI::Error->new(
      type        => 'api',
      message     => "Crawl4AI HTTP $code: " . ( $res->message // 'error' ),
      response    => $res,
      data        => $data,
      status_code => $code,
      backend     => $backend,
    );
  }
  return $data;
}

sub parse_crawl_response {
  my ( $self, $res, $backend ) = @_;
  my $data = $self->_decode( $res, $backend );
  return [ map { $self->_normalize_page($_) } @{ $self->_result_list($data) } ];
}

=method parse_crawl_response

=method parse_md_response

=method parse_job_submit_response

=method parse_job_status_response

=method parse_health_response

Decode and normalize a response. They throw a L<WWW::Crawl4AI::Error> on API,
transport or job failures.

=cut

sub parse_md_response {
  my ( $self, $res, $backend ) = @_;
  my $data = $self->_decode( $res, $backend );
  return $data if !ref $data;
  # /md commonly returns { markdown => ... } or { result => ... }
  return $data->{markdown} // $data->{result} // $data->{md} // $data;
}

sub parse_job_submit_response {
  my ( $self, $res, $backend ) = @_;
  my $data = $self->_decode( $res, $backend );
  my $id = $data->{task_id} // $data->{job_id} // $data->{id};
  croak "Crawl4AI job submit returned no task_id" unless defined $id;
  return { task_id => $id, raw => $data };
}

sub parse_job_status_response {
  my ( $self, $res, $backend ) = @_;
  my $data = $self->_decode( $res, $backend );
  my $status = uc( $data->{status} // $data->{state} // 'UNKNOWN' );
  my $pages;
  if ( $status eq 'COMPLETED' ) {
    my $results = $data->{results} // $data->{result} // $data->{data};
    $pages = [ map { $self->_normalize_page($_) } @{ $self->_result_list($results) } ]
      if defined $results;
  }
  if ( $status eq 'FAILED' ) {
    die WWW::Crawl4AI::Error->new(
      type    => 'job',
      message => "Crawl4AI job failed: " . ( $data->{error} // $data->{detail} // 'unknown' ),
      data    => $data,
      backend => $backend,
    );
  }
  return { status => $status, pages => $pages, raw => $data };
}

sub parse_health_response {
  my ( $self, $res ) = @_;
  return 0 unless $res->is_success;
  my $data = eval { $self->_json->decode( $res->decoded_content // '' ) };
  return $data if ref $data;
  return 1;
}

# Crawl4AI has returned the page list in several shapes across versions;
# accept all of them rather than pin to one.
sub _result_list {
  my ( $self, $data ) = @_;
  return [] unless defined $data;
  return $data if ref $data eq 'ARRAY';
  if ( ref $data eq 'HASH' ) {
    for my $key (qw( results data result )) {
      my $v = $data->{$key} or next;
      return $v if ref $v eq 'ARRAY';
      return [$v] if ref $v eq 'HASH';
    }
    # Looks like a single page itself.
    return [$data] if exists $data->{markdown} || exists $data->{html} || exists $data->{success};
  }
  return [];
}

sub _normalize_page {
  my ( $self, $page ) = @_;
  return { raw => $page } unless ref $page eq 'HASH';
  my $meta = $page->{metadata} || {};
  return {
    success      => $page->{success},
    url          => $meta->{sourceURL} // $page->{url} // $meta->{url},
    final_url    => $page->{redirected_url} // $page->{url} // $meta->{url},
    status_code  => $page->{status_code} // $page->{status} // $meta->{statusCode},
    markdown     => $self->_extract_markdown($page),
    html         => $page->{cleaned_html} // $page->{html},
    raw_html     => $page->{html},
    title        => $meta->{title},
    links        => $self->_extract_links($page),
    metadata     => $meta,
    error        => $page->{error_message} // $page->{error},
    raw          => $page,
  };
}

# Crawl4AI returns links as { internal => [...], external => [...] }, each entry
# a hash with href/text/title (older servers may send bare strings). Normalize
# to a stable { internal => [{href,text,title}], external => [...] } shape so the
# Result can expose them without callers reaching into raw.
sub _extract_links {
  my ( $self, $page ) = @_;
  my $links = $page->{links};
  return { internal => [], external => [] } unless ref $links eq 'HASH';
  return {
    internal => $self->_normalize_link_list( $links->{internal} ),
    external => $self->_normalize_link_list( $links->{external} ),
  };
}

sub _normalize_link_list {
  my ( $self, $list ) = @_;
  return [] unless ref $list eq 'ARRAY';
  return [ map { $self->_normalize_link($_) } @$list ];
}

sub _normalize_link {
  my ( $self, $link ) = @_;
  return { href => $link } unless ref $link eq 'HASH';
  my $text = $link->{text};
  $text = undef unless defined $text && length $text;
  return {
    href  => $link->{href},
    text  => $text,
    title => $link->{title},
  };
}

# markdown is a plain string on old servers and a structured object on new ones.
# fit_markdown is preferred but is frequently an empty string (no content
# filter matched), so skip empty candidates instead of stopping at the first
# defined one.
sub _extract_markdown {
  my ( $self, $page ) = @_;
  my $md = $page->{markdown};
  return $md unless ref $md eq 'HASH';
  for my $key (qw( fit_markdown raw_markdown markdown_with_citations markdown )) {
    my $value = $md->{$key};
    return $value if defined $value && length $value;
  }
  return undef;
}

#----------------------------------------------------------------------
# I/O + retry
#----------------------------------------------------------------------

sub do_request {
  my ( $self, $req, $backend ) = @_;
  croak "do_request needs an HTTP::Request" unless $self->is_request($req);
  my $max = $self->max_attempts;
  my $res;
  for my $attempt ( 1 .. $max ) {
    $res = $self->ua->request($req);
    last if $res->is_success;
    my $code = $res->code;
    my $transport = $code == 599 || $res->header('Client-Warning') // '' eq 'Internal response';
    my $retryable = $transport || $self->_retry_status_set->{$code};
    if ( $retryable && $attempt < $max ) {
      my $delay = $self->retry_backoff->[ $attempt - 1 ] // $self->retry_backoff->[-1] // 1;
      if ( my $ra = $res->header('Retry-After') ) {
        $delay = $ra if $ra =~ /^\d+$/;
      }
      $self->on_retry->( $attempt, $delay, $res ) if $self->on_retry;
      $self->sleep_sub->($delay);
      next;
    }
    last;
  }
  if ( !$res->is_success && ( $res->code == 599 ) ) {
    die WWW::Crawl4AI::Error->new(
      type        => 'transport',
      message     => "Crawl4AI transport error: " . ( $res->content // $res->message // 'unreachable' ),
      response    => $res,
      status_code => 0,
      backend     => $backend,
    );
  }
  return $res;
}

=method do_request

Fire an L<HTTP::Request> through the UA with the retry policy applied. Returns
the L<HTTP::Response>; throws a C<type=transport> L<WWW::Crawl4AI::Error> on
persistent connection failure.

=cut

#----------------------------------------------------------------------
# Convenience (build + fire + parse)
#----------------------------------------------------------------------

sub crawl {
  my ( $self, $request, $backend ) = @_;
  return $self->parse_crawl_response( $self->do_request( $self->crawl_request($request), $backend ), $backend );
}

=method crawl

=method md

=method job_submit

=method job_status

=method health

Convenience methods: build request, fire via L<LWP::UserAgent>, parse response.
See the C<*_request>/C<parse_*_response> pairs for the no-I/O building blocks.

=cut

sub md {
  my ( $self, $url, %opts ) = @_;
  my $request = $url->$_isa('WWW::Crawl4AI::Request')
    ? $url
    : WWW::Crawl4AI::Request->new( urls => $url, %opts );
  return $self->parse_md_response( $self->do_request( $self->md_request($request) ) );
}

sub job_submit {
  my ( $self, $request ) = @_;
  return $self->parse_job_submit_response( $self->do_request( $self->job_submit_request($request) ) );
}

sub job_status {
  my ( $self, $task_id ) = @_;
  return $self->parse_job_status_response( $self->do_request( $self->job_status_request($task_id) ) );
}

sub health {
  my ( $self ) = @_;
  my $res = eval { $self->do_request( $self->health_request ) };
  return 0 if $@ || !$res;
  return $self->parse_health_response($res) ? 1 : 0;
}

=seealso

L<WWW::Crawl4AI>, L<WWW::Crawl4AI::Request>, L<WWW::Crawl4AI::Error>

=cut

1;
