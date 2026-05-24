package WWW::Crawl4AI::Result;
# ABSTRACT: normalized result of a WWW::Crawl4AI strategy chain
use Moo;
use JSON::MaybeXS ();

our $VERSION = '0.001';

has ok         => ( is => 'ro', default => sub { 0 } );
has url        => ( is => 'ro' );
has final_url  => ( is => 'ro' );
has status     => ( is => 'ro' );
has markdown   => ( is => 'ro' );
has html       => ( is => 'ro' );
has title      => ( is => 'ro' );
has backend    => ( is => 'ro' );
has cost_class => ( is => 'ro' );
has signals    => ( is => 'ro', default => sub { {} } );
has why_failed => ( is => 'ro' );
has error      => ( is => 'ro' );
has attempts   => ( is => 'ro', default => sub { [] } );

has _json => (
  is      => 'lazy',
  default => sub { JSON::MaybeXS->new( utf8 => 0, canonical => 1, convert_blessed => 1 ) },
);

sub from_attempt {
  my ( $class, $attempt, %extra ) = @_;
  my $page = $attempt->page || {};
  return $class->new(
    ok         => $attempt->ok,
    url        => $page->{url},
    final_url  => $page->{final_url} // $page->{url},
    status     => $page->{status_code},
    markdown   => $page->{markdown},
    html       => $page->{html},
    title      => $page->{title},
    backend    => $attempt->backend,
    cost_class => $attempt->cost_class,
    signals    => $attempt->signals,
    why_failed => $attempt->why_failed,
    %extra,
  );
}

sub attempt_count { scalar @{ $_[0]->attempts } }

sub to_hash {
  my ( $self ) = @_;
  return {
    ok         => $self->ok ? \1 : \0,
    url        => $self->url,
    final_url  => $self->final_url,
    status     => $self->status,
    backend    => $self->backend,
    cost_class => $self->cost_class,
    title      => $self->title,
    markdown   => $self->markdown,
    signals    => $self->signals,
    why_failed => $self->why_failed,
    ( defined $self->error ? ( error => "@{[ $self->error ]}" ) : () ),
    attempts   => [ map { $_->to_hash } @{ $self->attempts } ],
  };
}

sub TO_JSON { $_[0]->to_hash }

sub attempts_json {
  my ( $self ) = @_;
  return $self->_json->encode( [ map { $_->to_hash } @{ $self->attempts } ] );
}

1;

=head1 SYNOPSIS

  my $result = $crawler->markdown('https://example.com');

  if ( $result->ok ) {
    print $result->markdown;
    print $result->backend;     # which strategy won
    print $result->cost_class;  # cheap / browser / stealth / paid
  }
  else {
    warn $result->why_failed;   # 'bot_wall_detected'
    print $result->attempts_json;
  }

=head1 DESCRIPTION

The single, uniform object every L<WWW::Crawl4AI> crawl returns, regardless of
which backend won (or that they all lost). It carries the winning content plus
the full L<WWW::Crawl4AI::Attempt> history, so callers — especially agents —
can see I<why> a backend was chosen or I<why> everything failed.

=attr ok

True if some strategy produced a good page.

=attr url

The original requested URL.

=attr final_url

The URL after redirects, when known.

=attr status

HTTP status code of the winning (or last) attempt.

=attr markdown

=attr html

=attr title

Content of the winning page.

=attr backend

Name of the strategy that won, e.g. C<crawl4ai_stealth>.

=attr cost_class

Cost tier of the winning backend: C<cheap>, C<browser>, C<stealth>, C<paid>.

=attr signals

The L<WWW::Crawl4AI::Detect/signals> of the winning (or last) page.

=attr why_failed

When C<ok> is false, the failure token of the last attempt.

=attr error

A L<WWW::Crawl4AI::Error> or string when the chain failed outright.

=attr attempts

Arrayref of L<WWW::Crawl4AI::Attempt> objects, in execution order.

=method from_attempt

  WWW::Crawl4AI::Result->from_attempt($attempt, attempts => \@all)

Builds a result from a winning attempt, copying its page content over.

=method attempt_count

Number of attempts made.

=method to_hash

=method TO_JSON

JSON-safe plain-hash view, including every attempt via
L<WWW::Crawl4AI::Attempt/to_hash>.

=method attempts_json

The attempt history encoded as a JSON string.

=cut
