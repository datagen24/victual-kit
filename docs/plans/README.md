# Plans

Research and design records for major changes to this package. A plan states a problem,
measures current behavior, proposes a design, and names what would verify it. It is not
a task list and not a coding prompt.

Conventions follow the Victual repository's
[documentation guide](https://github.com/datagen24/victual/blob/master/docs/documentation.md):
numbered **Open questions** stay stable and review answers go inline as
`> **Response:**` blocks beneath them; a landed plan keeps its body in the original
present tense and gains an **Executed** section recording what actually shipped.

Architectural decisions are recorded in the Victual repository's
[ADR corpus](https://github.com/datagen24/victual/blob/master/docs/adr/README.md), not
here. This package holds no ADRs of its own; where a decision governs it, the ADR is the
authority and the plan cites it.

Plan numbers are permanent identifiers, not execution order.

## Status

This table is the authority on delivery status.

| # | Plan | Status | Dependencies or remaining work |
| --- | --- | --- | --- |
| 01 | [macOS stock application](01-macos-stock-app.md) | Scaffolded 2026-09-21; implementation not started | Structure, build plumbing and CI are in the tree. `VictualCore` mapping, `VictualStock` stores and the views are unwritten. |
