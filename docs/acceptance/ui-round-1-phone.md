# Phone app UI round 1 (iOS Simulator)

**Evidence class: SIMULATOR-BUILD/UI evidence only. None of it is DEVICE evidence.**

| | |
|---|---|
| Build | `Apps/VictualPhone` at the v0.4.0 spec pin, Debug, `xcodebuild` generic simulator destination |
| Simulator | one iPhone 18 Pro, iOS 27.0 (the newest installed runtime; iOS 26.5 also present but not used) |
| Server | the dev instance (Victual 0.4.0, plain HTTP, private LAN address) |
| Data | `ui1-` fixtures from `Scripts/seed-ui-fixtures.sh` (2 locations, 4 products, one below its minimum) |
| Keys | Adult user (non-admin, no MASTER_DATA_EDIT), Child user (STOCK_VIEW/CONSUME/OPEN), admin only for seeding |

Screenshots were taken (49 files) but are deliberately not committed; the filenames below are the scratchpad names.

## Build deviation that matters for case 1 and case 6

An **unsigned** build (`CODE_SIGNING_ALLOWED=NO`) behaved as if connecting did nothing: the process stayed alive, the
Connect form stayed up, and no error was shown, for the nip.io host and for the bare IP. A copy re-signed ad hoc with
a keychain entitlement connected normally.

I did not capture logs, so I cannot say whether the cause was the missing keychain entitlement, App Transport
Security, or both (I changed ATS and signing together; see D1). Everything after case 1 was run on a build signed with
`CODE_SIGN_IDENTITY=-` and, for the first connect, with ATS relaxed in the Info.plist of a throwaway copy. That is a
signing and test artifact, but D8 records the missing failure UI.

## Results

Legend: PASS, FAIL (defect), PARTIAL, BLOCKED, NOT RUN.

| # | Case | Steps | Expected | Observed | Result | Screenshot | Sev |
|---|---|---|---|---|---|---|---|
| 1a | Bad URL | Typed `not a url ::` with a junk key, Connect | Clear validation message | Connect did not proceed; no message shown after tapping (see D6) | PARTIAL | c1-badurl.png | Low |
| 1b | Wrong key | Valid host, junk key | "Key not accepted" style error | The form stayed up with an error after the key was rejected (wording not recorded) | PASS | c1-wrongkey.png | |
| 1c | 403-only key | Needs a key with no permissions | Clear message | **BLOCKED**: no way to mint a key for a permissionless user over the REST API in this session (the user list has one, `/api/users/{id}/keys` is not exposed) | BLOCKED | | |
| 1d | nip.io hostname over plain HTTP | `http://<name>.nip.io`, stock Info.plist | Connects (maintainer's open question) | **Did not connect** with the shipped Info.plist (`NSAllowsLocalNetworking` only); connected after ATS was relaxed in a test copy. Consistent with ATS, but no log was captured to prove it; **re-check on a device with the log** | FAIL (inferred) | c1-wrongkey.png | **High** (D1) |
| 1e | Bare IP over plain HTTP | `http://10.130.34.240` | Connects under NSAllowsLocalNetworking | Not confirmed in the app. `curl` to the bare IP gets **404** from the dev server (it routes by Host name), so the bare IP cannot work against this instance regardless of ATS | BLOCKED | c1-bareip.png | |
| 1f | Connect, Adult key (hostname, ATS relaxed in a test copy) | | Tabs appear | Scan/Stock/Settings tabs | PASS | c1-connected.png | |
| 2a | Stock list | open Stock | All stock rows, quantity, next due | Rows with amount and due date, overdue date in red | PASS | c2-stock-list.png | |
| 2b | Search | typed `ui1` | list narrows | narrowed | PASS | c2-search.png | |
| 2c | Filter by **location** | filter menu | filter by location | The menu offers only All / Due soon / Overdue / Expired / Below minimum. **No location filter**, and no way to browse by location except via a scanned label | FAIL | c2-filter-menu.png | Medium (D2) |
| 2d | Low-stock | Below minimum filter | below-min item shown with "short" text | Shown with an orange "N short" caption; the plain list shows no indication | PASS (filter only) | c2-below-min.png | Low (D3) |
| 2e | Pull to refresh | swipe down | refresh | list refreshed, no error | PASS | c2-pull.png | |
| 2f | Empty state | no empty stock available on the shared instance | "Nothing in stock" | **NOT RUN** (shared instance never empty) | NOT RUN | | |
| 3a | Product detail | tap row | Name, stock, due, where, 3 buttons | Present | PASS | c3-product.png | |
| 3b | Use one + undo bar | Use one, then Undo | stock -1, undo bar, undo restores | Server 3→2 then back to 3; bar read "Consume recorded." | PASS (curl-verified) | c3-consume-undo.png, c3-after-undo.png | |
| 3c | Open one | Open one | opened amount +1 | Server `stock_amount_opened` 0→1 | PASS (curl-verified) | c3-open.png | |
| 3d | Purchase | More > Add to stock, amount 2 | stock +2 | Server 3→5 | PASS (curl-verified) | c3-purchase-done.png | |
| 3e | Transfer | More > Move, Pantry→Fridge | stock moves, success shown | **Server moved the stock (verified with curl) but the app showed an error "The server's response could not be read".** The booking is unconfirmed in the UI, so a user would retry and double-move | FAIL | c3-transfer-done.png | **High** (D4) |
| 3f | Inventory (correct the count) | set 4 | stock becomes 4 | Server 5→4 | PASS (curl-verified) | c3-inventory-done.png | |
| 3g | Validation error | Use some, amount 5 with 4 in stock | clean server message, no change | Server text shown, stock unchanged at 4 | PASS | c3-validation-error.png | |
| 3h | Unreachable server | wrong port `:9999` on the connection form | quick, clear error | Spinner ran ~60 s, then "Could not reach the server: The request timed out." No cancel while waiting | PARTIAL | c3-unreachable.png | Medium (D5) |
| 4a | Child key: write controls | connect with Child key, open product | disabled with an explanation, not hidden | Use one/Open one enabled (allowed). In More: Add to stock, Correct the count, Move are shown **greyed, with no explanation of why** | PARTIAL | c4-child-menu.png | Medium (D7) |
| 4b | Child key: forced write 403 | write the REST way with the Child key | clean 403 message | REST returns `403 Permission missing: STOCK_PURCHASE`. **The UI cannot be driven into a 403** because the controls are disabled; the app path from `forbidden` to a message was not exercised | BLOCKED (UI) | | |
| 5 | Scan tab (simulator) | open Scan | no camera: typed-code and photo paths offered | "No camera scanner here. Type a code, or pick a photo." with both buttons. Camera scanning, a typed code lookup and photo decode were **not exercised** | PARTIAL | c6-relaunch-after-failed.png | |
| 6a | Relaunch persistence | terminate and relaunch | stays connected | Reconnected without retyping (ad-hoc signed build only; unsigned build crashes, D8) | PASS | c6-relaunch-after-failed.png | |
| 6b | Disconnect | Connection > Disconnect | back to Connect form, key kept, fields prefilled | As described, key still masked in the form | PASS | c6-disconnected.png | |
| 6c | Forget this instance | Connection > Forget | key removed, form empty, survives relaunch | Empty form, empty after relaunch | PASS | c6-relaunch-after-forget.png | |
| 6d | Replace key on the Connect form | key field prefilled | clearing a masked key is possible | **No clear button, and pasting appends** to the old text; the old key could not be removed in the UI (I reset the simulator keychain to get on) | FAIL | | Low (D9) |
| 7a | Medications entry gated by `GET /api/consumption/capabilities` | connect to the real server | entry appears only with capabilities | Settings shows Medications and Refills; the real server advertises `manual_consume`, `mappings`, etc. | PASS | c6-settings.png | |
| 7b | Real server, nothing shared in Health | open Medications, Choose, Set up | explains there is nothing shared | Authorization list says "No matching medications saved in Health". The setup wizard then says **"Every medication you share is already settled"** when nothing is shared at all | FAIL | c7-setup-real.png | Medium (D10) |
| 7c | Demo server on, wizard, mapping editor, review list | Debug > Demo medication server | walk through | Demo switch works (needs a held tap, see D11). A simulator Health medication (Acetaminophen 500 mg, one logged dose) appears as "Needs mapping"; the editor offers its fields; saved as "Mapped"; Sync now raised a review item ("Health calls the unit this: count") that Approve resolved | PASS | c7-meds-shared.png, c7-mapping-editor.png, c7-sync-done.png | |
| 7d | Mapping editor detail | | labelled fields | The default-quantity field is an **unlabelled text field showing only the placeholder "None"**. The product picker is an unsearchable flat list; switching the location rule moves other rows (Organizer row disappears) | PARTIAL | c7-mapping-filled.png | Low (D12) |
| 8a | Dynamic Type, largest | AX-XXXL | usable | Stock list wraps names mid-word. **Product screen clips its content at the left edge**: labels "In stock/Due/Where" are cut and values overflow | FAIL | c8-dyntype-product.png, c8-dyntype-list.png | **High** (D13) |
| 8b | VoiceOver labels | | named controls | Not read from the accessibility tree (no tree tool in this session). Source review: only 6 `accessibilityLabel/Hint/Element` uses; most controls use `Label("..", systemImage:)`, which is named; icon-only buttons found have labels ("Dismiss", "More bookings") | NOT RUN | | |
| 8c | Dark mode | appearance dark | readable | Stock list fine | PASS | c8-dark-stock.png | |
| 8d | iPhone SE layout | no small-device runtime installed | | iOS 26.5/27.0 runtimes have no SE; one-simulator rule | BLOCKED | | |
| 8e | Floating tab bar overlap | scroll lists | last rows reachable | Tab bar floats over the bottom rows; "Save mapping" sits partly behind it | PARTIAL | c7-mapping-filled.png | Low (D14) |
| 9 | Rotation | portrait lock | portrait only | `UISupportedInterfaceOrientations` lists portrait only (plist); a rotation was **not driven** | PARTIAL (plist) | | |

Totals: **PASS 18, FAIL 6, PARTIAL 8, BLOCKED 3, NOT RUN 2.**
(Counts the rows above: 1b,1f,2a,2b,2d,2e,3a,3b,3c,3d,3f,3g,6a,6b,6c,7a,7c,8c are PASS; 1d,2c,3e,6d,7b,8a are FAIL.)

## The nip.io question

**Most likely no: the shipped Info.plist (`NSAllowsLocalNetworking` only) did not connect to
`http://<name>.nip.io`, and the same app connected once ATS was relaxed.** That fits Apple's documented behaviour:
`NSAllowsLocalNetworking` exempts local names (`.local`, unqualified hostnames) and IP addresses. A nip.io name is an
ordinary DNS name and needs HTTPS or an `NSExceptionDomains` entry.

**Caveat:** I changed signing and ATS at the same time and captured no log, so this is an inference, not a proof. The
bare IP could not be tested because the dev server answers 404 to a bare-IP Host (`curl`). So the IP does not work
against this instance. Re-check with `log stream` on a device.

## Defects

- **D1 (High, inferred): plain-HTTP nip.io hostnames did not connect with the shipped Info.plist.** Steps: Connect, URL `http://victual.<ip>.nip.io`, valid key. Observed: no connection and no useful message. Needs either an `NSExceptionDomains` decision or an in-app explanation that plain HTTP only works for local names/IPs.
- **D4 (High): a successful transfer is reported as an error.** Steps: Product > More > Move, Pantry→Fridge, 1 piece. Observed: the dialog says "The server's response could not be read" although the server moved the stock (curl-verified). Probably the decode of the `transfer` response (it returns two log entries, `transfer_from` and `transfer_to`). The user is invited to retry and double-book.
- **D13 (High): product screen unusable at accessibility Dynamic Type.** Steps: Settings > Display > Larger Text > AX-XXXL (or `simctl ui content_size accessibility-extra-extra-extra-large`), open any product. Observed: the panel is clipped on the left and the rows are cut.
- **D2 (Medium): no location filter on the Stock tab** (only status filters).
- **D5 (Medium): unreachable host spins ~60 s with no cancel.**
- **D7 (Medium): disabled controls for a restricted key have no explanation** (Child key: greyed menu rows, no text saying the key lacks permission).
- **D10 (Medium): "Every medication you share is already settled" appears when nothing is shared** (setup wizard, empty Health).
- **D8 (Medium, unconfirmed): with the unsigned build the first connect gave no feedback at all** (form stayed up, nothing shown). Cause not proven (see "Build deviation"); if it is the Keychain refusing the save, the `credentialStoreError` warning never surfaced because the form is replaced only on success.
- **D3 (Low): below-minimum is only visible inside the filter** (the main list shows nothing for a low item).
- **D6 (Low): connect form gives no validation message for a malformed URL; the Connect button just does not proceed** (and is disabled with empty fields).
- **D9 (Low): masked API key cannot be cleared or replaced on the Connect form after Disconnect** (no clear control; pasted text appends).
- **D11 (Low): the Debug demo switch needed a held tap in the simulator** (a quick tap did not toggle, maybe an automation artifact).
- **D12 (Low): unlabelled default-quantity field ("None" placeholder only) in the mapping editor, and an unsearchable product list.**
- **D14 (Low): the floating tab bar overlaps the last row and the Save button on long forms.**
- **Side effect:** iOS offers "Save Password?" for the API key field after connect. Probably acceptable (it lets a password manager hold the key) but worth a decision.

## NOT RUN (device-only, never claimed)

Real HealthKit authorization sheet on a device. Real dose payloads from the Medications app on a device. Background
delivery (`HKObserverQuery`/background wake), local and critical notifications, the live camera scanner, a real
iPhone's Keychain, an actual 403 reached through the UI, an empty-stock state, VoiceOver spoken output, iPhone SE
layout, physical rotation. The Medications evidence above is **simulator Health** (Medications and a logged dose
were created in the simulator's Health app), through the **demo** server, so it shows the UI and the HealthKit read
path in the simulator only.

- DEVICE: does iOS offer to save the API key as a password when connecting, and does VoiceOver announce the field as a secure field? NOT RUN.

## Test data left on the dev instance

`ui1-Pantry`, `ui1-Fridge`, `ui1-Rice`, `ui1-Milk`, `ui1-Pasta` (below its minimum of 10), `ui1-Eggs`, and a user
`ui1-noperm` with no permissions. Stock levels were changed by the Adult-key tests.

## Reproducing

```
Scripts/seed-ui-fixtures.sh   # VICTUAL_URL and VICTUAL_ADMIN_KEY from the environment
cd Apps/VictualPhone && xcodegen generate
xcodebuild -project VictualPhone.xcodeproj -scheme VictualPhone -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGN_IDENTITY=- build
```
