# WWW::Crawl4AI

Perl client and fallback orchestrator for [Crawl4AI](https://github.com/unclecode/crawl4ai).

Crawl4AI does the fetching and Markdown extraction. `WWW::Crawl4AI` decides
*policy*: it probes which backends are available, escalates through a visible
strategy chain (plain → browser → stealth → CloakBrowser/CDP → proxy →
callback) and always hands back a normalized, agent-friendly result with the
full attempt history attached.

This is not "Firecrawl in Perl" — it is a crawler control plane in Perl.

## Synopsis

```perl
use WWW::Crawl4AI;

my $crawler = WWW::Crawl4AI->new(
  base_url         => 'http://localhost:11235',
  cloakbrowser_url => $ENV{CLOAKBROWSER_CDP_URL},  # optional
  proxy_url        => $ENV{CRAWL4AI_PROXY_URL},    # optional
  fallback         => 'auto',
);

my $result = $crawler->markdown('https://example.com');

say $result->markdown;
say $result->backend;        # crawl4ai_plain / crawl4ai_stealth / crawl4ai_cloakbrowser ...
say $result->final_url;
say $result->cost_class;     # cheap / browser / stealth / paid
say $result->attempts_json;  # full, JSON-safe attempt history
```

## The strategy chain

`markdown`/`crawl` do not call Crawl4AI once — they walk a chain in
cost/complexity order and stop at the first *good* result:

| Backend | What it does | cost_class |
|---|---|---|
| `crawl4ai_plain` | normal call, text mode, no special browser | cheap |
| `crawl4ai_browser` | JS rendering, `wait_until: networkidle` | browser |
| `crawl4ai_stealth` | `enable_stealth`, randomized user agent | stealth |
| `crawl4ai_cloakbrowser` | attaches Crawl4AI to CloakBrowser via `cdp_url` | stealth |
| `crawl4ai_proxy` | routes through a configured proxy | paid |
| `external_callback` | user-supplied last-resort coderef | paid |

Which links are added depends on detection: CloakBrowser is only in the chain
if a CDP endpoint is configured/reachable, proxy only if a proxy URL is set,
callback only if you pass one.

## A result is not just "200 OK"

A crawl can succeed at the HTTP level and still return junk. The classifier
fails a result on:

- thin Markdown (below a length threshold)
- "enable JavaScript" / "checking your browser" / "access denied" pages
- bot-wall fingerprints in the HTML (`cf-chl`, `datadome`, `perimeterx`, `akamai`)
- titles like `Just a moment...`
- HTTP 401/403/429/5xx

Each rejected attempt is recorded with its signals, so an agent sees *why* a
backend failed and what to try next:

```perl
$result->ok;            # 0
$result->why_failed;    # 'bot_wall_detected'
$result->signals;       # { js_required => 1, blocked => 1, captcha => 0, thin_html => 0 }
$result->attempts;      # [ WWW::Crawl4AI::Attempt, ... ]
```

## Low-level REST client

`WWW::Crawl4AI::Client` is a thin, UA-agnostic wrapper over the Crawl4AI Docker
REST API. Every endpoint has three flavours (no UA lock-in):

```perl
my $client = WWW::Crawl4AI::Client->new( base_url => 'http://localhost:11235' );

# convenience (LWP)
my $data = $client->crawl($request);     # POST /crawl  (sync)
my $md   = $client->md('https://example.com');
my $job  = $client->job_submit($request);          # POST /crawl/job
my $st   = $client->job_status($job->{task_id});   # GET  /crawl/job/{task_id}
my $ok   = $client->health;                         # GET  /health

# or build/parse separately
my $req  = $client->crawl_request($request);        # HTTP::Request, no I/O
my $out  = $client->parse_crawl_response($http_response);
```

## Environment

| Variable | Purpose |
|---|---|
| `CRAWL4AI_URL` / `CRAWL4AI_BASE_URL` | Crawl4AI server (default `http://localhost:11235`) |
| `CRAWL4AI_API_TOKEN` | Bearer token (optional; only if the server has JWT enabled) |
| `CLOAKBROWSER_CDP_URL` | CloakBrowser CDP endpoint (enables the cloakbrowser strategy) |
| `CRAWL4AI_PROXY_URL` | Proxy URL (enables the proxy strategy) |

## Tools

```bash
www-crawl4ai-doctor                        # probe crawl4ai / cloakbrowser / proxy
www-crawl4ai-test-url https://example.com  # run the full chain against one URL, show attempts
```

## Docker

`examples/docker-compose.yml` brings up Crawl4AI (`:11235`) and CloakBrowser
(`:9222`) bound to `127.0.0.1` only. `examples/docker-compose.proxy.yml` adds a
Squid proxy for the escalation tier.

## Installation

```bash
cpanm WWW::Crawl4AI
# or from source:
cpanm --installdeps .
```

## See Also

- [Net::Async::Crawl4AI](https://metacpan.org/pod/Net::Async::Crawl4AI) — IO::Async / Future integration
- [Crawl4AI](https://github.com/unclecode/crawl4ai) — the upstream service (Apache-2.0, with attribution requirements)
- [CloakBrowser](https://github.com/cloakhq/cloakbrowser) — optional CDP browser provider (MIT)

## License Note

This distribution *talks to* Crawl4AI and ships examples for it; Crawl4AI
itself is a separate Apache-2.0-licensed project with attribution
requirements. CloakBrowser is an optional external service (MIT). Neither is
bundled here.
