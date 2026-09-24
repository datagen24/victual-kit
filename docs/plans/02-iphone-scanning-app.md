# 02. iPhone scanning application

**Goal:** an iPhone application built on the layering plan 01 established, whose addition
is barcode and label scanning: point the camera at a package or a Victual label, learn what
it is, and book it in one tap.

**Depends on:** [plan 01](01-macos-stock-app.md) (the layers and stores);
[ADR-0011](https://github.com/datagen24/victual/blob/master/docs/adr/0011-label-namespace.md)
(label payloads are resolved server-side).

**Status:** see the [plan index](README.md).

**Client impact:** none on the server. Reads `GET /labels/resolve/{code}`,
`GET /stock/products/by-barcode/{barcode}` and `GET /stock/entry/{entryId}`, which already
exist.

## Problem and outcome

Plan 01 named barcode scanning out of scope. A Mac is the wrong device for it; a phone is
the right one. The household's phones are iPhone 16s on iOS 27, all of which support
VisionKit's live scanner.

The outcome: take a package out of the fridge, scan it, tap "Use one". Scan a location
label and see what is in it. Scan a label whose target is gone and be told so.

## Design

### Resolution is the server's

ADR-0011 forbids a client parsing `vctl:` or `grcy:` payloads. The obvious reading — "check
the prefix, then call the right endpoint" — is already a parse. So
`VictualClient.resolveScan(_:)` asks **both** questions of every code, concurrently:

- `GET /labels/resolve/{code}` — is this one of Victual's labels?
- `GET /stock/products/by-barcode/{code}` — is this a product's barcode, or a legacy
  `grcy:p:` code?

A label answer wins, following ADR-0011 item 2's order. The cost is a second request per
scan, sent in parallel, so latency is one round trip.

Outcomes are a `ScanResolution`: a product; one specific lot (a per-unit label); a location;
a label on something this app has no screen for (a recipe, a chore, a battery, or a kind
newer than the package); a retired label with what it used to be on; or unknown. None of
them is an error. Unknown is the ordinary answer for a new package.

### What the specification does not say

- **`/labels/resolve` resolves six kinds, not one.** The pinned specification (`5995cab`)
  declares `kind` as `const: location`. The server's `LabelIdentityService` resolves
  location, product, stock_entry, recipe, chore and battery. The generated decoder reads
  `kind` as an untyped container, so the wider set decodes; `LabelKind` maps all six and
  keeps any other kind as `.other(String)` rather than dropping it.
- **An unknown barcode is `400`, not `404`.** `GetProductIdFromBarcode` throws, and the
  controller maps the throw to `400`. So does a Grocycode naming something other than a
  product. Both read as "not a product barcode".
- **Older instances have no `/labels/resolve`.** A `404` there is read as "no label", so
  product barcodes keep working — the same degradation `CapabilityGate` gets.

### UPC-A and EAN-13

Apple's scanners report a UPC-A code as 13 digits with a leading zero. A barcode typed into
the web UI, or read by its scanner, is often the 12-digit form. The server matches the
stored string exactly. So on a miss, an all-digit 13-character code with a leading zero is
retried without it, and a 12-digit one with one. This is the only rewrite; it concerns
retail symbologies, not Victual's namespaces.

### Debouncing the camera

A live scanner reports a code for as long as it is in frame. `ScanStore` ignores the code it
last saw for a sliding three seconds, and keeps it in that window after the result is
dismissed — otherwise the card pops straight back up with the package still in hand. A
typed code or a photo is deliberate and skips the window.

### One tap

"Use one" and "Open one" book immediately. Everything else opens a form. The undo bar is the
safety net, as on the Mac. Consume via Siri still requires confirmation (concept §7.5); a
visible tap on a visible product is not the same risk.

### A shared booking draft

`BookingDraft` in `VictualStock` holds a booking form's fields, validation and request
building. Both the phone's form and the Mac's `BookingSheet` edit one, so they cannot
disagree about what is valid. Moving it there changed one Mac behaviour: a purchase used to
pre-fill the due date with the product's *oldest lot's* date. It now omits the date by
default, and the server applies the product's own shelf life — including its after-freezing
rule for a freezer — which a pre-filled date bypasses.

### Application shell

Three tabs: Scan (opens first), Stock, Settings. The scan result is a card over the camera
rather than a sheet: the camera keeps running, so the next package replaces the card, and a
booking form can still be presented. VisionKit's `DataScannerViewController` for live
scanning; Vision's `DetectBarcodesRequest` for photos. Symbologies: retail linear codes,
QR (new labels) and DataMatrix (legacy Grocycodes).

iOS 18 floor. Keychain accessibility `afterFirstUnlock`, per the Siri concept §6.2, set now
because changing it later is a migration. `NSAllowsLocalNetworking`, because a household
instance on plain `http` on the LAN is the normal case.

## Out of scope, named

Linking an unknown barcode to a product (`POST /objects/product_barcodes`, which needs
`MASTER_DATA_EDIT` and runs into the same `objects` union plan 01 documents). A continuous
"scan to consume" mode. The shopping list. App Intents and Siri. Label printing.

## Verification

1. `swift test` — including the scan resolution suite (product, location, product label,
   stock-entry label, retired, other kind, older instance, `401`, whitespace, path
   encoding), the UPC-A/EAN-13 retry, `ScanStore`'s debouncing, and `BookingDraft`.
2. The macOS application still builds, now on `BookingDraft`.
3. CI's `phone` job generates the project and builds for the iOS Simulator.
4. On an iPhone, against a live instance: scan a product's barcode and see its stock; "Use
   one" and undo, confirming the amount returns; scan a location label; scan a retired
   label; scan an unknown barcode.

## Executed

Built 2026-09-24. Items 1 and 2 pass: 174 package tests, and an `xcodebuild` of the Mac
application. The phone application builds for the iOS Simulator with no warnings in its
sources, and launches to the connection form.

**Item 4 is not done.** No live instance was running. A simulator pass against a stub
server was abandoned: running two simulators plus Xcode through its MCP exhausted the
build machine's memory, and the iOS 27 simulator crash-looped `intelligencetasksd`
throughout. The live scanner cannot run in a simulator in any case, so item 4 belongs on a
phone.
