package WWW::Crawl4AI::Result;
# ABSTRACT: normalized result of a WWW::Crawl4AI strategy chain
use Moo;
use JSON::MaybeXS ();
use URI ();

our $VERSION = '0.001';

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

=cut

has ok         => ( is => 'ro', default => sub { 0 } );

=attr ok

True if some strategy produced a good page.

=cut

has url        => ( is => 'ro' );

=attr url

The original requested URL.

=cut

has final_url  => ( is => 'ro' );

=attr final_url

The URL after redirects, when known.

=cut

has status     => ( is => 'ro' );

=attr status

HTTP status code of the winning (or last) attempt.

=cut

has markdown   => ( is => 'ro' );

=attr markdown

Content of the winning page.

=cut

has html       => ( is => 'ro' );

=attr html

Raw HTML of the winning page.

=cut

has title      => ( is => 'ro' );

=attr title

Page title of the winning page.

=cut

has backend    => ( is => 'ro' );

=attr backend

Name of the strategy that won, e.g. C<crawl4ai_stealth>.

=cut

has cost_class => ( is => 'ro' );

=attr cost_class

Cost tier of the winning backend: C<cheap>, C<browser>, C<stealth>, C<paid>.

=cut

has signals    => ( is => 'ro', default => sub { {} } );

=attr signals

The L<WWW::Crawl4AI::Detect/signals> of the winning (or last) page.

=cut

has why_failed => ( is => 'ro' );

=attr why_failed

When C<ok> is false, the failure token of the last attempt.

=cut

has error      => ( is => 'ro' );

=attr error

A L<WWW::Crawl4AI::Error> or string when the chain failed outright.

=cut

has attempts   => ( is => 'ro', default => sub { [] } );

=attr attempts

Arrayref of L<WWW::Crawl4AI::Attempt> objects, in execution order.

=cut

has links      => ( is => 'ro', default => sub { { internal => [], external => [] } } );

=attr links

The links Crawl4AI extracted from the winning page, as
C<< { internal => [...], external => [...] } >>. Each entry is a hashref with
C<href>, C<text> and C<title>. For just the URLs, use L</urls>.

=cut

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
    links      => $page->{links} // { internal => [], external => [] },
    %extra,
  );
}

=method from_attempt

  WWW::Crawl4AI::Result->from_attempt($attempt, attempts => \@all)

Builds a result from a winning attempt, copying its page content over.

=cut

sub attempt_count { scalar @{ $_[0]->attempts } }

=method attempt_count

Number of attempts made.

=cut

sub internal_links { $_[0]->links->{internal} || [] }

=method internal_links

Arrayref of the winning page's same-site links (each C<< { href, text, title } >>).

=cut

sub external_links { $_[0]->links->{external} || [] }

=method external_links

Arrayref of the winning page's off-site links (each C<< { href, text, title } >>).

=cut

sub urls {
  my ( $self ) = @_;
  my $base = $self->final_url // $self->url;
  my ( %seen, @urls );
  for my $link ( @{ $self->internal_links }, @{ $self->external_links } ) {
    my $href = ref $link eq 'HASH' ? $link->{href} : $link;
    next unless defined $href && length $href;
    next if $href =~ m{\A(?:javascript|mailto|tel|data):}i;
    next if $href =~ /\A#/;
    my $abs = $base ? URI->new_abs( $href, $base )->as_string : $href;
    next unless $abs =~ m{\Ahttps?://}i;
    next if $seen{$abs}++;
    push @urls, $abs;
  }
  return \@urls;
}

=method urls

The deduplicated, absolute C<http>/C<https> URLs found on the winning page, in
document order. Relative hrefs are resolved against L</final_url>;
C<javascript:>, C<mailto:>, C<tel:>, C<data:> and bare anchors are dropped. This
is the list to feed back into a crawl to go deeper.

=cut

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
    links      => $self->links,
    urls       => $self->urls,
    ( defined $self->error ? ( error => "@{[ $self->error ]}" ) : () ),
    attempts   => [ map { $_->to_hash } @{ $self->attempts } ],
  };
}

=method to_hash

=method TO_JSON

JSON-safe plain-hash view, including every attempt via
L<WWW::Crawl4AI::Attempt/to_hash>.

=cut

sub TO_JSON { $_[0]->to_hash }

sub attempts_json {
  my ( $self ) = @_;
  return $self->_json->encode( [ map { $_->to_hash } @{ $self->attempts } ] );
}

=method attempts_json

The attempt history encoded as a JSON string.

=cut

1;
