package WWW::Crawl4AI::Strategy::Callback;
# ABSTRACT: last-resort Crawl4AI strategy delegating to a user coderef
use Moo;
with 'WWW::Crawl4AI::Strategy';

our $VERSION = '0.001';

=head1 DESCRIPTION

The final link, only present when the crawler was given a C<callback> coderef.
When every Crawl4AI-backed strategy has failed, the URL is handed to that
coderef as C<< ->($url, %opts) >>; it should return a page-shaped hashref
(C<markdown>, C<html>, C<status_code>, C<title>, ...) or C<undef>. This is the
hook for paid scraping APIs or any external escalation you control.

C<markdown> may be a plain string or the structured object Crawl4AI itself
returns (C<< { raw_markdown => ..., fit_markdown => ... } >>); either is
accepted. C<links>, if present, is expected in the
C<< { internal => [...], external => [...] } >> shape.

=cut

sub name       { 'external_callback' }

=method name

C<external_callback>.

=cut

sub cost_class { 'paid' }

=method cost_class

C<paid>.

=cut

sub applicable {
  my ( $self, $crawler ) = @_;
  return $crawler->callback ? 1 : 0;
}

=method applicable

True only when C<< $crawler->callback >> is set.

=cut

# Does not go through Crawl4AI at all — hand the URL to the user's coderef and
# normalize whatever page-shaped hashref it returns. We accept markdown either
# as a plain string or as Crawl4AI's structured object, so Detect and Result
# see the same shape they get from every (Crawl4AI-backed) strategy.
sub crawl {
  my ( $self, $crawler, $url, %opts ) = @_;
  my $page = $crawler->callback->( $url, %opts );
  return undef unless ref $page eq 'HASH';
  $page->{markdown}  = _flatten_markdown( $page->{markdown} ) if ref $page->{markdown} eq 'HASH';
  $page->{url}       //= $url;
  $page->{final_url} //= $page->{url};
  return $page;
}

# Same candidate order as WWW::Crawl4AI::Client::_extract_markdown: prefer the
# filtered markdown but skip empty candidates (fit_markdown is often '').
sub _flatten_markdown {
  my ( $md ) = @_;
  for my $key (qw( fit_markdown raw_markdown markdown_with_citations markdown )) {
    my $value = $md->{$key};
    return $value if defined $value && length $value;
  }
  return undef;
}

=method crawl

Calls the user coderef and normalizes its return value into a page.

=cut

1;
