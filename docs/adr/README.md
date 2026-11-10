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
3. Fill in every section and link the issue (`Issue: #N`). Give the ADR the status
   it will have when merged — normally **Accepted**. Merging the PR is the
   acceptance; the owner can still supersede the decision later with a new ADR.
4. If validation needs a device or runtime check that the ADR PR could not run,
   don't keep the ADR Proposed. Add the check to the acceptance criteria of the
   issue that implements the decision, and say in the ADR's Validation section
   that it is performed there (for example "performed in #49").
5. If the number is new, add a row to the index below in the same PR.

Accepted ADRs are not rewritten. To change a decision, write a new ADR, set the old
one's status to `Superseded by [NNNN](NNNN-slug.md)`, and update the index. Typo
and link fixes are fine.

## Index

Rows marked **Reserved** are numbers held for ADRs that land in their own pull
requests; their links resolve once each one merges. Merging a topic ADR flips its
row from Reserved to Accepted (the coordinator updates this index when merging, so
topic ADR PRs for a reserved number don't edit it).

| Number | Title | Issue | Status |
| --- | --- | --- | --- |
| [0000](0000-template.md) | Template | [#21](https://github.com/djensenius/audiobookshelf-apple/issues/21) (P0-05) | — |
| [0001](0001-architecture.md) | Architecture: modules, app layout, and concurrency | [#21](https://github.com/djensenius/audiobookshelf-apple/issues/21) (P0-05) | Accepted |
| [0002](0002-identity-and-no-migration.md) | App identity and no data migration | [#18](https://github.com/djensenius/audiobookshelf-apple/issues/18) (P0-03) | Accepted |
| [0003](0003-swiftdata.md) | SwiftData schema, versioning, and actor boundaries | [#35](https://github.com/djensenius/audiobookshelf-apple/issues/35) (P1-12) | Reserved |
| [0004](0004-navigation.md) | Navigation architecture for iPhone, iPad, iPhone Duo and Mac | [#41](https://github.com/djensenius/audiobookshelf-apple/issues/41) (P3-01) | Reserved |
| [0005](0005-images.md) | Cover and image loading and caching | [#42](https://github.com/djensenius/audiobookshelf-apple/issues/42) (P3-02) | Reserved |
| [0006](0006-now-playing.md) | Now Playing API | [#47](https://github.com/djensenius/audiobookshelf-apple/issues/47) (P2-01) | Reserved |
| [0007](0007-streaming.md) | Streaming strategy and minimum server version | [#48](https://github.com/djensenius/audiobookshelf-apple/issues/48) (P2-02) | Reserved |
| [0008](0008-readers.md) | EPUB engine, MOBI/AZW3, and CBR support | [#100](https://github.com/djensenius/audiobookshelf-apple/issues/100) (P6-10) | Reserved |
