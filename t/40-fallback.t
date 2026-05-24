#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use WWW::Crawl4AI;

# A mock client that returns a pre-programmed normalized page per backend name,
# so the chain runs with zero I/O.
package Mock::Client {
  sub new   { my ( $c, %a ) = @_; bless { pages => $a{pages} || {}, calls => [] }, $c }
  sub calls { $_[0]->{calls} }
  sub crawl {
    my ( $self, $req, $backend ) = @_;
    push @{ $self->{calls} }, $backend;
    my $p = $self->{pages}{$backend};
    die "mock: no page configured for $backend\n" unless $p;
    return [$p];
  }
  sub health { 1 }
}

my $thin    = { status_code => 200, markdown => 'too short' };
my $blocked = { status_code => 403, markdown => 'Access Denied ' x 50 };
my $good    = { status_code => 200, markdown => ( 'real useful content ' x 40 ), title => 'OK' };

# Clear env so applicability is deterministic.
local $ENV{CLOAKBROWSER_CDP_URL};
local $ENV{CRAWL4AI_PROXY_URL};
delete $ENV{CLOAKBROWSER_CDP_URL};
delete $ENV{CRAWL4AI_PROXY_URL};

subtest 'escalates plain -> browser -> stealth and stops at first good' => sub {
  my $mock = Mock::Client->new( pages => {
    crawl4ai_plain   => $thin,
    crawl4ai_browser => $blocked,
    crawl4ai_stealth => $good,
  } );
  my $c = WWW::Crawl4AI->new( client => $mock );
  my $r = $c->markdown('https://example.com');

  ok $r->ok, 'overall ok';
  is $r->backend, 'crawl4ai_stealth', 'stealth won';
  is $r->cost_class, 'stealth', 'cost class reported';
  is_deeply $mock->calls, [qw( crawl4ai_plain crawl4ai_browser crawl4ai_stealth )], 'ran in order, stopped at stealth';
  is $r->attempt_count, 3, 'three attempts';
  is $r->attempts->[0]->why_failed, 'thin_content', 'plain failed thin';
  is $r->attempts->[1]->why_failed, 'bot_wall_detected', 'browser failed blocked';
  ok $r->attempts->[2]->ok, 'stealth attempt ok';
};

subtest 'all strategies fail -> ok=0 with history + reason' => sub {
  my $mock = Mock::Client->new( pages => {
    crawl4ai_plain   => $thin,
    crawl4ai_browser => $thin,
    crawl4ai_stealth => $blocked,
  } );
  my $c = WWW::Crawl4AI->new( client => $mock );
  my $r = $c->markdown('https://example.com');

  ok !$r->ok, 'not ok';
  is $r->attempt_count, 3, 'all three tried';
  is $r->why_failed, 'bot_wall_detected', 'last reason surfaced';
  isa_ok $r->error, 'WWW::Crawl4AI::Error';
  ok $r->error->is_content, 'content-type error';
};

subtest 'fallback => plain only runs Plain' => sub {
  my $mock = Mock::Client->new( pages => { crawl4ai_plain => $good } );
  my $c = WWW::Crawl4AI->new( client => $mock, fallback => 'plain' );
  is_deeply $c->available_backends, ['crawl4ai_plain'], 'only plain in chain';
  my $r = $c->markdown('https://example.com');
  ok $r->ok, 'plain-only ok';
  is $r->backend, 'crawl4ai_plain', 'plain backend';
};

subtest 'explicit arrayref fallback honours order + skips inapplicable' => sub {
  my $mock = Mock::Client->new( pages => {
    crawl4ai_stealth => $thin,
    crawl4ai_plain   => $good,
  } );
  # cloakbrowser requested but no url configured -> dropped
  my $c = WWW::Crawl4AI->new(
    client   => $mock,
    fallback => [qw( crawl4ai_stealth crawl4ai_cloakbrowser crawl4ai_plain )],
  );
  is_deeply $c->available_backends, [qw( crawl4ai_stealth crawl4ai_plain )], 'cloakbrowser dropped, order kept';
  my $r = $c->markdown('https://example.com');
  is $r->backend, 'crawl4ai_plain', 'plain won after stealth thin';
};

subtest 'cloakbrowser + proxy join chain when configured' => sub {
  my $mock = Mock::Client->new( pages => {} );
  my $c = WWW::Crawl4AI->new(
    client           => $mock,
    cloakbrowser_url => 'http://localhost:9222',
    proxy_url        => 'http://proxy:3128',
  );
  my %b = map { $_ => 1 } @{ $c->available_backends };
  ok $b{crawl4ai_cloakbrowser}, 'cloakbrowser present';
  ok $b{crawl4ai_proxy},        'proxy present';
};

subtest 'callback strategy as last resort' => sub {
  my $mock = Mock::Client->new( pages => {
    crawl4ai_plain   => $thin,
    crawl4ai_browser => $thin,
    crawl4ai_stealth => $blocked,
  } );
  my $called = 0;
  my $c = WWW::Crawl4AI->new(
    client   => $mock,
    callback => sub { $called++; return { status_code => 200, markdown => ( 'from callback ' x 60 ) } },
  );
  ok scalar( grep { $_ eq 'external_callback' } @{ $c->available_backends } ), 'callback in chain';
  my $r = $c->markdown('https://example.com');
  ok $r->ok, 'callback rescued the crawl';
  is $r->backend, 'external_callback', 'callback won';
  is $called, 1, 'callback invoked once';
};

subtest 'strategy that throws is recorded, chain continues' => sub {
  my $mock = Mock::Client->new( pages => { crawl4ai_stealth => $good } );  # plain/browser will die
  my $c = WWW::Crawl4AI->new( client => $mock );
  my $r = $c->markdown('https://example.com');
  ok $r->ok, 'recovered after throwing strategies';
  is $r->backend, 'crawl4ai_stealth';
  is $r->attempts->[0]->why_failed, 'error', 'throwing attempt marked error';
  ok defined $r->attempts->[0]->error, 'error object captured';
};

done_testing;
