# WWW::Crawl4AI

Perl client and fallback orchestrator for
[Crawl4AI](https://github.com/unclecode/crawl4ai).

Crawl4AI does the fetching and Markdown extraction. `WWW::Crawl4AI` decides
*policy*: it probes which backends are available, escalates through a visible
strategy chain (plain → browser → stealth → CloakBrowser/CDP → proxy →
callback), and always returns a normalized, agent-friendly result with the full
attempt history attached.

**This is not "Firecrawl in Perl."** It is a crawler control plane in Perl —
every attempt is modelled on the client side so a caller can see which backend
won, what it cost, and on failure, exactly why.

## Synopsis

```perl
use WWW::Crawl4AI;

my $crawler = WWW::Crawl4AI->new(
  base_url         => 'http://localhost:11235',
  cloakbrowser_url => $ENV{CLOAKBROWSER_CDP_URL},  # optional
  proxy_url        => $ENV{CRAWL4AI_PROXY_URL},    # optional
  fallback         => 'auto',                       # default
);

my $result = $crawler->markdown('https://example.com');

if ( $result->ok ) {
  say $result->markdown;
  say $result->backend;       # crawl4ai_plain / crawl4ai_stealth / ...
  say $result->cost_class;    # cheap / browser / stealth / paid
  say $result->final_url;
} else {
  say $result->why_failed;    # bot_wall_detected / js_required / thin_content ...
  say $result->attempts_json; # full history, JSON-safe
}
```

## The strategy chain

`markdown` / `crawl` walk strategies in cost order and stop at the first result
that passes content classification:

| Backend | What it does | cost\_class |
|---|---|---|
| `crawl4ai_plain` | headless text mode, no special browser | `cheap` |
| `crawl4ai_browser` | full JS render, `wait_until: networkidle` | `browser` |
| `crawl4ai_stealth` | `enable_stealth`, randomized user agent | `stealth` |
| `crawl4ai_cloakbrowser` | attaches Crawl4AI to CloakBrowser via `cdp_url` | `stealth` |
| `crawl4ai_proxy` | stealth crawl routed through a proxy | `paid` |
| `external_callback` | user-supplied last-resort coderef | `paid` |

Which links join the chain depends on configuration: `crawl4ai_cloakbrowser` is
only active when `cloakbrowser_url` is set; `crawl4ai_proxy` when `proxy_url`
is set; `external_callback` when you pass a `callback` coderef.

Select a subset — or an explicit order — via `fallback`:

```perl
# Only the plain backend (no escalation):
fallback => 'plain'

# Explicit order, skip browser tier:
fallback => ['crawl4ai_plain', 'crawl4ai_stealth', 'crawl4ai_cloakbrowser']
```

## Content classification — "200 OK" is not enough

A crawl can succeed at the HTTP level and still return junk. The classifier
(`WWW::Crawl4AI::Detect`) rejects a result on:

- **thin Markdown** — below a configurable length threshold (default 500 chars)
- **JS walls** — "enable JavaScript" / "checking your browser" bodies
- **bot walls** — Cloudflare / DataDome / PerimeterX fingerprints in the HTML
- **CAPTCHA pages** — hCaptcha / reCAPTCHA / Cloudflare turnstile markers
- **HTTP errors** — 401, 403, 429, 5xx

Each rejected attempt is recorded as a `WWW::Crawl4AI::Attempt` with its
signals, so an agent can see why a backend failed and what was tried:

```perl
$result->ok;            # false
$result->why_failed;    # 'bot_wall_detected'
$result->signals;       # { js_required => 0, blocked => 1, captcha => 0, thin_html => 0 }
$result->attempts;      # [ WWW::Crawl4AI::Attempt, ... ]
$result->attempts_json; # compact JSON, markdown reduced to markdown_len
```

## Links and deep crawl

Every successful `Result` exposes the links Crawl4AI found on the page — no
reaching into `raw`:

```perl
my $r = $crawler->markdown('https://example.com');

$r->urls;            # \@ deduped absolute http(s) URLs (relative ones resolved
                     #    against final_url; javascript:/mailto:/#anchors dropped)
$r->internal_links;  # \@ same-site links,  each { href, text, title }
$r->external_links;  # \@ off-site links
$r->links;           # { internal => [...], external => [...] }
```

To actually *follow* those links, `deep_crawl` runs the full strategy chain
breadth-first across the link graph:

```perl
my $results = $crawler->deep_crawl(
  'https://example.com',
  max_pages  => 50,    # hard cap (default 25)
  max_depth  => 3,     # link-following depth, start URL is depth 0 (default 2)
  same_host  => 1,     # only follow links on the start host (default on)
  url_filter => sub { $_[0] !~ m{/login} },          # optional gate
  on_page    => sub { my ($result, $depth) = @_ },   # optional progress/stream
  min_markdown => 200, # any crawl() option is forwarded to every page
);

# arrayref of WWW::Crawl4AI::Result in BFS visit order (first = start URL)
say $_->final_url for @$results;
```

URLs are deduplicated with the fragment stripped, so map-style `#lat/lon`
anchors don't count as separate pages. Each page still escalates through the
chain independently and keeps its own attempt history, and a dead or thin link
shows up as an `ok => 0` result in the list rather than being silently dropped.

## Low-level REST client

`WWW::Crawl4AI::Client` is a thin, UA-agnostic wrapper over the Crawl4AI
Docker REST API. Every endpoint has three flavours:

```perl
my $client = WWW::Crawl4AI::Client->new( base_url => 'http://localhost:11235' );

# Convenience: build + fire (LWP) + parse
my $pages = $client->crawl($request);            # POST /crawl → normalized page array
my $md    = $client->md('https://example.com');  # POST /md   → markdown string
my $job   = $client->job_submit($request);       # POST /crawl/job → { task_id, raw }
my $st    = $client->job_status($job->{task_id}); # GET /crawl/job/{id} → { status, pages, raw }
my $ok    = $client->health;                     # GET /health → 0/1

# No-I/O building blocks (inject your own UA or async framework)
my $req   = $client->crawl_request($request);          # → HTTP::Request
my $pages = $client->parse_crawl_response($http_res);  # → \@pages
```

## Diagnostic tools

```bash
# Probe reachability and show the active chain:
perl -Ilib bin/www-crawl4ai-doctor

# Run the full chain against one URL and print the attempt table:
perl -Ilib bin/www-crawl4ai-test-url https://example.com
```

## Environment

| Variable | Purpose |
|---|---|
| `CRAWL4AI_URL` / `CRAWL4AI_BASE_URL` | Crawl4AI server (default `http://localhost:11235`) |
| `CRAWL4AI_API_TOKEN` | Bearer token (optional; only if the server has JWT enabled) |
| `CLOAKBROWSER_CDP_URL` | CloakBrowser CDP endpoint (activates the cloakbrowser strategy) |
| `CRAWL4AI_PROXY_URL` | Proxy URL (activates the proxy strategy) |

## Docker

`examples/docker-compose.yml` brings up Crawl4AI on port `11235` and
CloakBrowser on port `9222`, both bound to `127.0.0.1`.
`examples/docker-compose.proxy.yml` adds a Squid proxy for the escalation tier.

```bash
cd examples && docker compose up -d
perl -Ilib bin/www-crawl4ai-doctor
```

## Installation

```bash
cpanm WWW::Crawl4AI
# or from source:
cpanm --installdeps .
dzil test
```

## See Also

- [Net::Async::Crawl4AI](https://metacpan.org/pod/Net::Async::Crawl4AI) — IO::Async / Future integration (same chain, non-blocking)
- [Crawl4AI](https://github.com/unclecode/crawl4ai) — the upstream service
- [CloakBrowser](https://github.com/cloakhq/cloakbrowser) — optional CDP browser provider

## License

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

This distribution *talks to* Crawl4AI but does not bundle it. Crawl4AI is a
separate Apache-2.0-licensed project with attribution requirements.
CloakBrowser is an optional external service under its own license.
