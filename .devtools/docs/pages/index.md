<img class="wordmark light" src="assets/logo.svg" alt="Victual">
<img class="wordmark dark" src="assets/logo-dark.svg" alt="Victual">

# VictualKit

VictualKit is the Apple side of [Victual](https://victual.readthedocs.io/), a self-hosted
groceries and household management server. It holds a Swift package for talking to a
Victual instance, and the applications built on that package.

## The Swift package

[The package guide](package/index.md) is for someone building a Victual front end: the four
modules, connecting to an instance, reading stock, errors, and Keychain credential storage.
Its API layer is generated from the server's OpenAPI document, and
[Tracking the specification](package/openapi.md) records how that document is vendored,
which server release it is pinned to, and what the normalizer repairs.

The package needs a Victual server at **0.2.0-MVP or later**.

## The applications

[Victual for macOS](apps/macos.md) connects to an instance, shows a household's stock, and
books the five stock actions with undo. It is the package's first consumer, and how the
package's seams are tested against a real interface.

An iPhone application built around Siri is at the concept stage. Its design is in
[docs/concepts/](https://github.com/datagen24/victual-kit/tree/main/docs/concepts) in the
repository.

## Development

[The developer section](development/index.md) covers building and testing, the prose
checks, and how this site is assembled.

Design plans are not published here. They record work in progress, with delivery status as
of a date, and they live in
[docs/plans/](https://github.com/datagen24/victual-kit/tree/main/docs/plans) in the
repository. The boundary is the one the server's
[ADR-0020](https://victual.readthedocs.io/en/latest/development/adr/0020-documentation-publication-boundary/)
draws for its own site.
