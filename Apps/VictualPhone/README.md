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
brew install xcodegen
cp Apps/Local.xcconfig.example Apps/Local.xcconfig   # once; put your Team ID in it
cd Apps/VictualPhone
xcodegen generate
open VictualPhone.xcodeproj
```

Then in Xcode: pick the **VictualPhone** scheme, trust the `OpenAPIGenerator` plugin when
asked, choose the phone (or a simulator) as the destination, and run. The first run on a
device needs Developer Mode on the phone and a trip to Settings > General > VPN & Device
Management if the profile is not yet trusted.

`Apps/Local.xcconfig` is gitignored and holds `DEVELOPMENT_TEAM`, read by `project.yml`
through `Apps/Base.xcconfig`. It lives outside the generated project, so `xcodegen
generate` cannot wipe it; setting the team in the Signing pane instead is lost on the next
generate. Debug uses automatic signing. Without the file everything still builds for the
simulator, unsigned, which is what CI does (`CODE_SIGNING_ALLOWED=NO`).

### HealthKit

`Resources/VictualPhone.entitlements` (generated from `project.yml`) carries
`com.apple.developer.healthkit`, and `Info.plist` carries `NSHealthShareUsageDescription`:
read-only, so there is no `NSHealthUpdateUsageDescription`. A device build needs a
provisioning profile that includes the HealthKit capability; with automatic signing and a
team set, Xcode requests it when you first build for the device. An unsigned build ignores
the entitlement, so CI is unaffected. See
[plan 03](../../docs/plans/03-healthkit-medication-sync.md).

### HealthKit device spike (debug builds)

Plan 03 Phase 0. A Debug build has **Settings > HealthKit spike** (top right); a Release
build does not contain it. It needs a physical iPhone on iOS 26 or later with medications
entered in the Health app (the simulator has none), and a signing team in
`Apps/Local.xcconfig`. It makes no network request and writes nothing to Health.

1. `cd Apps/VictualPhone && xcodegen generate`, open `VictualPhone.xcodeproj`, scheme
   **VictualPhone**, destination your phone, Run. Automatic signing adds the HealthKit and
   Background Delivery capabilities to the App ID on the first build.
2. Connect to any Victual instance (the spike is behind the connection screen). Open
   Settings, then **HealthKit spike**.
3. **1. Choose medications** and tick the ones to test. Include a tablet, a liquid and a
   single-use item if you have them. Each tap shows Health's sheet again, by design.
4. **2. Start listening**, then in the Health app log doses on those medications: one taken
   now, one skipped, one edited (change the quantity or time of a logged dose), one logged
   then undone, and one logged for an earlier time. Return to the spike after each and
   note the "s after start" for the dose you logged *now*.
5. **3. Try background delivery** for whether Health accepts the registration.
6. In Health, stop sharing one medication with Victual (Health > Sharing > Apps > Victual),
   then press **4. Re-query after revoking one**.
7. Quit and relaunch the app, press **1** and choose the same medications, to fill in "same
   as last launch". Then **Share report**: plain text with no medication names, for the
   plan's Executed section.

### Tests

The scheme's Test action (**Cmd-U**) runs the package's four test targets, as on the Mac;
pick a simulator or device destination. `swift test` at the repository root runs the same
tests. The app has no test target of its own. When the `VictualHealth` package target
lands, add its test target under the scheme's `test:` in `project.yml` and its product to
the app's `dependencies`.

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
