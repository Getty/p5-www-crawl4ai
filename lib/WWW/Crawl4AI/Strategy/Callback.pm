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
# normalize whatever page-shaped hashref it returns.
sub crawl {
  my ( $self, $crawler, $url, %opts ) = @_;
  my $page = $crawler->callback->( $url, %opts );
  return undef unless ref $page eq 'HASH';
  $page->{url}       //= $url;
  $page->{final_url} //= $page->{url};
  return $page;
}

=method crawl

Calls the user coderef and normalizes its return value into a page.

=cut

1;
