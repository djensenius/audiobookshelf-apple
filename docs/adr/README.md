# Architecture decision records

An architecture decision record (ADR) is a short document that records one
significant decision: the problem, the options considered, what was chosen, and
why. ADRs let contributors (and coding agents) working in parallel follow the same
choices without re-debating them, and let later readers see why the code looks the
way it does.

Write an ADR when a decision:

- affects more than one module or feature;
- changes the module rules in [architecture.md](../architecture.md);
- picks between Apple APIs or adds an SPM dependency; or
- is hard to reverse later (persistence, identity, minimum server version).

## Adding an ADR

1. Take the next free number from the index below, or the number reserved for your
   issue. Numbers are never reused.
2. Copy [0000-template.md](0000-template.md) to `NNNN-short-slug.md` (four digits,
   lowercase slug with hyphens).
3. Fill in every section. Set the status to **Proposed** while the PR is open, and
   link the issue.
4. Add a row to the index below in the same PR.
5. Set the status to **Accepted** when the decision is agreed (the owner signs off
   where the issue asks for it), before merging.

Accepted ADRs are not rewritten. To change a decision, write a new ADR, set the old
one's status to `Superseded by [NNNN](NNNN-slug.md)`, and update the index. Typo
and link fixes are fine.

## Index

Most numbers below are reserved for ADRs that land in their own pull requests;
links resolve once each one merges.

| Number | Title | Issue | Status |
| --- | --- | --- | --- |
| [0000](0000-template.md) | Template | P0-05 | — |
| [0001](0001-architecture.md) | Architecture: modules, app layout, and concurrency | P0-05 | Accepted |
| [0002](0002-identity-and-no-migration.md) | App identity and no data migration | P0-03 | Reserved |
| [0003](0003-swiftdata.md) | SwiftData schema, versioning, and actor boundaries | P1-12 | Reserved |
| [0004](0004-navigation.md) | Navigation for iPhone, iPad, iPhone Duo, and Mac | P3-01 | Reserved |
| [0005](0005-images.md) | Cover and image loading and caching | P3-02 | Reserved |
| [0006](0006-now-playing.md) | Now Playing API | P2-01 | Reserved |
| [0007](0007-streaming.md) | Streaming, stream auth, and minimum server version | P2-02 | Reserved |
| [0008](0008-readers.md) | EPUB engine, MOBI/AZW3, and CBR support | P6-10 | Reserved |
