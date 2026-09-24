# Victual for iPhone

The second front end on this package, and the first that is not a Mac. What it adds is
**scanning**: point the camera at a package or a Victual label, see what it is, and book
it. See [docs/plans/02-iphone-scanning-app.md](../../docs/plans/02-iphone-scanning-app.md).

Three tabs. **Scan** opens first: a live camera scanner, with a photo picker and a
typed-code field as the other two ways in. **Stock** is the list, filtered by the server's
status buckets. **Settings** is the connection.

Behaviours that are deliberate, where changing one would be a regression:

- **"Use one" and "Open one" book without a form.** One tap is the point of scanning the
  thing in your hand. The undo bar is the safety net; everything needing an amount, a date
  or a place opens the form.
- **The client never interprets a scanned code.** It asks the server whether the code is
  one of its labels *and* whether it is a product barcode, together, and shows the answer
  ([ADR-0011](https://github.com/datagen24/victual/blob/master/docs/adr/0011-label-namespace.md)).
  The one rewrite is UPC-A ↔ EAN-13 on a miss; see `VictualClient+Scanning.swift`.
- **Every outcome says something.** An unknown code, a retired label and a label on a chore
  each have their own sentence. A retired label is a discrepancy a person can act on.
- **Bookings the key may not make are disabled, with the reason written underneath** —
  the Mac's rule, without tooltips.

## Running it on a phone

The live scanner needs a real device: VisionKit's `DataScannerViewController` is not
supported in the simulator at all. The simulator still runs the rest, and scanning from a
photo works there.

```
cd Apps/VictualPhone
xcodegen generate
open VictualPhone.xcodeproj
```

Then in Xcode: pick your team under **Signing & Capabilities** (it is not committed), trust
the `OpenAPIGenerator` plugin when asked, choose the phone as the destination, and run.

A household instance on plain `http` on the LAN is allowed (`NSAllowsLocalNetworking`);
anything reached over the internet still needs TLS.

## Keychain

The key is stored under its own service, `dev.victual.VictualPhone.api-key`, with
`afterFirstUnlock` accessibility — the setting the Siri concept
([§6.2](../../docs/concepts/siri-and-app-intents.md)) says a background intent will need,
and which cannot be changed later without migrating the item. No access group yet; that
arrives with the first extension.

## Name

The display name is **Victual**, matching the Mac. `CFBundleSpokenName` is `vittle`, so
VoiceOver and Siri *say* it correctly. Whether the phone should be called "Vittles" is the
concept's open question 3 and is not settled here.

## Where the code goes

As on the Mac: views here, stores in `Sources/VictualStock`, wire mapping in
`Sources/VictualCore`. The phone's `PhoneWorkspace` is the counterpart of the Mac's
`StockWorkspace`, plus the scanner. `BookingDraft` in `VictualStock` is shared by both apps'
booking forms, so they cannot disagree about what a valid booking is.

`project.yml` is the source of truth; `VictualPhone.xcodeproj` and `Resources/Info.plist`
are generated and not committed.
