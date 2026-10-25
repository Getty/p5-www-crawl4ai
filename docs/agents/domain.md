# Domain Docs

How the engineering skills should read this repo's domain docs while exploring the
code.

## Read before exploring

- **`CONTEXT.md`** at the repo root — the glossary / the domain language.
- **`docs/adr/`** — the ADRs that touch the area currently being worked on.

This is a **single-context** repo: one `CONTEXT.md` plus `docs/adr/` at the root.

If one of these files does not exist, **carry on silently**. Don't report its
absence and don't propose creating it up front. The producer skills create them
only once terms or decisions are actually settled.

## File structure

```
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-….md
│   └── 0002-….md
└── lib/
```

## Use the glossary vocabulary

When the output names a domain concept (issue title, refactor proposal,
hypothesis, test name), use the term defined in `CONTEXT.md`. Don't drift to
synonyms the glossary deliberately avoids.

If the concept you need is not in the glossary yet, that is a signal — either
you are inventing language the project doesn't use (reconsider), or there is a
real gap (note it for the doc producers).

## Report ADR conflicts

If the output contradicts an existing ADR, say so explicitly instead of passing
over it silently:

> _Contradicts ADR-0007 (…) — but worth a fresh look, because …_
