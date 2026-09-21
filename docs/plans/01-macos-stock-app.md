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

## Executed

Landed 2026-09-21 on `claude/victual-macos-app-abd0b0`, in three commits — the
`VictualCore` boundary, the `VictualStock` stores, and the application's views.
Items 1 through 4 of [Verification](#verification) pass; item 5 is outstanding
and is described at the end of this section.

### What shipped as designed

The layering, the domain models, the endpoint wrappers, the five stores and the
three-column window are as [Design](#design) describes them. `currentStock()`
returns `[StockSummary]`, which is the source break this plan proposed. Booking
commands are disabled with a tooltip naming the missing permission; the price
column is absent rather than empty without `STOCK_PRICES_VIEW`. Undo is offered
per transaction. `stock_entry_id` with an amount other than 1 is refused before
the round trip, and a test asserts no request reaches the transport.

### What this plan did not anticipate

**`format: date-time` fields did not decode at all.** This plan's third mapping
rule covers `format: date`, which generates as `Swift.String` and is parsed by
hand. It says nothing about `format: date-time`, which generates as
`Foundation.Date` and is decoded by the runtime's **strict ISO 8601** reader —
while the server renders those fields the way its database stores them,
`"2019-05-03 18:24:04"`, as the specification's own examples show throughout.
Every read carrying `row_created_timestamp` — a stock entry, a location, a
quantity unit, a booking's log rows — and `GET /system/db-changed-time` would
have failed outright with a decoding error.

`VictualDates` installs a `DateTranscoder` on the client configuration that
reads ISO 8601 first and the database renderings second. This is the same
exception [ADR-0005](https://github.com/datagen24/victual/blob/master/docs/adr/0005-wire-contract-is-the-invariant.md)
documents for `chores.start_date`, one layer down and applying to every
timestamp rather than to one field. It is worth recording upstream that the
exception is general, not particular.

**`GET /objects/{entity}` cannot be read through the generated client.** This
plan proposed `quantityUnits()` and `locations()` "over `listObjects`". The
route's response is an undiscriminated `oneOf` over nine entity schemas, which
the generator decodes by trying each in declaration order and keeping the first
that succeeds. `Product` is declared first and has no required properties, so
every row of every entity decodes as a `Product`: a quantity unit loses
`name_plural`, and a `locations_resolved` row — whose schema is not in the union
at all — loses `path`. Both are exactly what this plan needs them for.

That one route is therefore issued directly, through the same transport and the
same middleware chain the generated client uses, and decoded into hand-written
rows. It is the only such exception in the package and is documented where it
lives. It is also worth reporting upstream: a discriminator, or simply declaring
`id` required on `Product`, would make the union decodable.

**Every write was refused, and the specification could not have shown it.** Two
disagreements between what the document says and what the server does, neither
reachable by a test built from the document — a stub made from the specification
agrees with the specification. Both were found the first time a booking was sent
to a real instance, and between them nothing could be written at all.

`swift-openapi-runtime` sends `Content-Type: application/json; charset=utf-8`.
Victual compares that header against the literal `application/json` with `!=`
(`BaseApiController::GetParsedAndFilteredRequestBody`), so the parameter fails
it and every booking is answered `400 Bad Content-Type`. RFC 9110 allows
parameters and expects a receiver to parse the media type, so the server is
wrong — but deployed instances will not care, so
``JSONContentTypeMiddleware`` drops the parameter on the way out.

`StockLogEntry.spoiled` and `CurrentStockResponse.is_aggregated_amount` are typed
`boolean` and arrive as `0`/`1`: the first is an `integer` column, the second is
assigned a bare number in `StockService.php`. A strict decoder refuses `0` where
it was promised `true`, so all five bookings threw while decoding their own
result — *after* the booking had been written, which is the worst shape such a
failure can take. `Scripts/update-openapi.py` retypes them, consistently with
every other 0/1 flag in the document, and this layer maps them back to `Bool`.
The repair is deliberately surgical: `ProductDetailsResponse.has_childs` goes
through `boolval()` and `CurrentUserCapabilities.read_only` through a PHP
comparison, so both really are booleans and a test says they were left alone.

This is what the plan's third mapping rule was reaching for, and it turns out to
be broader than `ProductWithoutUserfields`. Both defects are worth reporting
upstream.

### Where the design was extended

**The locations sidebar reads `GET /stock/locations/{id}/entries`.** This plan
said the sidebar gains a locations tree without saying what selecting one shows.
Filtering `GET /stock` was the obvious reading and is wrong: that endpoint
reports a product's *default* location, which stops describing where the stock
is the moment anything is transferred. The dedicated endpoint reports what is
actually there.

A location's value is computed with the server's own formula — price times
amount, summed — and goes absent as soon as any lot in it carries no price.
Summing only the priced lots would understate the total, which is the same
mistake as defaulting a missing price to zero, one step removed.

**`CapabilityGate` reads permissively until the server answers**, and treats
`ADMIN` as a superuser marker. The first is so a window does not open with every
control greyed out, wrongly, for the moment before `/user/capabilities`
returns; the second is defensive, since the endpoint documents its permissions
as already resolved. Both lean on the same backstop this plan names: `403` is
handled on every write regardless.

**`ChangePoller` gives up after three consecutive failures** rather than raising
an error every interval forever. Polling is an optimisation over re-fetching
`/stock` on a timer, and the application works by hand without it.

**The price column needs two `Table` expressions**, not one conditional column:
`TableColumnBuilder.buildIf` requires macOS 14.4 and this plan's floor is
macOS 14. The columns are declared once and shared between them.

### Open questions, revisited

2. **Where the price column's absence is decided.** Still unsettled, but the
   two absences are now distinguishable in the UI rather than conflated. When
   `canSeePrices` is false the column is not rendered. When it is true, an em
   dash inside the column means the server reported no price for that stock —
   which is a different statement, and reads as one.

3. **Refresh interval.** `ChangePoller.interval` defaults to 30 seconds, which
   is a starting point and not the measurement this question asks for. The
   poller is stopped on `onDisappear`; whether to stop when the window merely
   loses key is still unmeasured.

### Verification item 5 is outstanding

Items 1 through 4 run unattended and pass: `Scripts/build.sh test` (136 tests),
`Scripts/verify-platforms.sh` (all six platforms, `VictualStock` included),
`Scripts/update-openapi.py --check`, and an `xcodebuild` of the application.

Item 5 — the four checks against a live instance — is **not** done. The
application launches, and `VictualCore` was confirmed against a real instance
through the real `URLSession` transport: a rejected key returns `401`, which
maps to `.unauthorized` and renders as "The API key was not accepted."

The instance available for testing is **Victual 4.6.0 at migration 286**, which
is behind this plan's stated dependency in two ways that matter:

- `GET /user/capabilities` answers `404`. The route arrived with upstream
  `5995cab`, which [Dependencies](#dependencies) names. Checks 3 and 4 both rest
  on `CapabilityGate`, so neither can be demonstrated there at all.
- `api_keys.read_only` does not exist; it arrives in migration `0287`. A
  read-only MCP key cannot be created, so check 4 has no subject.

That turned up something worth having: an instance old enough to 404 that route
exists in the wild, so the application's behaviour against one is now pinned by
a test rather than assumed. `CapabilityGate` records the `404` and leaves every
gate open, which means an older server is fully usable and the server's own
`403` and field omission remain the backstop — the degradation this design
already intended, now demonstrated against the case that provoked it.

**Check 2 passes.** Driven through this package's own wrappers against that
instance: purchase three, and stock goes 9 to 12; consume one, and it goes to
11; undo the transaction, and it returns to 12. The booking's `transaction_id`
is what undo is addressed to, and `spoiled` maps back from the wire's `0` to
`false`. The reads were exercised at the same time and all decode from real
rows — quantity units keeping `name_plural`, a location keeping its `path`,
`row_created_timestamp` arriving as `"2026-09-19 14:30:23"` and parsing,
prices visible at `17.91` for nine packs at `1.99`, and the below-minimum
bucket reporting the shortfall. Both fixes above were found and made in the
course of it.

**Check 1 — Keychain restore — is still undone.** It needs the key typed into
the connection form, and that field is a `SecureField`; background automation
cannot type into a password field, so finishing it means taking over the
screen. Nothing about the code is suspected: `VictualSession.restore()` is
covered by `Tests/VictualUITests`, and what remains untested is specifically
the data-protection Keychain against a signed bundle, which no unit test
reaches.

The temporary product, its stock and the temporary API key were removed
afterwards; the instance was left as it was found.
