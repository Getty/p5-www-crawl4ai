package WWW::Crawl4AI::Error;
# ABSTRACT: structured error class for WWW::Crawl4AI
use Moo;
use overload
  '""' => sub { $_[0]->message },
  bool => sub { 1 },
  fallback => 1;

our $VERSION = '0.001';

=head1 SYNOPSIS

  die WWW::Crawl4AI::Error->new(
    type        => 'api',
    message     => "HTTP 503: Service Unavailable",
    response    => $http_response,
    status_code => 503,
    backend     => 'crawl4ai_plain',
  );

  if (my $e = $@) {
    if (ref $e && $e->isa('WWW::Crawl4AI::Error')) {
      warn "crawl4ai failed (@{[ $e->type ]}): $e" if $e->is_api;
    }
  }

=head1 DESCRIPTION

Structured error thrown by L<WWW::Crawl4AI::Client> and the strategy chain.
Stringifies to its C<message> so it works as a drop-in replacement for a
string exception. Carries type, HTTP context, and the responsible backend so
callers can route on the specific kind of failure.

=cut

has type        => ( is => 'ro', required => 1 );

=attr type

One of C<transport>, C<api>, C<job>, C<content>. Required.

=over 4

=item C<transport> — could not reach the Crawl4AI server at all.

=item C<api> — the server responded with an HTTP error or malformed body.

=item C<job> — an async job finished with status C<FAILED>.

=item C<content> — every strategy ran but no result passed classification
(used as the error type of a failed L<WWW::Crawl4AI::Result>).

=back

=cut

has message     => ( is => 'ro', required => 1 );

=attr message

Human-readable error string. Required. The object stringifies to this.

=cut

has response    => ( is => 'ro' );

=attr response

The L<HTTP::Response> object, when available.

=cut

has data        => ( is => 'ro' );

=attr data

The decoded JSON payload, when available.

=cut

has status_code => ( is => 'ro' );

=attr status_code

HTTP status code of the Crawl4AI response (0 for pure transport failures).

=cut

has url         => ( is => 'ro' );

=attr url

Target URL, when the error is tied to one.

=cut

has backend     => ( is => 'ro' );

=attr backend

Name of the strategy backend that produced the error, e.g. C<crawl4ai_plain>.

=cut

has attempt     => ( is => 'ro' );

=attr attempt

1-based attempt counter, populated when retry was involved.

=cut

sub is_transport { $_[0]->type eq 'transport' }
sub is_api       { $_[0]->type eq 'api' }
sub is_job       { $_[0]->type eq 'job' }
sub is_content   { $_[0]->type eq 'content' }

=method is_transport

=method is_api

=method is_job

=method is_content

Boolean accessors, each returns true when L</type> matches.

=cut

1;
