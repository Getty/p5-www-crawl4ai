package WWW::Crawl4AI::StrategyChain;
# ABSTRACT: ordered list of strategy objects, pluggable at construction time
use Moo;
use WWW::Crawl4AI::Strategy::Plain ();
use WWW::Crawl4AI::Strategy::Browser ();
use WWW::Crawl4AI::Strategy::Stealth ();
use WWW::Crawl4AI::Strategy::CloakBrowser ();
use WWW::Crawl4AI::Strategy::Proxy ();
use WWW::Crawl4AI::Strategy::Callback ();

our $VERSION = '0.001';

=head1 SYNOPSIS

  # Default chain (all applicable strategies):
  my $chain = WWW::Crawl4AI::StrategyChain->new;

  # Explicit strategy instances:
  my $chain = WWW::Crawl4AI::StrategyChain->new(
    strategies => [ $plain, $stealth, $callback ],
  );

  # Subclass to override defaults:
  package My::Chain;
  use parent 'WWW::Crawl4AI::StrategyChain';
  sub _build_default_strategies {
    [ WWW::Crawl4AI::Strategy::Plain->new ]
  }

=head1 DESCRIPTION

Holds the ordered list of strategy objects that power the fallback chain.
Replaces the hardcoded C<@CHAIN_CLASSES> array in C<WWW::Crawl4AI>.

B<No fat globals>: strategies live in the object. Subclass
L</_build_default_strategies> to change defaults; use L</add_strategy>,
L</remove_strategy>, L</replace_strategy> to mutate after construction.

=cut

# Default order, cheapest first. Override in subclass or at construction.
my @CHAIN_CLASSES = qw(
  WWW::Crawl4AI::Strategy::Plain
  WWW::Crawl4AI::Strategy::Browser
  WWW::Crawl4AI::Strategy::Stealth
  WWW::Crawl4AI::Strategy::CloakBrowser
  WWW::Crawl4AI::Strategy::Proxy
  WWW::Crawl4AI::Strategy::Callback
);

=func chain_classes

Returns the raw class-name array. Override this to change the default class
list without subclassing L</_build_default_strategies>.

=cut

sub chain_classes { @CHAIN_CLASSES }

has strategies => (
  is      => 'ro',
  builder => 1,
);

=attr strategies

Arrayref of instantiated L<WWW::Crawl4AI::Strategy> objects in execution order.

=cut

sub _build_strategies {
  my ( $self ) = @_;
  return [ map { $_->new } $self->chain_classes ];
}

sub add_strategy {
  my ( $self, $strategy ) = @_;
  push @{ $self->{strategies} }, $strategy;
}

sub remove_strategy {
  my ( $self, $name ) = @_;
  @{ $self->{strategies} } = grep { $_->name ne $name } @{ $self->{strategies} };
}

sub replace_strategy {
  my ( $self, $name, $strategy ) = @_;
  my $s = $self->{strategies};
  for my $i ( 0 .. $#$s ) {
    $s->[$i] = $strategy if $s->[$i]->name eq $name;
  }
}

# Filter strategies by applicable($crawler) for this crawler instance.
sub applicable {
  my ( $self, $crawler ) = @_;
  return [ grep { $_->applicable($crawler) } @{ $self->strategies } ];
}

1;