package WWW::Crawl4AI::Markdown;
# ABSTRACT: markdown field resolution across Crawl4AI response shapes
use strict;
use warnings;

our $VERSION = '0.001';

=head1 SYNOPSIS

  use WWW::Crawl4AI::Markdown qw( resolve_markdown_chain );

  my $md = { fit_markdown => '', raw_markdown => 'content', ... };
  my $text = resolve_markdown_chain($md);  # returns 'content'

=head1 DESCRIPTION

Resolves the markdown field from Crawl4AI's structured response object.
Crawl4AI returns markdown as a hash C<< { fit_markdown, raw_markdown,
markdown_with_citations, markdown } >> — the chain prefers filtered (fit)
but skips empty candidates.

Shared by L<WWW::Crawl4AI::Client/_extract_markdown> and
L<WWW::Crawl4AI::Strategy::Callback/_flatten_markdown>.

=cut

use Exporter qw( import );
our @EXPORT_OK = qw( resolve_markdown_chain );

=func resolve_markdown_chain

  my $text = resolve_markdown_chain($md);

Given a markdown hashref (or plain string), returns the first non-empty value
from this candidate chain: C<fit_markdown>, C<raw_markdown>,
C<markdown_with_citations>, C<markdown>. Returns C<undef> if none are defined
or non-empty, or the original string if a plain scalar was passed.

=cut

sub resolve_markdown_chain {
  my ( $md ) = @_;
  return $md unless ref $md eq 'HASH';
  for my $key (qw( fit_markdown raw_markdown markdown_with_citations markdown )) {
    my $value = $md->{$key};
    return $value if defined $value && length $value;
  }
  return undef;
}

1;