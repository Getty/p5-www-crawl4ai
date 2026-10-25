# CLAUDE.md

Repo-specific notes for `WWW::Crawl4AI`. The general Perl rules (module loading,
Moo/Moose, `[@Author::GETTY]` Dist::Zilla, cpanfile versioning, style) live in the
`getty-perl-core` skill (`.claude/skills/`) — they still apply here. For every
classification or chain question the code is the truth, not the docs:
`lib/WWW/Crawl4AI/Detect.pm` and `Changes` first.

## Delegation

Delegation and house rules: shared rules via the skilletor bundle `getty-cpan-dist@getty`;
lanes in `.claude/rules/crawl4ai-rules.md` (auto-loaded).

| Task | Agent |
|---|---|
| Implement, refactor, debug, behavior, tests | `crawl4ai-worker` (default) |
| Commits, `Changes`, card → done, release audit before every `dzil release` | `crawl4ai-release-manager` |
| Run a URL live through the strategy chain, diagnose the attempt table | `crawl-chain-probe` |
| Check skills, CONTEXT.md and ADRs against `lib/` for drift | `docs-drift-auditor` |
| Triage and label issues and PRDs on the karr board | `karr-triage` |

## Agent skills

### Issue tracker

Issues and PRDs are managed with **karr** (git-native kanban, board in `refs/karr/*`).
See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles map to karr tags with their default names. See
`docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
