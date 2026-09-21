# Victual for macOS

The first front end built on this package, and the thing that proves it. What it is meant
to do, and why it is layered the way it is, is in
[docs/plans/01-macos-stock-app.md](../../docs/plans/01-macos-stock-app.md).

It connects to an instance, restores from the Keychain, and shows a household's stock: a
sidebar of the server's status buckets and the locations tree, a table of stock, a product
inspector, and the five bookings with undo.

Two behaviours are deliberate and easy to "fix" wrongly:

- **Booking commands are disabled, not hidden**, when the key's owner lacks the permission,
  and the tooltip names it. A household member should be able to see that consume exists
  and that they lack `STOCK_CONSUME`.
- **The price column is absent, not empty**, without `STOCK_PRICES_VIEW` — a column of em
  dashes is worse than no column. Inside a column that *is* shown, an em dash means no
  price was recorded, which is a different statement.

## Building it

```
brew install xcodegen
cd Apps/Victual
xcodegen generate
open Victual.xcodeproj
```

`project.yml` is the source of truth; `Victual.xcodeproj`, `Resources/Info.plist` and
`Resources/Victual.entitlements` are generated from it and are not committed. Re-run
`xcodegen generate` after adding or removing a file. The same arrangement already governs
`Sources/VictualAPI/openapi.json`: a reviewable manifest in the tree, generated output
out of it.

CI does the same thing on every pull request, in the `app` job.

## Signing

`CODE_SIGN_IDENTITY` is `-`, so it builds and runs ad-hoc signed with no developer
account. That is enough for the data-protection Keychain to work locally. A distribution
identity is plan 01's open question 1 and is not answered yet.

CI builds with `CODE_SIGNING_ALLOWED=NO`, which is enough to find a compile error and not
enough to exercise the Keychain — that path is verified on a developer machine.

## Where the code goes

The application target holds views and macOS chrome, and is meant to stay thin.
Everything below a view belongs in the package, where `swift test` reaches it without an
Xcode project:

| Layer | Holds |
| --- | --- |
| `Sources/VictualCore` | Domain models and endpoint wrappers. The boundary where generated `Components.Schemas.` types stop being visible. |
| `Sources/VictualStock` | Observable stores: fetching, filtering, refresh policy, permission gating. No views. |
| `Apps/Victual/Sources` | SwiftUI views, commands, entitlements. |
