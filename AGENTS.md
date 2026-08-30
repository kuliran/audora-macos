# Product context

Before making additions or changes to the product behavior or architecture, read [`rfc/README.md`](rfc/README.md)
and the concept documents it links for the affected area.

- `rfc/README.md` is the canonical product and architecture description.
- Every conceptual product or architecture change must update that README in the
  same commit as the detailed RFC or implementation.
- Files under `rfc/concepts/` may elaborate on the README but may not silently
  contradict it.
- Files under `rfc/backlog/` are proposals, not committed scope.
- Git commits are the history. Do not add an RFC changelog or duplicate old
  decisions inside the documents.
- Existing files under `docs/` and the remainder of the current README describe
  the legacy Audora implementation unless the RFC explicitly adopts them.

## Agent skills

### Issue tracker

Issues and specs are tracked in GitHub Issues for `kuliran/audora-macos`. See
`docs/agents/issue-tracker.md`.

### Triage labels

Use the five default canonical triage labels. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context product repo. The RFC remains canonical; use the root
`CONTEXT.md` glossary and repo-wide ADRs under `docs/adr/`. See
`docs/agents/domain.md`.
