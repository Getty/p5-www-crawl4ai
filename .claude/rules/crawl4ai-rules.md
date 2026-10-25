# WWW::Crawl4AI House Rules

The shared house rules come from skilletor — bundle `getty-cpan-dist@getty`: engineering
discipline, the delegation lock, the publish gate, karr coordination, CPAN release. They load
as `.claude/rules/.local.*.md`; if they are missing, run `skilletor sync` and publish nothing
until they load. This file adds what is true only here, and wins where it differs.

## What this repo is

Perl client and fallback orchestrator for Crawl4AI.

## Agent team

| Task | Agent |
|---|---|
| Implement / refactor / debug / test | `crawl4ai-worker` (default) |
| Commits, `Changes`, card → done, pre-release audit | `crawl4ai-release-manager` |
| Run a URL live through the strategy chain, diagnose a misclassification | `crawl-chain-probe` |
| Check the skill / CONTEXT.md / ADRs against the code for drift | `docs-drift-auditor` |
| Triage and label karr tickets | `karr-triage` |
| Read-only research, audit, gap analysis | `crawl4ai-worker` ("read-only, change nothing") |

Behavior-relevant = runtime behavior, the public API, the chain and detect logic, error
handling, tests. Pure prose docs and README are not.

Board commands for this repo: `docs/agents/issue-tracker.md`. The worker works only the card
it was handed, up to `review`.
