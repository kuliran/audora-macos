# Domain Docs

How engineering skills should consume this repository's domain documentation.

## Before exploring, read these

- **`rfc/README.md`** and the concept documents it links for the affected area.
  The RFC is the canonical product and architecture description.
- **`CONTEXT.md`** at the repository root, if it exists.
- **`docs/adr/`**, reading ADRs that affect the area being changed.

If `CONTEXT.md` or `docs/adr/` does not exist, proceed silently. The
domain-modeling workflow creates them lazily when terminology or qualifying
decisions are resolved.

## File structure

This is a single-context repository:

```text
/
├── CONTEXT.md
├── docs/
│   └── adr/
├── rfc/
│   ├── README.md
│   ├── concepts/
│   └── backlog/
└── audora/
```

## Document roles

- **`rfc/README.md`** defines current committed product scope and architecture.
  Conceptual changes must update it in the same commit.
- **`CONTEXT.md`** is a glossary of domain language only. It must not contain
  implementation details or contradict the RFC.
- **`docs/adr/`** records only hard-to-reverse, surprising decisions produced by
  real trade-offs. ADRs must not become a changelog or silently contradict the
  RFC.
- **`rfc/backlog/`** contains proposals, not committed scope.

## Use the glossary's vocabulary

When output names a domain concept—in an issue title, proposal, hypothesis, or
test—use the term defined in `CONTEXT.md`.

If a needed concept is absent, reconsider whether existing language already
covers it or note the gap for domain modeling.

## Flag conflicts

If proposed work contradicts the RFC or an ADR, surface the conflict explicitly
instead of silently overriding it.
