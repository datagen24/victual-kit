# The VictualKit package

Swift bindings for the [Victual](https://github.com/datagen24/victual) REST API, and the
SwiftUI plumbing to build a Victual front end on any Apple platform.

The API layer is generated from Victual's own OpenAPI document, which this repository
tracks, normalizes and pins; see [openapi/](../openapi/README.md). Nothing about the
endpoints is written by hand, so an upstream change shows up as a compile error rather
than a runtime surprise.

## Modules

| Product | Contents |
| --- | --- |
| `VictualAPI` | Generated request/response types and the low-level client. All 145 operations. |
| `VictualCore` | `VictualServer`, `VictualAPIKey`, `VictualClient`, `VictualError`, and Keychain-backed credential storage. |
| `VictualUI` | `VictualSession` (`@Observable`), the SwiftUI environment key, and a ready-made `VictualConnectionView`. |
| `VictualStock` | Observable stores over the client — what a connection is used for. No views. |

`VictualUI` and `VictualStock` both depend on `VictualCore`, which depends on
`VictualAPI`. Import the highest layer you need.

## Requirements

- Swift 6.0, and macOS 14 / iOS 17 / iPadOS 17 / tvOS 17 / watchOS 10 / visionOS 1. The
  floor is set by the Observation framework, which `VictualSession` uses.
- A Victual server at **0.2.0-MVP or later**. That release changed how timestamps are
  documented and made the server send its documented booleans as `true`/`false`
  ([issue #230](https://github.com/datagen24/victual/issues/230)). The package follows
  the new contract, and a booking response from an older server does not decode.

## Installation

The package has no tagged release yet, so depend on its main branch:

```swift
.package(url: "https://github.com/datagen24/victual-kit.git", branch: "main")
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

`VictualCore` deliberately does not wrap all 145 operations. It wraps five groups:

- the connection flow (`VictualClient+Convenience.swift`);
- the stock reads (`VictualClient+Stock.swift`);
- scan resolution (`VictualClient+Scanning.swift`);
- the five bookings and undo (`VictualClient+Bookings.swift`);
- the entity listings a stock list cannot render without (`VictualClient+Objects.swift`).

Add more the same way as a front end needs them: generated call in, `VictualError` out, a
hand-written type across the boundary.

Three rules are applied once, at that boundary, rather than at every call site:

- **Price-bearing fields are read by presence.** `value`, `price`, `last_price`,
  `avg_price` and `stock_value` are absent from the response — not null — for a
  caller without `STOCK_PRICES_VIEW`. They stay optional and are never defaulted
  to zero. For the same reason the wrappers expose neither `query[]` nor `order`:
  naming a price field in either is answered `400` rather than applied.
- **Timestamps are parsed from the server's own rendering.** Victual renders a timestamp
  as a local wall-clock value, `"2019-05-03 18:24:04"`, which is not RFC 3339. Since
  0.2.0-MVP the specification says so
  ([ADR-0027](https://github.com/datagen24/victual/blob/master/docs/adr/0027-timestamps-are-local-strings-documented-booleans-are-booleans.md)),
  and those fields generate as strings. `VictualDates.timestamp(_:)` reads that rendering,
  ISO 8601, and the PostgreSQL `TIMESTAMPTZ` form that label fields such as `retired_at`
  use. `VictualDates.day(_:)` reads calendar days, with or without a `" 00:00:00"` suffix.
- **Timestamps are read in the instance's time zone.** A timestamp without an offset is the
  server's local time, so `verifyConnection()` learns the zone from `GET /system/time` and
  every copy of the client reads such timestamps in it. One that states an offset keeps
  it. Calendar days (`best_before_date`) are not instants and stay in the device's zone.
- **`integer` 0/1 flags become `Bool`.** Flags the document types `boolean` already
  arrive as booleans.

### Errors

Every convenience method throws `VictualError`, a flat enum over the failures a
UI actually has to distinguish (`.unauthorized`, `.forbidden`, `.notFound`,
`.badRequest`, `.serverError`, `.transportFailed`, `.decodingFailed`). It is
`Equatable` and `LocalizedError`, and `isRetryable` marks the cases where
retrying the identical request could plausibly work.

## Credentials

API keys go in the Keychain. `VictualSession` stores and removes them:

- a successful `connect()` saves the key and records the instance,
- `restore()` signs back in from what was saved, returning `false` when there is
  nothing to restore,
- `disconnect()` ends the session but keeps the key,
- `signOut()` removes the key and forgets the instance.

Only the instance address goes in `UserDefaults`, under
`VictualSession.lastServerDefaultsKey`. The key never does.

A Keychain failure is deliberately not fatal. It lands on
`session.credentialStoreError` while the session stays connected, because a key that
could not be saved only means the user types it again next launch.

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

Two settings need care:

- `synchronizesWithiCloud` is off by default. It is the user's call whether a
  server credential leaves the device, and turning it on is incompatible with a
  `ThisDeviceOnly` accessibility.
- `usesDataProtectionKeychain` defaults to `true`, which is correct for any app
  bundle. A bare command-line or unit-test binary on macOS is not signed with a
  Keychain access group and needs it set to `false`.

For previews and tests, `InMemoryCredentialStore` is a complete implementation
that does not outlive the process:

```swift
VictualSession(credentialStore: InMemoryCredentialStore())
```

## Testing

Tests use Swift Testing and share `Tests/VictualTestSupport`, whose `StubTransport`
answers requests from a closure. The client tests therefore exercise real request
encoding and response decoding without a server.

```sh
Scripts/build.sh test          # swift test, with the generated-code noise filtered out
Scripts/verify-platforms.sh    # build every product for every supported platform
```

`swift build` on its own only covers the host platform. `verify-platforms.sh` drives
`xcodebuild` across macOS, iOS, iOS Simulator, tvOS, watchOS and visionOS, which is what
catches the platform-conditional code in `VictualUI`.
