# VictualKit

Swift bindings for the [Victual](https://github.com/datagen24/victual) REST API,
and the SwiftUI plumbing to build a Victual front end on any Apple platform.

The API layer is generated from Victual's own OpenAPI document, which this
repository tracks, normalizes and pins. Nothing about the endpoints is written by
hand, so an upstream change shows up as a compile error rather than a runtime
surprise.

## Modules

| Product | Contents |
| --- | --- |
| `VictualAPI` | Generated request/response types and the low-level client. All 145 operations. |
| `VictualCore` | `VictualServer`, `VictualAPIKey`, `VictualClient`, `VictualError`, and Keychain-backed credential storage. |
| `VictualUI` | `VictualSession` (`@Observable`), the SwiftUI environment key, and a ready-made `VictualConnectionView`. |
| `VictualStock` | Observable stores over the client — what a connection is used for. No views. |

`VictualUI` and `VictualStock` both depend on `VictualCore`, which depends on
`VictualAPI`. Import the highest layer you need.

`Apps/Victual` is a macOS application built on those products — the package's first
consumer, and how its seams get proven. See
[its README](Apps/Victual/README.md) and
[docs/plans/01-macos-stock-app.md](docs/plans/01-macos-stock-app.md).

## Requirements

Swift 6.0, and macOS 14 / iOS 17 / iPadOS 17 / tvOS 17 / watchOS 10 / visionOS 1.
The floor is set by the Observation framework, which `VictualSession` uses.

## Installation

```swift
.package(url: "https://github.com/datagen24/victual-kit.git", from: "0.1.0")
```

then depend on the products you need:

```swift
.product(name: "VictualUI", package: "victual-kit")
```

> Xcode will ask you to trust the `OpenAPIGenerator` build plugin the first time
> it builds the package. Command-line and CI builds need
> `-skipPackagePluginValidation`; see `Scripts/verify-platforms.sh`.

## Using it

```swift
import SwiftUI
import VictualUI

@main
struct VictualApp: App {
    @State private var session = VictualSession()

    var body: some Scene {
        WindowGroup {
            Group {
                if session.state.isConnected {
                    StockList()
                        .victualSession(session)
                } else {
                    VictualConnectionView(session: session)
                }
            }
            // Signs back in from the Keychain if this instance was used before.
            .task { await session.restore() }
        }
    }
}
```

Reading data, via the convenience layer:

```swift
import VictualCore

let client = try VictualClient(
    server: VictualServer(userEnteredText: "victual.example.com"),
    apiKey: "…"
)

let info = try await client.systemInfo()
let stock = try await client.currentStock()
```

Everything else goes through the generated client directly:

```swift
let response = try await client.underlying.getStockProductsByProductId(
    .init(path: .init(productId: 42))
)
let details = try response.ok.body.json
```

`VictualCore` deliberately does not wrap all 145 operations. The convenience
methods in `VictualClient+Convenience.swift` exist to cover the connection flow
and to demonstrate the pattern — generated call in, `VictualError` out. Add more
the same way as a front end needs them.

### Errors

Every convenience method throws `VictualError`, a flat enum over the failures a
UI actually has to distinguish (`.unauthorized`, `.forbidden`, `.notFound`,
`.badRequest`, `.serverError`, `.transportFailed`, `.decodingFailed`). It is
`Equatable` and `LocalizedError`, and `isRetryable` marks the cases where
retrying the identical request could plausibly work.

## Credentials

API keys go in the Keychain. `VictualSession` does it for you:

- a successful `connect()` saves the key and records the instance,
- `restore()` signs back in from what was saved, returning `false` when there is
  nothing to restore,
- `disconnect()` ends the session but keeps the key,
- `signOut()` removes the key and forgets the instance.

Only the instance address goes in `UserDefaults`, under
`VictualSession.lastServerDefaultsKey`. The key never does.

A Keychain failure is deliberately not fatal — it lands on
`session.credentialStoreError` while the session stays connected, because a key
that could not be saved only means the user types it again next launch.

### Configuring the store

`KeychainCredentialStore` writes one generic-password item per instance, keyed by
service and account (the instance URL), with the API path prefix in
`kSecAttrGeneric` so a `VictualServer` is rebuilt exactly rather than guessed at.

```swift
let store = KeychainCredentialStore(
    configuration: .init(
        service: "com.example.MyVictualApp.api-key",
        accessGroup: "ABCDE12345.com.example.shared",  // share with a widget
        accessibility: .afterFirstUnlock,              // survives a reboot for background refresh
        synchronizesWithiCloud: true                   // opt in to iCloud Keychain
    )
)
VictualSession(credentialStore: store)
```

Because it is keyed per instance, one app can hold keys for several servers at
once; `savedServers()` enumerates them.

Two things to know:

- `synchronizesWithiCloud` is off by default. It is the user's call whether a
  server credential leaves the device, and turning it on is incompatible with a
  `ThisDeviceOnly` accessibility.
- `usesDataProtectionKeychain` defaults to `true`, which is correct for any app
  bundle. A bare command-line or unit-test binary on macOS is not signed with a
  Keychain access group and needs it set to `false`.

For previews and tests, `InMemoryCredentialStore` is a complete implementation
that just does not outlive the process:

```swift
VictualSession(credentialStore: InMemoryCredentialStore())
```

## Tracking the OpenAPI specification

`Scripts/update-openapi.py` is the only thing that touches the spec:

```
Scripts/update-openapi.py            # fetch upstream, normalize, write, re-lock
Scripts/update-openapi.py --offline  # re-normalize the vendored copy
Scripts/update-openapi.py --check    # CI: fail if the artifacts are stale
```

| Path | What it is |
| --- | --- |
| `openapi/upstream/victual.openapi.json` | The upstream document, byte for byte. |
| `openapi/spec-lock.json` | Upstream commit, both checksums, and a report of every normalization applied. |
| `openapi/operation-ids.json` | Optional nicer names for individual operations. |
| `Sources/VictualAPI/openapi.json` | The normalized document the generator reads. Never edit by hand. |

CI runs `--check` on every pull request and weekly on a schedule, so an upstream
change surfaces as a failing job rather than as drift.

### What the normalizer fixes, and why

Victual's document is generated from Slim/PHP routes and did not load in
swift-openapi-generator as published.

As of upstream commit `5995cab` only repair 2 and repair 6 still do anything —
the sync report in `openapi/spec-lock.json` shows `pathsRewritten`,
`danglingRefsRepaired`, `nullableKeywordsConverted` and
`compositionConflictsResolved` all at zero, because upstream now publishes those
shapes correctly. The repairs stay in the script, and `Tests/VictualAPITests`
keeps asserting the shapes they produced: a repair that is a no-op today is a
guard against a regression tomorrow, and it costs nothing to leave standing.

1. **Slim route constraints in path templates.** Three routes are written
   `/labels/{kind:location|product|…}/{id:[0-9]+}/print`. That is not legal
   OpenAPI path templating; the constraint is already in the parameter's schema,
   so the suffix is stripped.
2. **No `operationId` anywhere.** All 145 operations would otherwise be named
   things like `get_sol_stock_sol_products_sol__lcub_productId_rcub_`. Names are
   derived deterministically from the route
   (`getStockProductsByProductIdPriceHistory`), with a collision check, and can
   be overridden per route in `openapi/operation-ids.json`.
3. **Five dangling `$ref`s.** The `entity` path parameter points at
   `ExposedEntity_NotIncludingNotListable` and four sibling variants that the
   document never defines; the generator rejects the whole document over it.
   They become a permissive `string`. Inventing an enum would assert an
   allow-list nobody wrote.
4. **OpenAPI 3.0 `nullable` inside a 3.1 document.** Twenty-five properties use
   the 3.0 spelling, which a 3.1 parser ignores. Two of them —
   `UserPermission.parent` and `UserPermission.via_roles` — are also `required`,
   so without translation to `["integer", "null"]` they generate as
   non-optional and every response where a permission has no parent fails to
   decode. `Tests/VictualAPITests` pins this.
5. **`type: object` alongside `oneOf`.** Contradictory, and rejected by the
   generator. The redundant `type` is dropped.
6. **The `servers` placeholder.** Upstream publishes `{"url": "xxx"}`. Victual
   is self-hosted, so it becomes the relative prefix `/api`; `VictualServer`
   supplies the origin at runtime.

### Known upstream issues left in place

These change what the API *says* it returns, so repairing them would mean
guessing at the contract. They are recorded in `openapi/spec-lock.json` under
`upstreamIssuesLeftInPlace` and are worth reporting upstream:

- `GET /user` types its 200 response as `{"type": "object", "items": {"$ref":
  ".../UserDto"}}`. `items` is meaningless on an object, so the response
  generates as a free-form `OpenAPIObjectContainer` instead of `UserDto`.

## Development

```
Scripts/build.sh test                  # swift test, with the generated-code noise filtered out
Scripts/verify-platforms.sh            # build every product for every supported platform
Scripts/update-openapi.py              # re-sync the specification
cd Apps/Victual && xcodegen generate   # regenerate the macOS application's project
```

Design records live in [docs/plans/](docs/plans/README.md). Architectural decisions do
not: those are in
[Victual's ADR corpus](https://github.com/datagen24/victual/blob/master/docs/adr/README.md),
which governs this package too.

`swift build` on its own only covers the host platform. `verify-platforms.sh`
drives `xcodebuild` across macOS, iOS, iOS Simulator, tvOS, watchOS and visionOS,
which is what catches the platform-conditional code in `VictualUI`.

Tests use Swift Testing and share `Tests/VictualTestSupport`, whose
`StubTransport` answers requests from a closure — so the client tests exercise
real request encoding and response decoding without a server.

## Licence

BSD 3-Clause. See [LICENSE](LICENSE).

`openapi/upstream/victual.openapi.json` is vendored verbatim from Victual and
carries that project's terms (MIT © Bernd Bestel for grocy-derived material, AND
BSD 3-Clause © Steven Peterson). No grocy-derived code is present in this
package.
