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
