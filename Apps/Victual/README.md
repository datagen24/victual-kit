# Victual for macOS

The first front end built on this package, and the thing that proves it. What it is meant
to do, and why it is layered the way it is, is in
[docs/plans/01-macos-stock-app.md](../../docs/plans/01-macos-stock-app.md).

It connects to an instance, restores from the Keychain, and shows a household's stock: a
sidebar of the server's status buckets and the locations tree, a table of stock, a product
inspector, and the five bookings with undo.

Two behaviours are deliberate, and changing either one would be a regression:

- **Booking commands are disabled, not hidden**, when the key's owner lacks the permission,
  and the tooltip names it. A household member should be able to see that consume exists
  and that they lack `STOCK_CONSUME`.
- **The price column is absent, not empty**, without `STOCK_PRICES_VIEW` — a column of em
  dashes is worse than no column. Inside a column that *is* shown, an em dash means no
  price was recorded, which is a different statement.

## Version

`0.3.0`, following Victual's own scheme: the application carries the version of the
server it was built against, so the application and the instance it talks to read as one
project. The application needs a server at 0.3.0; see the
[package requirements](../../Sources/README.md#requirements). The earlier `-MVP` suffix
was a release stage, and the server dropped it at 0.3.0. The scope is unchanged: the five
bookings and the stock a household reads daily, and deliberately nothing else
(see plan 01's [Scope](../../docs/plans/01-macos-stock-app.md#scope)).

`CURRENT_PROJECT_VERSION` stays a plain integer, because that is the one the
system orders builds by.

The suffix drops when the application moves to production. That is also what
makes it submittable: `CFBundleShortVersionString` is meant to be a
period-separated list of integers and the App Store enforces it, so a build
still carrying `-MVP` would fail validation. The two happen together, so this is
worth knowing rather than planning around.

## Building it

```
brew install xcodegen
cp Apps/Local.xcconfig.example Apps/Local.xcconfig   # once; put your Team ID in it
cd Apps/Victual
xcodegen generate
open Victual.xcodeproj
```

Pick the **Victual** scheme and run. `Apps/Local.xcconfig` is gitignored and holds
`DEVELOPMENT_TEAM`, which `project.yml` reads through `Apps/Base.xcconfig`. It lives outside
the generated project, so `xcodegen generate` cannot wipe it; setting the team in Xcode's
Signing pane instead is lost on the next generate. Without the file everything still
builds, unsigned or ad-hoc, which is what CI does.

`project.yml` is the source of truth; `Victual.xcodeproj`, `Resources/Info.plist` and
`Resources/Victual.entitlements` are generated from it and are not committed. Re-run
`xcodegen generate` after adding or removing a file. The same arrangement already governs
`Sources/VictualAPI/openapi.json`: a reviewable manifest in the tree, generated output
out of it.

CI does the same thing on every pull request, in the `app` job.

### Tests

The scheme's Test action (**Cmd-U**) runs the package's four test targets
(`VictualAPITests`, `VictualCoreTests`, `VictualUITests`, `VictualStockTests`), so the
whole suite runs from the IDE. `swift test` at the repository root runs the same tests.
The app has no test target of its own: its logic lives in the package. When a new package
test target is added, list it under the scheme's `test:` in `project.yml`.

## Signing

`CODE_SIGN_IDENTITY` is `-`, so it builds and runs ad-hoc signed with no developer
account. A distribution identity is plan 01's open question 1 and is not answered yet.

That has one consequence worth knowing. The **data-protection Keychain is off**, because
it requires an access group that comes from a signing identity's team and an ad-hoc build
has none: with it on, every save is refused with `errSecMissingEntitlement`, nothing is
remembered, and the next launch asks for the key again. The application uses the
file-based Keychain instead — see `VictualApp.credentialStore`, which says to turn it back
on once there is a real identity.

A side effect during development: each rebuild changes the ad-hoc signature, so macOS asks
once per build whether the new binary may read the item it saved. A shipped build has a
stable signature and asks once.

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
