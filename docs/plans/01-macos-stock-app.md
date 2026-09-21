# 01. macOS stock application

**Goal:** a first-party macOS application that shows a household's stock and performs the
five stock bookings, and in doing so establishes the layering every other Apple-platform
front end will reuse.

**Depends on:** [ADR-0024](https://github.com/datagen24/victual/blob/master/docs/adr/0024-the-fork-writes-its-own-clients.md)
(Accepted 2026-09-15), which makes first-party clients this project's own responsibility.
Victual's [plan 17](https://github.com/datagen24/victual/blob/master/docs/plans/17-ecosystem-clients.md)
schedules Swift work behind plans 11, 14 piece 2 and 19 piece 2; all three landed by
2026-09-17.

**Status:** see the [plan index](README.md).

**Client impact:** none on the server. This plan consumes the existing wire contract and
proposes no endpoint, no response-shape change and no migration. Two package-internal
source breaks are proposed in [Design](#design).

## Problem and outcome

The package has no consumer. Three of 145 operations are wrapped, `currentStock()` hands
callers a generated `Components.Schemas.` type, and nothing exercises the session
plumbing end to end. Defects in that layering are currently invisible: they will be
discovered by whichever front end is written first, and the cost of finding them rises
with every additional platform that has already copied them.

The outcome is an application a household member uses daily on a Mac — see what is in
stock, what is due, what has run out, and record consuming and buying things — and a
package whose seams have been proven by a real UI rather than by inspection.

macOS is first rather than iOS, diverging from plan 17's 2026-08-29 posture. The reason
is verification, not preference: a macOS target builds and runs headlessly on a CI
runner, so every commit is checked by something. That divergence is not yet recorded in
the Victual corpus.

## Current behavior

`VictualSession` (`Sources/VictualUI/VictualSession.swift`) is `@MainActor @Observable`
and holds a connection: `connect()`, `restore()`, `disconnect()`, `signOut()`, a `State`
enum, and a `VictualClient?` that is non-nil only while connected. Connection errors land
on `state.error`; credential-store errors land on the separate `credentialStoreError`,
deliberately, because a key that could not be saved is not a broken session.

`VictualClient` (`Sources/VictualCore/VictualClient.swift:21`) holds the generated client
on `underlying` and prepends an `APIKeyAuthenticationMiddleware` that sets
`VICTUAL-API-KEY` on every request. `VictualError` is a flat nine-case enum with
`LocalizedError`, `Equatable` and `isRetryable`.

`VictualClient+Convenience.swift` wraps `systemInfo()`, `currentStock()` and
`verifyConnection()`, and its doc comment names itself the pattern for additions: a
generated call in, a `VictualError` out, through the private `perform(_:unwrap:)` helper
at line 72.

What does not exist: any domain model, any data store, any refresh policy, any
permission awareness, and any view beyond `VictualConnectionView`.

## Scope

**In scope.** Connection and Keychain restore. Current stock, with search, sort, and the
status filters the server already computes. Product detail with its stock entries. The
five bookings — consume, purchase, open, inventory correction, transfer — and undo.
Permission and read-only-key awareness in the UI.

**Out of scope, named.** Shopping list, chores, tasks, batteries, recipes, meal plan.
Barcode scanning. Label printing. Multi-instance switching, although
`KeychainCredentialStore.savedServers()` already supports it. Observation proposals:
[ADR-0012](https://github.com/datagen24/victual/blob/master/docs/adr/0012-observations-are-proposals.md)'s
contract is accepted and unbuilt, and a human-driven desktop application belongs on the
booking API regardless — the line that record draws is confidence, and this application
has none to declare.

## Constraints

These come from accepted records and from the API's documented behavior. They are
design inputs, not preferences.

| Source | Constraint |
| --- | --- |
| Victual plan 17 coupling 5; `docs/manual/operator/rest-api.md` | A field the authenticating key's owner may not see is **absent from the response, not null**. Price-bearing fields must be optional and read by presence; arithmetic over a missing one produces `NaN`. Naming such a field in `query[]` or `order` is answered `400`, not applied. |
| [ADR-0005](https://github.com/datagen24/victual/blob/master/docs/adr/0005-wire-contract-is-the-invariant.md) | The wire contract is stable. Two exceptions are documented there; one of them renders `chores.start_date` as `"2025-01-01 00:00:00"`, so date parsing must tolerate a time suffix on a `format: date` field. |
| [ADR-0011](https://github.com/datagen24/victual/blob/master/docs/adr/0011-label-namespace.md) | Label and barcode payloads are resolved **server-side**. A client never parses `vctl:` or `grcy:` locally, and an unknown or retired code fails visibly rather than resolving to the wrong thing. |
| [ADR-0012](https://github.com/datagen24/victual/blob/master/docs/adr/0012-observations-are-proposals.md) | Anything carrying a confidence value writes a proposal, never a booking. A client with no confidence to declare uses the booking API and must not invent one. |
| `docs/manual/operator/rest-api.md` | Authentication is the `VICTUAL-API-KEY` header. A key inherits its owner's permissions exactly; it is not a narrower credential. An MCP key may additionally be read-only. |

## Design

### Layering

Four layers, each with one job.

**`VictualAPI`** — generated, untouched by hand.

**`VictualCore`** — the wire boundary. Gains domain models and endpoint wrappers. Every
type that crosses out of this layer is hand-written, so a spec regeneration renaming a
generated symbol is a compile error in one file rather than a diff across the UI.

**`VictualStock`** (new library product) — observable stores over `VictualClient`. No
views, no platform conditionals, so a future iOS front end reuses it and `swift test`
covers it without an Xcode project.

**`Apps/Victual`** — SwiftUI views, macOS chrome, entitlements. Thin by intent.

`VictualUI` is deliberately not where the stores go: it is described as plumbing every
front end shares, and `Scripts/verify-platforms.sh` builds it for watchOS.

### `VictualCore` additions

Domain models — `StockSummary`, `ProductDetail`, `StockEntry`, `StockBooking`,
`VolatileStock`, `QuantityUnit`, `StorageLocation`, `VictualCapabilities` — mapped from
the generated schemas at the wrapper boundary. Three rules are applied once, here, rather
than at every call site:

- Price-bearing fields (`value`, `price`, `last_price`, `avg_price`, `stock_value`) stay optional and are never defaulted to zero. Absent means "not permitted to see", which renders as an em dash.
- `ProductWithoutUserfields` ships booleans as `integer` 0/1. They become `Bool` here.
- Dates arrive as strings — `Tests/VictualAPITests/GeneratedSpecTests.swift` pins `bestBeforeDate == "2026-01-31"`, confirming `format: date` generates as `Swift.String`. Parsing uses a fixed `en_US_POSIX` formatter tolerant of a `" 00:00:00"` suffix.

Endpoint wrappers in `VictualClient+Stock.swift` and `VictualClient+Bookings.swift`,
following the existing `perform(_:unwrap:)` pattern. Reads: `volatileStock(dueSoonDays:)`,
`productDetail(id:)`, `stockEntries(productID:includeSubProducts:)`, `capabilities()`,
and `quantityUnits()` / `locations()` over `listObjects` — amounts cannot be rendered
without quantity units, and the sidebar needs `locations_resolved`'s `path`. Writes: the
five bookings and `undoTransaction(id:)`.

Every booking returns `StockBooking`, carrying the `transaction_id` the log rows share
plus the rows themselves. One user action produces several rows under one transaction, so
undo is offered per transaction, not per row.

`stock_entry_id` requires `amount == 1`. The wrapper rejects the combination as
`.badRequest` before the round trip rather than spending a request to be told.

**Source breaks:** `currentStock()` changes its return type from
`[Components.Schemas.CurrentStockResponse]` to `[StockSummary]`. There are no consumers
outside this repository, and the package has not been tagged.

### `VictualStock`

`StockStore` (summaries, the four volatile buckets, filter and sort state, load state,
`refresh()`); `ProductDetailStore`; `BookingController` (performs a booking, holds the
last `StockBooking` for the undo affordance, surfaces `VictualError`); `CapabilityGate`
over `VictualCapabilities`; and `ChangePoller`.

`ChangePoller` polls `GET /system/db-changed-time` and refreshes only when the timestamp
moves, rather than re-fetching `/stock` on a timer. `GET /stock/volatile` returns due,
overdue, expired and below-minimum in one response, so the dashboard costs one request.

### Permission awareness

`GET /user/capabilities` answers `key_type`, `read_only` and the acting user's resolved
`permissions[]`. `CapabilityGate` turns that into `canConsume` (`STOCK_CONSUME`),
`canPurchase` (`STOCK_PURCHASE`), `canOpen` (`STOCK_OPEN`), `canInventory`
(`STOCK_INVENTORY`), `canTransfer` (`STOCK_TRANSFER`), `canSeePrices`
(`STOCK_PRICES_VIEW`) and `isReadOnlyKey`.

Booking commands are **disabled with a tooltip naming the missing permission**, not
hidden. A household member should be able to see that consume exists and that they lack
the permission for it; a control that vanishes teaches nothing. The price column is the
exception — it is absent rather than empty, because a column of em dashes is worse than
no column.

Capabilities are a courtesy. `403` is still handled on every write: the key's permissions
can change between the capability fetch and the booking.

### Application shell

`NavigationSplitView`. Sidebar: All, Due soon, Overdue, Expired, Below minimum, then the
locations tree built from `locations_resolved`'s `path`. Content: a `Table` of stock.
Detail: a product inspector listing stock entries. Booking sheets for the five actions,
an undo affordance after each, and a commands menu.

App Sandbox with `com.apple.security.network.client`. The application sets its own
`KeychainCredentialStore.Configuration` service rather than inheriting the package
default, so a package test and a shipped application never contend for the same item.

### Project generation

`Apps/Victual/project.yml` is an XcodeGen manifest; the `.xcodeproj` is generated and not
committed. The repository already treats `Sources/VictualAPI/openapi.json` as generated
output with a checked-in source of truth, and this is the same arrangement: a reviewable
diff, and no `project.pbxproj` merge conflicts when two branches add files.

## Alternatives

**Views in the package rather than the application.** Would put them under `swift test`'s
compiler without an Xcode project. Rejected for now: macOS-shaped views would need
`#if os(macOS)` fences to survive `verify-platforms.sh`'s watchOS build, and the CI job
described below compiles them anyway. Worth revisiting when an iOS front end exists and
there is a real second consumer to share against.

**Generated types straight to the UI.** Fewer lines, no mapping layer. Rejected: the
2026-09-21 re-sync changed generated symbols, and will again. ADR-0005 stabilizes the
JSON, not the Swift.

**Gate purely on observed `403`.** Simpler, one fewer request. Rejected as the only
mechanism: a disabled control with a reason is a better answer than an error after the
fact. Retained as the backstop.

## Dependencies

- Upstream OpenAPI at commit `5995cab` or later, for `/user/capabilities`. Pinned in `openapi/spec-lock.json` as of 2026-09-21.
- XcodeGen, on a developer machine and on the CI runner.
- Swift 6.0, macOS 14.

## Open questions

1. **Distribution.** Victual plan 17's Q3 is open, and a Mac target can be notarized for direct distribution without the App Store while iOS has no equivalent. Nothing here depends on the answer — the application builds and runs unsigned locally — but the entitlement set and the Keychain configuration do eventually.

2. **Where the price column's absence is decided.** `CapabilityGate.canSeePrices` reads `STOCK_PRICES_VIEW`, but the server also simply omits the fields. The two should agree; if they ever disagree, the response is the authority and the gate is stale. Whether the UI should notice that disagreement or quietly follow the data is unsettled.

3. **Refresh interval.** `db-changed-time` polling is cheap but not free. A sensible default while the window is key, and whether to stop entirely when it is not, needs measurement rather than a guess.

## Verification

1. `Scripts/build.sh test` — all targets, including a test asserting the encoded JSON body of each of the five bookings, and one asserting that a `CurrentStockResponse` with `value` absent decodes to `nil` rather than `0`.
2. `Scripts/update-openapi.py --check` reports the spec in sync.
3. `Scripts/verify-platforms.sh` builds every platform including macOS.
4. CI's `app` job generates the project and builds the application.
5. Against a live instance, on a Mac: connect with an API key; relaunch and confirm the Keychain restores the session; consume one of a product and undo it, confirming the amount returns; sign in with a key whose owner lacks `STOCK_PRICES_VIEW` and confirm the price column is absent and nothing renders `0.00`; sign in with a read-only MCP key and confirm the booking commands are disabled and say why.

Items 1 through 4 run unattended. Item 5 needs a Mac and a real instance, and is the only
one that exercises the Keychain against a signed bundle.
