package WWW::Crawl4AI::Client;
# ABSTRACT: UA-agnostic REST client for the Crawl4AI Docker API
use Moo;
use Carp qw( croak );
use HTTP::Request ();
use LWP::UserAgent ();
use JSON::MaybeXS ();
use URI ();
use URI::Escape ();
use MIME::Base64 ();
use Safe::Isa;
use WWW::Crawl4AI::Markdown qw( resolve_markdown_chain );
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

Covered endpoints: C<crawl> (C</crawl>), C<md> (C</md>), C<job_submit> /
C<job_status> (C</crawl/job>), C<health>, plus the single-URL action endpoints
C<screenshot>, C<pdf>, C<html>, C<execute_js>, C<llm> and C<token>.

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

sub screenshot_request {
  my ( $self, $url, %opts ) = @_;
  croak "screenshot_request needs a url" unless defined $url && length $url;
  my %body = ( url => $url );
  $body{screenshot_wait_for} = $opts{wait_for}    if defined $opts{wait_for};
  $body{output_path}         = $opts{output_path} if defined $opts{output_path};
  $body{wait_for_images} =
    $opts{wait_for_images} ? WWW::Crawl4AI::Request::JSON_true() : WWW::Crawl4AI::Request::JSON_false()
    if exists $opts{wait_for_images};
  return $self->_request( POST => '/screenshot', \%body );
}

=method screenshot_request

=method pdf_request

=method html_request

=method execute_js_request

=method llm_request

=method token_request

Build the L<HTTP::Request> for each of the single-URL action endpoints without
performing I/O. C<screenshot_request> accepts C<wait_for> (seconds),
C<wait_for_images> (bool) and C<output_path>; C<pdf_request> accepts
C<output_path>; C<execute_js_request> takes a script string or arrayref;
C<llm_request> takes a query plus optional C<provider>/C<temperature>/C<base_url>.

=cut

sub pdf_request {
  my ( $self, $url, %opts ) = @_;
  croak "pdf_request needs a url" unless defined $url && length $url;
  my %body = ( url => $url );
  $body{output_path} = $opts{output_path} if defined $opts{output_path};
  return $self->_request( POST => '/pdf', \%body );
}

sub html_request {
  my ( $self, $url ) = @_;
  croak "html_request needs a url" unless defined $url && length $url;
  return $self->_request( POST => '/html', { url => $url } );
}

sub execute_js_request {
  my ( $self, $url, $scripts ) = @_;
  croak "execute_js_request needs a url" unless defined $url && length $url;
  $scripts = [$scripts] unless ref $scripts eq 'ARRAY';
  croak "execute_js_request needs at least one script" unless @$scripts && defined $scripts->[0];
  return $self->_request( POST => '/execute_js', { url => $url, scripts => $scripts } );
}

sub llm_request {
  my ( $self, $url, $query, %opts ) = @_;
  croak "llm_request needs a url"   unless defined $url   && length $url;
  croak "llm_request needs a query" unless defined $query && length $query;
  # The page URL is a path segment ({url:path}); escape it so its own scheme and
  # query string don't merge into ours. The question and tuning go in the query.
  my $path = URI->new( '/llm/' . URI::Escape::uri_escape_utf8($url) );
  $path->query_form(
    q => $query,
    ( defined $opts{provider}    ? ( provider    => $opts{provider} )    : () ),
    ( defined $opts{temperature} ? ( temperature => $opts{temperature} ) : () ),
    ( defined $opts{base_url}    ? ( base_url     => $opts{base_url} )    : () ),
  );
  return $self->_request( GET => $path->as_string );
}

sub token_request {
  my ( $self, $email, %opts ) = @_;
  croak "token_request needs an email" unless defined $email && length $email;
  my %body = ( email => $email );
  $body{api_token} = $opts{api_token} if defined $opts{api_token};
  return $self->_request( POST => '/token', \%body );
}

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

sub parse_screenshot_response {
  my ( $self, $res, $backend ) = @_;
  return $self->_decode_b64_artifact( $self->_decode( $res, $backend ), 'screenshot', $backend );
}

=method parse_screenshot_response

=method parse_pdf_response

Decode the C<{ success, screenshot|pdf }> response and return the B<raw bytes>
(the base64 payload decoded), ready to write to a file. Throw a C<type=content>
L<WWW::Crawl4AI::Error> when the server reports failure or returns no artifact.

=cut

sub parse_pdf_response {
  my ( $self, $res, $backend ) = @_;
  return $self->_decode_b64_artifact( $self->_decode( $res, $backend ), 'pdf', $backend );
}

# /screenshot and /pdf return { success => bool, <key> => base64 }. Decode to raw
# bytes; raise a content error if the server reported nothing usable.
sub _decode_b64_artifact {
  my ( $self, $data, $key, $backend ) = @_;
  my $b64 = ref $data eq 'HASH' ? $data->{$key} : undef;
  unless ( defined $b64 && length $b64 ) {
    die WWW::Crawl4AI::Error->new(
      type    => 'content',
      message => "Crawl4AI returned no $key",
      data    => $data,
      backend => $backend,
    );
  }
  return MIME::Base64::decode_base64($b64);
}

sub parse_html_response {
  my ( $self, $res, $backend ) = @_;
  my $data = $self->_decode( $res, $backend );
  return ref $data eq 'HASH' ? $data->{html} : $data;
}

=method parse_html_response

Decode the C<{ html, url, success }> response and return the preprocessed HTML
string.

=cut

sub parse_execute_js_response {
  my ( $self, $res, $backend ) = @_;
  my $data = $self->_decode( $res, $backend );
  # /execute_js returns a single crawl result (same shape as one /crawl page)
  # with the script output added under js_execution_result.
  my $page = $self->_normalize_page( ref $data eq 'HASH' ? $data : { raw => $data } );
  $page->{js_result} = ref $data eq 'HASH' ? $data->{js_execution_result} : undef;
  return $page;
}

=method parse_execute_js_response

Decode the C</execute_js> response into a normalized page (the same shape
L</parse_crawl_response> produces) with the script return values added under
C<js_result>.

=cut

sub parse_llm_response {
  my ( $self, $res, $backend ) = @_;
  my $data = $self->_decode( $res, $backend );
  return ref $data eq 'HASH' ? ( $data->{answer} // $data->{result} // $data ) : $data;
}

=method parse_llm_response

Decode the C</llm> response and return the answer text (the C<answer> field
when present).

=cut

sub parse_token_response {
  my ( $self, $res, $backend ) = @_;
  return $self->_decode( $res, $backend );
}

=method parse_token_response

Decode the C</token> response into C<< { email, access_token, token_type } >>.

=cut

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
    success          => $page->{success},
    url              => $meta->{sourceURL} // $page->{url} // $meta->{url},
    final_url        => $page->{redirected_url} // $page->{url} // $meta->{url},
    status_code      => $page->{status_code} // $page->{status} // $meta->{statusCode},
    markdown         => $self->_extract_markdown($page),
    html             => $page->{cleaned_html} // $page->{html},
    raw_html         => $page->{html},
    title            => $meta->{title},
    links            => $self->_extract_links($page),
    metadata         => $meta,
    error            => $page->{error_message} // $page->{error},
    response_headers => $self->_lc_headers( $page->{response_headers} ),
    raw              => $page,
  };
}

# Lowercase all header keys for deterministic, case-insensitive matching by callers.
sub _lc_headers {
  my ( $self, $h ) = @_;
  return {} unless ref $h eq 'HASH';
  return { map { lc($_) => $h->{$_} } keys %$h };
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
  return resolve_markdown_chain( $page->{markdown} );
}

#----------------------------------------------------------------------
# I/O + retry
#----------------------------------------------------------------------

sub do_request {
  my ( $self, $req, $backend ) = @_;
  croak "do_request needs an HTTP::Request" unless $self->is_request($req);
  my $max = $self->max_attempts;
  my $res;
  my $is_transport = sub {
    my $r = shift;
    return $r->code == 599 || ( ( $r->header('Client-Warning') // '' ) eq 'Internal response' );
  };
  for my $attempt ( 1 .. $max ) {
    $res = $self->ua->request($req);
    last if $res->is_success;
    my $code = $res->code;
    my $transport = $is_transport->($res);
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
  if ( !$res->is_success && $is_transport->($res) ) {
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

sub screenshot {
  my ( $self, $url, %opts ) = @_;
  return $self->parse_screenshot_response( $self->do_request( $self->screenshot_request( $url, %opts ) ) );
}

=method screenshot

  my $png = $client->screenshot( $url, wait_for => 2, wait_for_images => 1 );
  open my $fh, '>:raw', 'shot.png'; print $fh $png;

=method pdf

  my $pdf = $client->pdf($url);

C<POST /screenshot> and C<POST /pdf>: render the page and return the raw image
or PDF B<bytes> (decoded from the base64 the server sends).

=method html

  my $html = $client->html($url);

C<POST /html>: the server-preprocessed (sanitized) HTML as a string.

=method execute_js

  my $page = $client->execute_js( $url, 'return document.title' );
  my $page = $client->execute_js( $url, [ 'window.scrollTo(0,9e9)', 'return document.title' ] );
  print $page->{js_result}{results}[0];

C<POST /execute_js>: run one or more JS snippets in the page and return a
normalized page (as L</crawl>) with the raw script output under C<js_result>
(C<< { results => [ ... ], success => bool } >>).

=method llm

  my $answer = $client->llm( $url, 'Who is the author?' );

C<GET /llm/{url}>: ask an LLM a question about the page. Requires the Crawl4AI
server to have an LLM provider configured (e.g. C<OPENAI_API_KEY>); optional
C<provider>, C<temperature> and C<base_url> are forwarded.

=method token

  my $tok = $client->token('me@example.com');   # { access_token, token_type, ... }

C<POST /token>: obtain a JWT from a server with auth enabled. Feed
C<< $tok->{access_token} >> back as L</api_token>.

=cut

sub pdf {
  my ( $self, $url, %opts ) = @_;
  return $self->parse_pdf_response( $self->do_request( $self->pdf_request( $url, %opts ) ) );
}

sub html {
  my ( $self, $url ) = @_;
  return $self->parse_html_response( $self->do_request( $self->html_request($url) ) );
}

sub execute_js {
  my ( $self, $url, $scripts ) = @_;
  return $self->parse_execute_js_response( $self->do_request( $self->execute_js_request( $url, $scripts ) ) );
}

sub llm {
  my ( $self, $url, $query, %opts ) = @_;
  return $self->parse_llm_response( $self->do_request( $self->llm_request( $url, $query, %opts ) ) );
}

sub token {
  my ( $self, $email, %opts ) = @_;
  return $self->parse_token_response( $self->do_request( $self->token_request( $email, %opts ) ) );
}

=seealso

L<WWW::Crawl4AI>, L<WWW::Crawl4AI::Request>, L<WWW::Crawl4AI::Error>

=cut

1;
