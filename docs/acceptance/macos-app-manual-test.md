# Victual for macOS: manual test guide

A hand-driven acceptance test for the macOS application in `Apps/Victual`. It covers plan 01's
verification item 5 and the checks a unit test cannot make: windows, menus, the Keychain and
what a person sees. Every step names a control that exists in the code. Every step has an
exact expected result.

The macOS application does not link `VictualHealth`. Nothing here touches HealthKit or
scanning.

## How to read this guide

**Where the expected results come from.** The author did not run the application. The
expected results come from reading `Apps/Victual/Sources`, `Sources/VictualStock`,
`Sources/VictualUI` and `Sources/VictualCore`. Server-side commands were run against a
disposable Victual 0.4.0 instance, and the numbers in them come from that run. A result you
observe that differs from an expected result is a finding. Write it in the Notes column.

**Case layout.** Each case has a purpose, what it needs, numbered steps, the expected result,
a server check and a result line. Case IDs use a letter for the area: C connection, L stock
list, P product detail, B bookings, E errors, K limited keys, W windows and menus.

**Server check.** A server check is a command you run in a terminal. It uses the helper
functions defined in [Server helpers](#server-helpers). "None" means the case has no
server-side effect.

**Reset.** Many cases change stock. Run `Scripts/seed-dev-household.py` again where a case
says **Reset**. The script restores the baseline.

## Read this first: plain HTTP is probably blocked

The development instance is served over plain HTTP at a `nip.io` name. The application's
generated `Info.plist` has no `NSAppTransportSecurity` key. The iPhone application sets
`NSAllowsLocalNetworking`, and the Mac application sets nothing.

App Transport Security refuses plain HTTP to a fully qualified host name unless an exception
exists. The exception for local networking covers IP addresses, unqualified names and `.local`
names. It would not cover a `nip.io` name even if the Mac application had it.

Case C4 records what happens on the unmodified build. If the connection is refused, apply the
local change in C4 before you run C5 and every case after it. The change is not committed.

## Prerequisites

You need:

- macOS 14 or later, and Xcode.
- `xcodegen`, `jq` and `python3`: `brew install xcodegen jq`.
- Network access to the dev instance.
- Three keys: an Adult key, a Child key, and an administrator key for seeding and for the
  server checks. The Adult key lacks `MASTER_DATA_EDIT`. The Child key holds only
  `STOCK_VIEW`, `STOCK_CONSUME` and `STOCK_OPEN` among the stock permissions.

Never paste a key into a file in the repository, a commit message or a pull request.

## Build and run

From the repository root:

```bash
cd Apps/Victual
xcodegen generate
open Victual.xcodeproj
```

1. In Xcode, pick the **Victual** scheme and **My Mac**. Press Cmd-R.
2. Without `Apps/Local.xcconfig` the build is ad hoc signed. With it, `DEVELOPMENT_TEAM` is
   set and Xcode may sign with your team. Both are valid. Record which one you used.
3. Press Cmd-U. The scheme's Test action runs the package's five test targets. Expected: the
   run finishes with no failures. Record the total in the results sheet.
4. Choose **Victual › About Victual**. Expected: Version 0.4.0, build 1. An older build in
   DerivedData reports `0.1.0-MVP`. If you see that, you launched the wrong product.

To record the signature, choose **Product › Show Build Folder in Finder**, open
`Products/Debug`, and run this with the path of `Victual.app`:

```bash
codesign -dv --verbose=2 /path/to/Victual.app 2>&1 | grep -E 'Signature|TeamIdentifier'
```

Expected for an ad hoc build: `Signature=adhoc` and `TeamIdentifier=not set`. A team build
shows your Team ID. Plan 01 lists the Keychain against a signed bundle as untested, so this
value matters.

## Seed the instance

The seed script reads the instance address and an administrator key from the environment.
It writes only locations, products and stock whose names start with `mac-`.

```bash
export VICTUAL_DEV_URL=http://your-instance.example   # no trailing slash
export VICTUAL_DEV_KEY=your-admin-key                 # type it in your shell; do not save it
export VICTUAL_CHILD_KEY=your-child-key               # used only by cases E3 and K1
Scripts/seed-dev-household.py --dry-run
Scripts/seed-dev-household.py
```

Expected: the second command ends with `Done: N write(s).` A second run ends with
`Done: 0 write(s).` and prints `ok` for every product.

### Baseline data

The instance also holds junk from earlier runs: locations and products named `rp…`, `ui1-…`
and others. The sidebar lists every location, and "All stock" lists every product. Type
`mac-` in the search field to see only the seed data.

Dates below are offsets from the day the script ran. The app prints them as, for example,
`Oct 13, 2026`.

| Product | Unit | Lots: amount, due, price, location | Role in the tests |
| --- | --- | --- | --- |
| mac-Milk | Pack | 1, +2 days, 1.50, Fridge; 2, +9, 1.60, Fridge; 1, +20, no price, Pantry | Several lots, two locations, minimum 3, due soon |
| mac-Eggs | Piece | 12, +14, 0.30, Fridge | Partial consume, inventory |
| mac-Rice | Pack | 5, +300, 3.20, Pantry | Purchase |
| mac-Flour | Pack | 2.5, +120, 1.10, Pantry Shelf | Fractions, open |
| mac-Yoghurt | Piece | 4, −3, 0.80, Fridge | Overdue |
| mac-Cream | Piece | 2, −5, 1.20, Fridge, due type "expires" | Expired |
| mac-Butter | Pack | 3, +40, 2.40, Fridge | Transfer |
| mac-Peas | Pack | 6, +200, 1.75, Freezer | Freezer contents |
| mac-Salt | Pack | none; minimum 2 | Below minimum, no stock |
| mac-Pasta | Pack | none; parent of the next two | Sub-products |
| mac-Pasta Penne | Pack | 2, +200, 1.30, Pantry | Child of Pasta |
| mac-Pasta Spaghetti | Pack | 3, +220, 1.20, Pantry | Child of Pasta |
| mac-Long name check… | Piece | 1, +60, no price, Pantry | Truncation, unpriced stock |

The locations are `mac-Pantry` with a child `mac-Pantry Shelf`, `mac-Fridge`, `mac-Freezer`
(a freezer) and `mac-Garage` (always empty).

### Server helpers

Paste these into the terminal you use for server checks, after the two `export` lines above.
They need `jq`.

```bash
vget() { curl -sS "$VICTUAL_DEV_URL/api$1" -H "VICTUAL-API-KEY: $VICTUAL_DEV_KEY"; }
vsend() { curl -sS -X "$1" "$VICTUAL_DEV_URL/api$2" -H "VICTUAL-API-KEY: $VICTUAL_DEV_KEY" -H 'Content-Type: application/json' -d "${3:-{\}}"; }
pid() { vget /objects/products | jq -r --arg n "$1" '.[] | select(.name == $n) | .id'; }
lid() { vget /objects/locations | jq -r --arg n "$1" '.[] | select(.name == $n) | .id'; }
lots() {
  local L; L=$(vget /objects/locations)
  vget "/stock/products/$(pid "$1")/entries" | jq -c --argjson L "$L" \
    '[.[] | .location_id as $i | {amount, due: .best_before_date, open, price, at: ($L[] | select(.id == $i) | .name)}] | sort_by(.due, .amount)'
}
stock1() { vget /stock | jq -c --arg n "$1" '.[] | select(.product.name == $n) | {amount, opened: .amount_opened, value, due: .best_before_date}'; }
slog() { vget "/objects/stock_log?order=id:desc&limit=${1:-4}" | jq -c '.[] | {id, product_id, amount, type: .transaction_type, spoiled, undone, tx: .transaction_id}'; }
buckets() {
  vget /stock/volatile | jq -c '{due: [.due_products[].product.name], overdue: [.overdue_products[].product.name], expired: [.expired_products[].product.name], below_minimum: [.missing_products[].name]} | map_values(map(select(startswith("mac-"))))'
}
```

Quick check of the helpers. Expected: `stock1 mac-Milk` prints
`{"amount":4,"opened":0,"value":4.7,"due":"<seed day + 2>"}`.

## Part C: connection

The connection form is `VictualConnectionView`. Its fields are the address field (placeholder
`victual.example.com`), an **API key** secure field and a **Connect** button. Connect stays
disabled while the address or the key is empty.

Cases C1 to C4 need a fresh state: no remembered instance. On a first run that holds. Later,
use **Forget this instance** from case C9.

### C1. Address that is not a web address

**Purpose.** The form rejects text that is not an http or https URL, without a network call.

**Needs.** The connection form showing, empty.

**Steps.**

1. Type `ftp://pantry.local` in the address field.
2. Type `x` in the API key field.
3. Click **Connect**.
4. Clear the key field and look at the button.

**Expected.**

- After step 3 a red line with a warning triangle reads `"ftp://pantry.local" is not a valid Victual address.`
- The form stays. **Connect** is enabled again.
- After step 4 **Connect** is disabled.

**Server check.** None.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### C2. Address that refuses connections

**Purpose.** A well-formed address with nothing listening reports a transport failure.

**Needs.** The form showing.

**Steps.**

1. Type `http://127.0.0.1:9` in the address field and `x` in the key field.
2. Click **Connect**.

**Expected.**

- The button shows a spinner while it works.
- A red line reads `Could not reach the server: Could not connect to the server.`
- If the text mentions App Transport Security instead, record it. That would mean ATS also
  covers IP addresses on this build.

**Server check.** Nothing listens on port 9, so the command fails:

```bash
curl -sS -m 3 http://127.0.0.1:9/ ; echo "curl exit $?"
```

Expected: `curl: (7) Failed to connect` and `curl exit 7`.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### C3. Bare host name is promoted to HTTPS

**Purpose.** An address without a scheme is read as `https://`. A plain-HTTP instance then
fails, and the message says so.

**Needs.** The form showing. The host name of the dev instance, without `http://`.

**Steps.**

1. Type the bare host name of the dev instance, for example `your-instance.example`.
2. Type the Adult key. Click **Connect**.

**Expected.**

- A red line starting `Could not reach the server:`. The rest describes a certificate
  problem, or a refused secure connection. The exact words come from the system.
- The window does not connect.

**Server check.** The instance has no valid certificate for this name:

```bash
curl -sS -m 10 -o /dev/null "https://${VICTUAL_DEV_URL#http://}/api/system/info"; echo "curl exit $?"
```

Expected: a certificate error and `curl exit 60`.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### C4. Plain HTTP instance on the unmodified build

**Purpose.** Find out whether App Transport Security blocks the dev instance. This decides
how the rest of the guide runs.

**Needs.** The form showing. The build from [Build and run](#build-and-run), unmodified.

**Steps.**

1. Type the full address with scheme, for example `http://your-instance.example`.
2. Type the Adult key. Click **Connect**.

**Expected, most likely.**

- A red line: `Could not reach the server: The resource could not be loaded because the App
  Transport Security policy requires the use of a secure connection.`
- The window does not connect.

**Expected, if ATS does not apply.** The window connects. Record that, skip the local change
below, and continue with C5.

**Local change (not committed).** Quit the app. In `Apps/Victual/project.yml`, under
`info: properties:`, add:

```yaml
        NSAppTransportSecurity:
          NSExceptionDomains:
            nip.io:
              NSIncludesSubdomains: true
              NSExceptionAllowsInsecureHTTPLoads: true
```

Run `xcodegen generate` in `Apps/Victual`, then rebuild and run. Use another domain in place
of `nip.io` if your instance has a different name. When all testing ends, run
`git checkout Apps/Victual/project.yml`. The Mac application has no such exception, so the
shipped build cannot reach a plain-HTTP dev instance. Report it.

**Server check.** The instance itself is healthy:

```bash
vget /system/info | jq -c '.victual_version'
```

Expected: `{"Version":"0.4.0","ReleaseDate":"2026-10-10"}`.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### C5. Wrong key

**Purpose.** A key the server does not know produces the unauthorized message.

**Needs.** ATS resolved (C4). The form showing.

**Steps.**

1. Type the instance address. Type `not-a-real-key` as the key.
2. Click **Connect**.

**Expected.** A red line reads `The API key was not accepted.` The form stays.

**Server check.**

```bash
curl -sS -o /dev/null -w '%{http_code}\n' "$VICTUAL_DEV_URL/api/system/info" -H 'VICTUAL-API-KEY: not-a-real-key'
```

Expected: `401`.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### C6. Successful connection

**Purpose.** A good key connects, shows stock and reports the server.

**Needs.** The form showing.

**Steps.**

1. Type the instance address and the Adult key. Click **Connect**.
2. Watch the window. Type `mac-` in the search field.
3. Press Cmd-, to open the settings window.

**Expected.**

- The window changes to three columns. The sidebar has a **Stock** section with **All stock**,
  **Due soon**, **Overdue**, **Expired** and **Below minimum**, each with a count badge.
  A **Locations** section follows.
- The table title is **All stock**. The subtitle reads `Refreshing…`, then `N products`.
  After step 2 it reads `12 products`.
- There is no orange banner above the table. Neither a newer-server warning nor the line
  `This key was not saved, and will have to be entered again next launch.` appears.
- The settings window has a **Connected** section: **Victual** `0.4.0` and **Database**
  the engine name (`PostgreSQL 16.15` on the dev instance), then **Disconnect** and **Forget this instance** buttons.
- The footer under them reads `Disconnecting keeps the API key in the Keychain. Forgetting
  removes it.`

**Server check.** The **All stock** badge equals the number of products in stock:

```bash
vget /stock | jq length
```

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### C7. Remembered instance after relaunch

**Purpose.** The address and key survive a quit. This is plan 01's Keychain check.

**Needs.** C6 done and the app connected.

**Steps.**

1. Press Cmd-Q.
2. Launch the app again.
3. If macOS asks whether Victual may use confidential information in your keychain, record
   the wording and click **Always Allow**.

**Expected.**

- The window opens already showing stock, with no form. The subtitle goes from `Refreshing…`
  to `N products`.
- Search text and selection are not restored.
- An ad hoc build asks the Keychain question once per new build. A build that was already
  allowed does not ask.

**Server check.** These local commands check the stored key and the remembered address. They
do not print the key:

```bash
security find-generic-password -s dev.victual.Victual.api-key >/dev/null 2>&1 && echo present || echo absent
plutil -p ~/Library/Containers/dev.victual.Victual/Data/Library/Preferences/dev.victual.Victual.plist | grep last-server
```

Expected: `present`, and one line naming `dev.victual.victual-kit.last-server`. The preference
file can lag behind the running app. If the second command prints nothing, quit and run it
again.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### C8. Disconnect keeps the key

**Purpose.** Disconnect returns to the form but leaves the stored key and address.

**Needs.** Connected. Two windows open (Cmd-N) makes the check stronger.

**Steps.**

1. Press Cmd-, and click **Disconnect**.
2. Look at every window.
3. Click **Connect** in one window.
4. Click **Disconnect** again. Quit with Cmd-Q and relaunch.

**Expected.**

- After step 1 every main window shows the form. The address and the key are still filled in,
  and **Connect** is enabled. The **Connected** section is gone from the settings window.
- After step 3 the window shows stock again with no retyping.
- After step 4 the relaunched app connects by itself. The key was kept.

**Server check.** The stored key is still there after the disconnect:

```bash
security find-generic-password -s dev.victual.Victual.api-key >/dev/null 2>&1 && echo present || echo absent
```

Expected: `present`.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### C9. Forget this instance removes the key

**Purpose.** Forget deletes the stored key and the remembered address.

**Needs.** Connected.

**Steps.**

1. Press Cmd-, and click **Forget this instance**.
2. Look at the main window.
3. Quit with Cmd-Q and relaunch.

**Expected.**

- After step 1 the main window shows the form. The address field still shows the address. The
  key field is empty. **Connect** is disabled.
- After step 3 the form shows with both fields empty. The app does not connect by itself.

**Server check.**

```bash
security find-generic-password -s dev.victual.Victual.api-key >/dev/null 2>&1 && echo present || echo absent
```

Expected: `absent`. Then connect again with the Adult key for the next part.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### C10. Key without STOCK_VIEW (optional)

**Purpose.** Check the failure when the key connects but may not read stock.

**Needs.** A key you create in the instance's web interface for a user with no roles. No such
key is supplied with this guide. Skip the case if you have none.

**Steps.** Connect with that key.

**Expected, from the code.** Connection succeeds, because `GET /system/info` needs no stock
permission. The table is empty. The subtitle reads `This API key does not have permission
for that.` The empty state reads **Nothing here** with the same sentence.

**Server check.** None.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  [ ] Skipped  Notes:

## Part L: the stock list

Connect with the Adult key and type `mac-` in the search field. Run the seed script first so
the data is at the baseline.

### L1. First load, columns and values

**Purpose.** The table shows the right products, amounts with units, due dates and values.

**Needs.** Connected as the Adult key. Search `mac-`. Sidebar on **All stock**.

**Steps.** Read the table.

**Expected.**

- The title is **All stock** and the subtitle is `12 products`.
- The columns are **Product**, **Amount**, **Due** and **Value**. The rows run by name, each
  with this amount and value:

| Product | Amount | Value |
| --- | --- | --- |
| mac-Butter | 3 Packs | 7.20 |
| mac-Cream | 2 Pieces | 2.40 |
| mac-Eggs | 12 Pieces | 3.60 |
| mac-Flour | 2.5 Packs | 2.75 |
| mac-Long name check… | 1 Piece | 0.00 |
| mac-Milk | 4 Packs | 4.70 |
| mac-Pasta | 0 Packs | 0.00 |
| mac-Pasta Penne | 2 Packs | 2.60 |
| mac-Pasta Spaghetti | 3 Packs | 3.60 |
| mac-Peas | 6 Packs | 10.50 |
| mac-Rice | 5 Packs | 16.00 |
| mac-Yoghurt | 4 Pieces | 3.20 |

- The long name is cut off with an ellipsis. It does not wrap.
- No row shows a drop icon, because nothing is opened.
- `mac-Pasta` shows `0 Packs` although its sub-products hold 5. See the observations at the
  end.
- `mac-Long name check…` and `mac-Pasta` show `0.00`, not a dash. The server sends 0 for
  stock without a price.

**Server check.**

```bash
vget /stock | jq -c '.[] | select(.product.name | startswith("mac-")) | {n: .product.name, amount, value, due: .best_before_date}'
```

Expected: 12 lines matching the table.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### L2. Sorting

**Purpose.** Each column header sorts, in both directions, with ties broken by name.

**Needs.** L1 state.

**Steps.** Click each header once, then again: **Product**, **Amount**, **Due**, **Value**.
A first click on a different column sorts ascending. A second click reverses it.

**Expected.** Order of the 12 products, using short names:

| Sort | Order |
| --- | --- |
| Product ascending | Butter, Cream, Eggs, Flour, Long name, Milk, Pasta, Pasta Penne, Pasta Spaghetti, Peas, Rice, Yoghurt |
| Product descending | The reverse of that list |
| Amount ascending | Pasta, Long name, Cream, Pasta Penne, Flour, Butter, Pasta Spaghetti, Milk, Yoghurt, Rice, Peas, Eggs |
| Amount descending | Eggs, Peas, Rice, Milk, Yoghurt, Butter, Pasta Spaghetti, Flour, Cream, Pasta Penne, Long name, Pasta |
| Due ascending | Cream, Yoghurt, Milk, Eggs, Butter, Long name, Flour, Pasta, Pasta Penne, Peas, Pasta Spaghetti, Rice |
| Due descending | Rice, Pasta Spaghetti, Pasta, Pasta Penne, Peas, Flour, Long name, Butter, Eggs, Milk, Yoghurt, Cream |
| Value ascending | Long name, Pasta, Cream, Pasta Penne, Flour, Yoghurt, Eggs, Pasta Spaghetti, Milk, Butter, Peas, Rice |
| Value descending | Rice, Peas, Butter, Milk, Eggs, Pasta Spaghetti, Yoghurt, Flour, Pasta Penne, Cream, Long name, Pasta |

Equal values keep name order in both directions. For example, Milk and Yoghurt both hold 4
and always list Milk first.

**Server check.** None. The sort happens in the app.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### L3. Search

**Purpose.** The search field filters by product name only.

**Needs.** L1 state, **All stock**.

**Steps.** Replace the text in the search field in turn with: `milk`, `MILK`, `mac-pas`,
`fridge`, `zzz`. Then clear the field with its clear button.

**Expected.**

- `milk` and `MILK` both leave `mac-Milk`. The subtitle reads `1 product`.
- `mac-pas` leaves Pasta, Pasta Penne and Pasta Spaghetti: `3 products`.
- `fridge` and `zzz` leave an empty table. The overlay reads **Nothing here** and
  `No product matches "fridge".` or `No product matches "zzz".`
- Clearing the field restores the full list. Switching the sidebar entry keeps the search text.
- Pressing Cmd-F: record whether it focuses the field. The code does not bind it.

**Server check.** None.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### L4. Status buckets

**Purpose.** The four attention entries show the products the server puts in them.

**Needs.** Baseline data. Search `mac-`.

**Steps.** Click **Due soon**, **Overdue**, **Expired**, then **Below minimum**. Note the
badge counts. Do not search for anything else.

**Expected.**

| Entry | Rows | Notes |
| --- | --- | --- |
| Due soon | mac-Milk | 4 Packs, 4.70. The window is the server default of 5 days. |
| Overdue | mac-Cream, mac-Yoghurt | Both due dates in red |
| Expired | mac-Cream | Cream is in Overdue and in Expired |
| Below minimum | mac-Salt | `0`, then `(2 short)`, due `—`, value `—`. No unit: Salt has no stock row. |

- The subtitle counts the rows after the search filter, for example `2 products`.
- The badge counts include the junk products from earlier runs, so they are larger than the
  table counts.
- With a search that matches nothing, the empty state reads `No product matches "…".`
  The empty-bucket messages, such as `Nothing is overdue.`, need a bucket with no rows at all.
  The junk data keeps every bucket full, so this instance cannot show them.

**Server check.**

```bash
buckets
```

Expected: `{"due":["mac-Milk"],"overdue":["mac-Yoghurt","mac-Cream"],"expired":["mac-Cream"],"below_minimum":["mac-Salt"]}`.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### L5. Locations

**Purpose.** A location shows what is stored there, which can differ from a product's default
location.

**Needs.** Baseline data. Search `mac-`.

**Steps.** In the sidebar, scroll to the **Locations** section. Entries named `rp…` and
`ui1-…` are junk. Click each `mac-` location in turn. Open the disclosure triangle on
`mac-Pantry`.

**Expected.**

- `mac-Pantry` has a triangle. Its child `mac-Pantry Shelf` appears inside it.
- Each click changes the table title to the location's path. The child's title is
  `mac-Pantry / mac-Pantry Shelf`.

| Location | Rows |
| --- | --- |
| mac-Fridge | `5 products`: Butter 3 Packs 7.20, Cream 2 Pieces 2.40, Eggs 12 Pieces 3.60, Milk 3 Packs 4.70, Yoghurt 4 Pieces 3.20 |
| mac-Pantry | `5 products`: Long name 1 Piece `—`, Milk 1 Pack `—`, Pasta Penne 2 Packs 2.60, Pasta Spaghetti 3 Packs 3.60, Rice 5 Packs 16.00 |
| mac-Pantry Shelf | `1 product`: Flour 2.5 Packs 2.75 |
| mac-Freezer | `1 product`: Peas 6 Packs 10.50 |
| mac-Garage | Empty: **Nothing here**, `Nothing is stored in mac-Garage.` |

- In `mac-Pantry` the Milk row shows 1 Pack, the Pantry lot only. In All stock it shows 4.
- The two `—` values mean "a lot here has no price". They differ from the `0.00` in L1.
- `mac-Pantry` does not list Flour: a parent location does not include its children.

**Server check.**

```bash
vget /stock/locations/$(lid mac-Pantry)/entries | jq -c '[.[] | {product_id, amount, price}]'
```

Expected: five entries, two with `"price":null`.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### L6. Amounts, units and the opened marker

**Purpose.** Amounts use the singular or plural unit name, fractions print, and opened stock
is marked.

**Needs.** Baseline data.

**Steps.**

1. Read the Amount column for Eggs, Milk, Long name, Flour.
2. Select `mac-Flour`. Choose **Book › Mark opened**. Leave the amount at 1. Click **Mark opened**.
3. Hover the new drop icon in the Amount column.
4. Click **Undo** in the bar at the bottom.

**Expected.**

- Eggs `12 Pieces`, Milk `4 Packs`, Long name `1 Piece`, Flour `2.5 Packs`. One of a unit is
  singular. Every other amount is plural.
- After step 2 the Flour row reads `2.5 Packs` followed by a drop icon. The tooltip reads
  `1 Pack already opened`.
- After step 4 the icon is gone.

**Server check.** After step 2, before undo:

```bash
stock1 mac-Flour
```

Expected: `{"amount":2.5,"opened":1,"value":2.75,"due":…}`. After undo, `opened` is 0.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### L7. Due-date colours

**Purpose.** Past due dates are red, and later dates are not.

**Needs.** Baseline data. Sort by **Due**.

**Steps.** Look at the Due column.

**Expected.**

- Cream and Yoghurt dates are red. Every later date is in the normal text colour.
- No row shows `—` in Due on the baseline data. A row with no date would, but the seed has none.
- A lot due today also renders red, because its date is midnight. The seed has none. See the
  observations.

**Server check.** None.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### L8. Refresh button

**Purpose.** Refresh re-reads the list and the open product.

**Needs.** Baseline data. `mac-Eggs` selected.

**Steps.**

1. Change Eggs from a terminal: `vsend POST /stock/products/$(pid mac-Eggs)/consume '{"amount":1,"transaction_type":"consume"}' | jq -c '.[0].transaction_id'`
2. At once, click **Refresh** in the toolbar.

**Expected.**

- The subtitle reads `Refreshing…` and the button is disabled while it loads.
- The Eggs row reads `11 Pieces`. The inspector's **In stock** reads `11 Pieces`.

**Server check.**

```bash
stock1 mac-Eggs
```

Expected: `"amount":11`. **Reset.**

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### L9. Change poller picks up an outside edit

**Purpose.** Without a click, the window follows a change made elsewhere. The poller checks
every 30 seconds.

**Needs.** Baseline data. The window has been open for at least 10 seconds, so the poller has
its baseline. `mac-Eggs` selected.

**Steps.**

1. Run the consume command from L8 in a terminal.
2. Do not touch the app. Wait up to 40 seconds.

**Expected.**

- Within about 35 seconds the Eggs row changes to `11 Pieces` and the inspector follows.
- No spinner or banner appears.

**Server check.** The server's change time moved:

```bash
vget /system/db-changed-time | jq -r .changed_time
```

Run it before and after step 1. Expected: the second value is later. **Reset.** If another
person or session writes to the same instance, the list may refresh on its own at other
times. Note it.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

## Part P: product detail

### P1. Inspector for a product with several lots

**Purpose.** The inspector summarizes one product and lists its lots, soonest due first.

**Needs.** Adult key. Baseline data.

**Steps.** Before selecting anything, read the right column. Then click `mac-Milk`.

**Expected.**

- Before selecting: **No product selected**, and `Pick a row to see what it is made of.`
- After: the title `mac-Milk` and the line `Whole, one litre.`
- Rows: **In stock** `4 Packs`, **Measured** `0 Packs`, **Minimum** `3 Packs`, **Next due**
  the +2 day date, **Location** `mac-Fridge`, **Average shelf life** about `10 days`,
  **Last price** `1.60`, **Average price** `1.57`, **Stock value** `4.70`. **Opened** does not
  appear.
- **Stock entries** lists three lots in due order: `1 Pack` with the +2 day date,
  `mac-Fridge` and `1.50`; `2 Packs` +9 days, `mac-Fridge`, `1.60`; `1 Pack` +20 days,
  `mac-Pantry` and `—`.
- The **Measured** row appears for every product, because the server sends 0. See the
  observations.

**Server check.**

```bash
vget /stock/products/$(pid mac-Milk) | jq -c '{stock_amount, stock_value, last_price, avg_price, next_due_date, location: .location.name}'
lots mac-Milk
```

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### P2. Parent product and sub-products

**Purpose.** The "Include sub-products" checkbox adds the children's lots.

**Needs.** Baseline data.

**Steps.**

1. Select `mac-Pasta`.
2. Tick **Include sub-products** at the right of the **Stock entries** heading.
3. Untick it.

**Expected.**

- **In stock** reads `0 Packs`. **Next due** reads `—`. **Average shelf life** is absent.
- Step 1 shows the checkbox and **Nothing in stock.**
- Step 2 lists `2 Packs` (+200 days) and `3 Packs` (+220 days), both `mac-Pantry`.
- Step 3 returns to **Nothing in stock.**
- A product without children, such as `mac-Milk`, has no checkbox.

**Server check.**

```bash
vget "/stock/products/$(pid mac-Pasta)/entries?include_sub_products=true" | jq -c '[.[] | {product_id, amount}]'
```

Expected: two entries, amounts 2 and 3.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### P3. Product with no stock

**Purpose.** A product with nothing on hand can still be opened and booked against.

**Needs.** Baseline data.

**Steps.** Click **Below minimum**, then click `mac-Salt`.

**Expected.**

- The inspector loads. **In stock** reads `0 Packs` and **Minimum** reads `2 Packs`.
  **Next due** reads `—`. **Stock entries** shows **Nothing in stock.**
- **Last price** reads `0.00`, **Average price** reads `—` and **Stock value** reads `0.00`.
  This follows the server's answer in the check below. It is another case of zero where a
  dash would be truer. See the observations.
- All five **Book** items are enabled for the Adult key.

**Server check.**

```bash
vget /stock/products/$(pid mac-Salt) | jq -c '{stock_amount, last_price, avg_price, stock_value}'
```

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### P4. Long name and layout

**Purpose.** A long name does not break the table or the inspector.

**Needs.** Baseline data.

**Steps.** Select `mac-Long name check…`. Drag the divider between the table and inspector.

**Expected.**

- The table cell shows one line with an ellipsis.
- The inspector title shows the whole name, wrapped over lines. Nothing is clipped.
- Columns have minimum widths: the table keeps 460 points, the inspector 280.

**Server check.** None.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

## Part B: bookings

The five bookings are in the **Book** pull-down at the right of the toolbar. Its items are
**Consume**, **Add to stock**, **Mark opened**, **Correct inventory** and **Transfer**. Each
opens a sheet 440 points wide. The sheet's footer shows the product name, **Cancel** and the
action button. Return presses the action button. Esc cancels.

After a booking the sheet closes. A bar appears at the bottom of the window: a green check,
`<Action> recorded.`, an **Undo** button and a **Dismiss** button. The action word is the
menu item's name, for example `Consume recorded.`

### B1. Booking menu gating

**Purpose.** The commands are visible but disabled until they can work.

**Needs.** Adult key. Nothing selected in the table.

**Steps.**

1. Open **Book**. Hover each item for about a second.
2. Click `mac-Eggs`. Open **Book** again.

**Expected.**

- Step 1: all five items are disabled. The tooltip reads `Select a product first.`
- Step 2: all five items are enabled. The tooltip on each is its own name.
- If a tooltip does not show on a menu item, record it. The plan promises a reason on every
  disabled command.

**Server check.** None.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### B2. Consume part of a lot, then undo

**Purpose.** A partial consume lowers the amount. Undo returns it.

**Needs.** Adult key. Baseline data. `mac-Eggs` selected.

**Steps.**

1. Choose **Book › Consume**.
2. Read the sheet. Set **Amount** to 5. Click **Consume**.
3. Click **Undo** in the bar.

**Expected.**

- The sheet shows **Amount** `1` with a stepper and the unit `Piece`. After you type 5 the
  unit reads `Pieces`. It also shows the toggle **Thrown away rather than used**, a
  **Location** pop-up on `Anywhere`, and a **Container** pop-up on `Whichever is due first`.
- After step 2: the bar reads `Consume recorded.` Eggs reads `7 Pieces`. The inspector shows
  `7 Pieces` and one lot. The Value reads `2.10`.
- After step 3: the bar disappears. Eggs reads `12 Pieces`. The inspector lists two lots,
  `7 Pieces` and `5 Pieces`, with the same due date. The server splits the lot on undo.

**Server check.** After step 2:

```bash
stock1 mac-Eggs; slog 1
```

Expected: `"amount":7`; one log row of `-5`, type `consume`, `undone` 0. After step 3 run
`lots mac-Eggs`: two entries of 7 and 5; `slog 2` shows the consume row with `undone` 1. **Reset.**

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### B3. Consume across lots, below minimum, undo

**Purpose.** A consume that spans lots takes the soonest due first. A drop under the minimum
moves the product between buckets.

**Needs.** Adult key. Baseline data. Note the badge counts of **Due soon** and **Below minimum**.

**Steps.**

1. Select `mac-Milk`. Choose **Book › Consume**. Set **Amount** to 2. Click **Consume**.
2. Look at the inspector and the sidebar badges. Click **Below minimum**.
3. Click **Undo**.

**Expected.**

- After step 1: Milk reads `2 Packs`. The inspector lists `1 Pack` (+9 days, Fridge) and
  `1 Pack` (+20 days, Pantry). **Next due** moves to the +9 day date. Value reads `1.60`.
- After step 2: **Due soon** is one lower and **Below minimum** one higher. Milk is in
  **Below minimum** and reads `0 Packs` then `(1 Pack short)`. Milk has stock, so its unit
  is known.
- After step 3: Milk reads `4 Packs`. The inspector lists four lots of `1 Pack`: the +2 day
  one, two on the +9 day date, and the +20 day one. Both buckets return to their old counts.

**Server check.** After step 1:

```bash
buckets; lots mac-Milk
```

Expected: `"due":[]` and `"below_minimum":["mac-Salt","mac-Milk"]` (order may differ). After
undo: Milk is back in `"due"`. **Reset.**

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### B4. Consume one named container

**Purpose.** Naming a lot forces an amount of 1, and the form blocks other amounts.

**Needs.** Adult key. Baseline data. `mac-Milk` selected.

**Steps.**

1. Choose **Book › Consume**. Open the **Container** pop-up.
2. Pick the lot that is `1 Pack` and due +20 days.
3. Type 2 in **Amount**. Look at the button. Type 1 again.
4. Click **Consume**.

**Expected.**

- The pop-up lists `Whichever is due first`, then three lots in due order: `1 Pack, due <date>`,
  `2 Packs, due <date>` and `1 Pack, due <date>`.
- After step 2: the text `A named container is booked one at a time.` appears. **Amount**
  becomes 1.
- After step 3 with 2: **Consume** is disabled. With 1 it is enabled again.
- After step 4: Milk reads `3 Packs`. The +20 day Pantry lot is gone. Next due stays at +2 days.
  Undo returns the lot.

**Server check.**

```bash
lots mac-Milk
```

Expected after step 4: two entries, both at `mac-Fridge`. **Reset.**

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### B5. Consume from one location, marked as thrown away

**Purpose.** The Location filter limits the lots considered. The toggle records spoilage.

**Needs.** Adult key. Baseline data. `mac-Milk` selected.

**Steps.**

1. Choose **Book › Consume**.
2. Turn on **Thrown away rather than used**.
3. In **Location**, choose `mac-Pantry`. The list is long. Click the pop-up and type `mac-Pa`
   to jump.
4. Leave **Amount** at 1. Click **Consume**.

**Expected.**

- Milk reads `3 Packs`. The Pantry lot, the only Milk there, is consumed. The Fridge lots stay.
- The log row is marked spoiled.

**Server check.**

```bash
slog 1
```

Expected: one row, amount `-1`, type `consume`, `"spoiled":true`. **Reset.**

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### B6. Consume with sub-product substitution

**Purpose.** A parent with no stock of its own can draw on a child when the toggle is on.

**Needs.** Adult key. Baseline data. `mac-Pasta` selected.

**Steps.**

1. Choose **Book › Consume**. Note the extra toggle **Use a sub-product if this one is out**.
   Leave it off. Click **Consume**.
2. Click **OK** on the alert.
3. Open **Consume** again. Turn the toggle on. Click **Consume**.
4. Tick **Include sub-products** in the inspector.

**Expected.**

- After step 1 an alert titled **That did not work** reads `Amount to be consumed cannot be >
  current stock amount (if supplied, at the desired location)`. The sheet has closed. No undo
  bar shows.
- After step 3 the bar reads `Consume recorded.` The Pasta row still reads `0 Packs`.
- After step 4 the lots are `1 Pack` and `3 Packs`. Penne gave the pack.
- The toggle appears for `mac-Pasta` and not for `mac-Milk`.

**Server check.**

```bash
slog 1; pid "mac-Pasta Penne"
```

Expected: one row, amount `-1`, whose `product_id` equals the id printed for Penne. **Reset.**

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### B7. Add to stock (purchase), with and without options

**Purpose.** A purchase adds a lot. A due date or price left off is recorded as unknown, not
as a made-up value.

**Needs.** Adult key. Baseline data. `mac-Rice` selected.

**Steps.**

1. Choose **Book › Add to stock**. Read the sheet.
2. Set **Amount** to 2. Change nothing else. Click **Add to stock**.
3. Click **Undo**.
4. Open **Add to stock** again. Set **Amount** to 3. Turn on **Set a due date** and pick a date
   30 days away. Turn on **Record a price** and type 2.5 in **Price per Pack**. Type `mac note` in
   **Note**. Choose `mac-Fridge` in **Location**. Click **Add to stock**.
5. Click **Undo**.

**Expected.**

- Step 1: fields **Amount**, **Location** (`Anywhere`), the toggles **Set a due date** and
  **Record a price**, and **Note**. A footer reads `A due date left off takes the product's
  own shelf life. A price left off is recorded as unknown, not as free.`
- After step 2: Rice reads `7 Packs`. A lot of 2 Packs shows with today's date and a price `—`.
  Rice's Due is today. Value stays `16.00`. **Due soon** gains Rice.
- After step 3: Rice reads `5 Packs`.
- After step 4: Rice reads `8 Packs`. A new lot of `3 Packs` shows the chosen date, `mac-Fridge`,
  the price `2.50` and the note `mac note`. Value reads `23.50`.
- After step 5: Rice reads `5 Packs`, and the new lot is gone.

**Server check.** After step 2 and again after step 4:

```bash
lots mac-Rice
```

Expected after step 2: a lot `{"amount":2,"due":"<today>","price":null,"at":"mac-Pantry"}`.
Expected after step 4: a lot with the chosen date, `"price":2.5` and `"at":"mac-Fridge"`.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### B8. Mark opened, and refuse too much

**Purpose.** Opening marks part of a lot. The server refuses to open more than exists.

**Needs.** Adult key. Baseline data. `mac-Flour` selected.

**Steps.**

1. Choose **Book › Mark opened**. Read the sheet.
2. Leave **Amount** at 1. Click **Mark opened**.
3. Click **Undo**.
4. Open **Mark opened** again. Set **Amount** to 3. Click **Mark opened**.

**Expected.**

- Step 1: **Amount**, a **Specific container** section with **Container**. There is no
  **Location** field.
- After step 2: the bar reads `Mark opened recorded.` The table row shows a drop icon. The
  inspector shows **Opened** `1 Pack` and two lots: one `1 Pack` with an `opened` tag and one
  `1.5 Packs`.
- After step 3: the icon, the **Opened** row and the tag are gone.
- After step 4: an alert **That did not work** reads `Amount to be opened cannot be > current
  unopened stock amount`.

**Server check.** After step 2:

```bash
lots mac-Flour
```

Expected: one entry with `"open":1` and amount 1, one with amount 1.5. **Reset.**

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### B9. Correct inventory

**Purpose.** An inventory correction sets the counted amount. The server adds or removes the
difference.

**Needs.** Adult key. Baseline data. `mac-Eggs` selected.

**Steps.**

1. Choose **Book › Correct inventory**. Read the amount field.
2. Click **Correct inventory** without changing anything.
3. Click **OK**. Open the sheet again. Set **Counted amount** to 10. Click **Correct inventory**.
4. Click **Undo**.
5. Open the sheet. Set the count to 14. Turn on **Set a due date**, pick a date, turn on
   **Record a price**, type 0.35, type `mac note`. Click **Correct inventory**. Click **Undo**.

**Expected.**

- Step 1: the field is labelled **Counted amount** and already holds 12. Its tooltip reads
  `What is actually there. The server adds or removes the difference.`
- After step 2: the button was enabled. An alert **That did not work** reads `The new amount
  cannot equal the current stock amount`. See the observations.
- After step 3: the bar reads `Correct inventory recorded.` Eggs reads `10 Pieces`.
- After step 4: Eggs reads `12 Pieces`.
- After step 5, before undo: Eggs reads `14 Pieces`, with a new lot of `2 Pieces` that has the
  chosen date, price `0.35` and the note. After undo it reads `12 Pieces`.

**Server check.** After step 3:

```bash
slog 1
```

Expected: amount `-2`, type `inventory-correction`. **Reset.**

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### B10. Transfer between locations

**Purpose.** A transfer moves part of a lot. The form blocks a move to the same place.

**Needs.** Adult key. Baseline data. `mac-Butter` selected.

**Steps.**

1. Choose **Book › Transfer**. Read the sheet.
2. Choose `mac-Fridge` in **To**. Look at the button. Change **To** to `mac-Freezer`.
3. Click **Transfer**.
4. Click `mac-Freezer` in the sidebar, then click **Undo**.
5. Select `mac-Eggs`. Open **Transfer**. Choose `mac-Freezer` in **From** and `mac-Pantry` in
   **To**. Click **Transfer**.

**Expected.**

- Step 1: **Amount** 1, **From** already on `mac-Fridge`, **To** on `Choose…`, and a
  **Specific container** section without the sub-product toggle. **Transfer** is disabled.
- Step 2: with the same place in both, **Transfer** is disabled. With the freezer it is enabled.
- After step 3: the bar reads `Transfer recorded.` Butter still reads `3 Packs`. The inspector
  lists `2 Packs` at `mac-Fridge` and `1 Pack` at `mac-Freezer`.
- Step 4: before the undo the freezer shows Butter 1 Pack and Peas 6 Packs. After the undo it
  shows only Peas.
- After step 5: an alert reads `Amount to be transferred cannot be > current stock amount at the
  source location`.

**Server check.** After step 3:

```bash
lots mac-Butter; slog 2
```

Expected: two lots; two log rows with types `transfer_to` and `transfer_from`, amounts `1`
and `-1`. **Reset.**

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### B11. Amount rules in the sheet

**Purpose.** The form refuses amounts that are not positive and passes everything else to the
server.

**Needs.** Adult key. Baseline data. `mac-Eggs` selected.

**Steps.**

1. Open **Book › Consume**. Type 0 in **Amount**. Look at the button.
2. Type -1. Look at the button.
3. Type 99 and click **Consume**. Click **OK**.
4. Open **Add to stock**. Type -1 in **Price per Piece** after turning on **Record a price**.
   Look at the button. Cancel.

**Expected.**

- Steps 1 and 2: **Consume** is disabled.
- Step 3: an alert reads `Amount to be consumed cannot be > current stock amount (if supplied,
  at the desired location)`. Nothing changes. No undo bar shows.
- Step 4: the button stays enabled. The form does not check prices. The server accepts a
  negative price. See the observations. Do not click **Add to stock**.
- The stepper next to **Amount** will not go below 0.001 in these sheets. In **Correct
  inventory** it goes down to 0.

**Server check.** None.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### B12. Undo bar behaviour

**Purpose.** Undo applies only to the latest booking, and a failure clears it.

**Needs.** Adult key. Baseline data. A table row clicked, so the search field does not have focus.

**Steps.**

1. Consume 1 Egg. Click **Dismiss**.
2. Consume 1 Egg again, then transfer 1 Butter to `mac-Freezer`. Look at the bar.
3. Press Cmd-Z.
4. Consume 1 Egg. Then open **Correct inventory** on Eggs and click **Correct inventory** with
   the count unchanged. Click **OK**.

**Expected.**

- Step 1: the bar disappears. Nothing is undone: Eggs stays at 11.
- Step 2: the bar reads `Transfer recorded.` only. The Egg consume can no longer be undone
  from the app.
- Step 3: the transfer is undone, the same as clicking **Undo**.
- Step 4: after the alert closes there is no bar. A failed booking clears the old undo.
- The bar stays while you change sidebar entries or search.

**Server check.**

```bash
slog 4
```

Expected: the rows match the order you did them, with `undone` 1 only on the transfer rows.
**Reset.**

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### B13. Cancel makes no request

**Purpose.** Cancel and Esc change nothing on the server.

**Needs.** Adult key. Baseline data. `mac-Eggs` selected.

**Steps.**

1. Run `slog 1` and note the `id`.
2. Open **Book › Consume**. Set **Amount** to 3. Click **Cancel**.
3. Open it again. Set **Amount** to 3. Press Esc.
4. Run `slog 1` again.

**Expected.** Both closes dismiss the sheet. No bar shows. The `id` in step 4 equals the one
from step 1. Eggs still reads `12 Pieces`.

**Server check.** `slog 1`, as in the steps.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

## Part E: errors

### E1. Server unreachable

**Purpose.** A failed refresh or booking reports the transport error and keeps the old rows.

**Needs.** Adult key. Connected with the table loaded. A way to cut the link to the instance:
switch Wi-Fi off, or unplug the cable.

**Steps.**

1. Cut the network.
2. Click **Refresh**.
3. Select a product. Open **Book › Consume** and click **Consume**.
4. Restore the network. Click **Refresh**.

**Expected.**

- After step 2: the subtitle shows `Could not reach the server:` followed by the system's
  reason, for example `The Internet connection appears to be offline.` The rows stay on screen.
- After step 3: the sheet closes. An alert **That did not work** shows a `Could not reach the
  server: …` message. No undo bar shows.
- After step 4: the subtitle returns to `N products`.

**Server check.** After step 4, `stock1 mac-Eggs` shows the unchanged amount.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### E2. The poller stops after an outage

**Purpose.** The change poller gives up after three failed polls and does not restart.

**Needs.** E1 done. Window open and connected. The poller checks every 30 seconds.

**Steps.**

1. Cut the network and wait two minutes.
2. Restore the network.
3. Run the consume command from L8 in a terminal. Wait 60 seconds. Do not touch the app.
4. Click **Refresh**.
5. Run the consume command again. Wait 60 seconds.
6. Press Cmd-N. In the new window wait 5 seconds, then run the consume command again.
   Wait 45 seconds.

**Expected, from the code.**

- Step 3: the list does not change by itself.
- Step 4: the list updates.
- Step 5: the list does not change by itself. The poller does not restart.
- Step 6: the new window updates on its own. Its poller is new.
- No error or banner announces any of this.

**Server check.** `stock1 mac-Eggs` after each consume. **Reset.**

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### E3. Forbidden: the backstop after a permission change

**Purpose.** The app reads permissions once. A later change is caught by the server's 403.

**Needs.** K1 complete, and still connected as the Child key. `mac-Eggs` selected. Run K1
before this case. K2 follows it. This case changes the Child test user's role, and other
sessions that use the Child key will see it. Keep this terminal open: K2 reuses the
variables set here.

**Steps.**

1. In a terminal, swap the Child user to the Guest role:

```bash
CHILD_ID=$(vget /users | jq -r '.[] | select(.username == "Child-Test") | .id')
ROLE_GUEST=$(vget /objects/roles | jq -r '.[] | select(.code == "GUEST") | .id')
ROLE_CHILD=$(vget /objects/roles | jq -r '.[] | select(.code == "CHILD") | .id')
vsend PUT /users/$CHILD_ID/roles "{\"roles\":[$ROLE_GUEST]}"
```

2. In the app, do not reconnect. Open **Book**. Choose **Consume** and click **Consume**.

**Expected.**

- Step 1 prints nothing (HTTP 204). Adjust the user name if your Child user differs.
- Step 2: **Consume** is still enabled, because the window read permissions earlier. The
  alert **That did not work** reads `This API key does not have permission for that.` No undo
  bar shows.
- Leave the role swapped and go to K2. Restore it at the end of K2.

**Server check.** The server refuses the same call:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$VICTUAL_DEV_URL/api/stock/products/$(pid mac-Eggs)/consume" -H "VICTUAL-API-KEY: $VICTUAL_CHILD_KEY" -H 'Content-Type: application/json' -d '{"amount":1}'
```

Run it before K2 step 3, while the Guest role is in place. Expected: `403`. Afterwards the
role must be restored: if you run it after the restore, it consumes one Egg and returns 200.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### E4. Undo of a booking that was already undone

**Purpose.** A stale undo reports the server's message and clears the bar.

**Needs.** Adult key. Baseline data. `mac-Eggs` selected.

**Steps.**

1. Consume 1 Egg. Leave the bar showing.
2. In a terminal, undo that booking from outside:

```bash
TX=$(slog 1 | jq -r .tx); vsend POST /stock/transactions/$TX/undo
```

3. In the app, click **Undo**.

**Expected.**

- Step 2 prints nothing (HTTP 204).
- Step 3: an alert **That did not work** reads `This transaction was not found or already undone`.
  The bar disappears. Eggs reads `12 Pieces`.

**Server check.** A second outside undo is refused:

```bash
vsend POST /stock/transactions/$TX/undo
```

Expected: `{"error_message":"This transaction was not found or already undone"}`.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### E5. Booking against stock that changed

**Purpose.** The server's refusal shows, and the window re-reads afterwards.

**Needs.** Adult key. Baseline data. `mac-Eggs` selected.

**Steps.**

1. Open **Book › Consume** and leave the sheet open.
2. In a terminal, consume 10 Eggs:
   `vsend POST /stock/products/$(pid mac-Eggs)/consume '{"amount":10,"transaction_type":"consume"}' | jq -c 'length'`
3. In the sheet, set **Amount** to 5. Click **Consume**. Click **OK**.

**Expected.**

- Step 3: an alert reads `Amount to be consumed cannot be > current stock amount (if supplied,
  at the desired location)`.
- After the alert the Eggs row reads `2 Pieces`. The window re-read the list, though the
  booking failed.

**Server check.** `stock1 mac-Eggs`. Expected: `"amount":2`. **Reset.**

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

## Part K: limited keys

### K1. Child key: some controls disabled, prices absent

**Purpose.** A key without purchase, inventory, transfer and price permissions sees those
controls disabled with a reason, and sees no prices.

**Needs.** Connected as the Adult key. Baseline data. The Child key.

**Steps.**

1. Press Cmd-, to open the settings window.
2. Replace the API key with the Child key. Click **Connect**. Close the settings window.
3. Type `mac-` in the search field. Read the table columns.
4. Click `mac-Milk`. Read the inspector.
5. Open **Book**. Hover each disabled item for about a second.
6. Choose **Book › Consume**. Leave **Amount** at 1. Click **Consume**.
7. Click **Undo** in the bar.

**Expected.**

- Step 2: the window shows the form for a moment, then returns to stock.
- Step 3: the columns are **Product**, **Amount** and **Due**. There is no **Value** column
  and no `0.00` anywhere.
- Step 4: the inspector has no **Last price**, **Average price** or **Stock value**, and no
  price at the right of any lot.
- Step 5: **Consume** and **Mark opened** are enabled. **Add to stock**, **Correct inventory**
  and **Transfer** are disabled. The tooltips read `Requires the STOCK_PURCHASE permission, which
  this account does not have.` and the same with `STOCK_INVENTORY` and `STOCK_TRANSFER`.
- Step 6: the bar reads `Consume recorded.` The amount falls by one.
- Step 7: an alert **That did not work** reads `This API key does not have permission for
  that.` The consume stays. Undo needs `STOCK_EDIT`, which the Child key lacks, and the app
  offered Undo anyway. See the observations.

**Server check.** The server hides prices from this key:

```bash
curl -sS "$VICTUAL_DEV_URL/api/stock" -H "VICTUAL-API-KEY: $VICTUAL_CHILD_KEY" | jq -c '.[] | select(.product.name == "mac-Milk") | has("value")'
```

Expected: `false`. The server leaves the field out for this key. **Reset.**

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### K2. Guest role: every booking disabled

**Purpose.** A key that may only read sees all five commands disabled, with the reason.

**Needs.** E3 step 1 done, so the Child user holds the Guest role. The app connected with the
Child key.

**Steps.**

1. In the settings window, click **Connect** again to reconnect. Close the settings window.
2. Select `mac-Eggs`. Open **Book**. Hover each item.
3. Restore the role:

```bash
vsend PUT /users/$CHILD_ID/roles "{\"roles\":[$ROLE_CHILD]}"
```

**Expected.**

- Step 2: all five items are disabled. The tooltips read `Requires the STOCK_CONSUME
  permission, which this account does not have.` and the same with `STOCK_PURCHASE`,
  `STOCK_OPEN`, `STOCK_INVENTORY` and `STOCK_TRANSFER`.
- The list still loads, with no price column.
- Step 3 prints nothing (HTTP 204).
- Afterwards, open the settings window, replace the key with the Adult key and click
  **Connect**. Connecting as the Child key replaced the saved key, so a relaunch would
  otherwise restore the Child key.

**Server check.**

```bash
vget /users/$CHILD_ID/roles | jq -c '.[].code'
```

Expected: `"CHILD"`.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

## Part W: windows, menus and appearance

### W1. Several windows

**Purpose.** Each window works alone. They share one connection.

**Needs.** Adult key. Baseline data.

**Steps.**

1. Press Cmd-N. Arrange two windows side by side.
2. In window A select `mac-Eggs`. In window B select `mac-Milk`.
3. In window A consume 1 Egg. Look at B without touching it. Wait up to 40 seconds.
4. In window A leave a booking bar showing. Look at B.

**Expected.**

- Step 1: the second window opens already connected, on **All stock**, with no form.
- Step 2: the selections are independent.
- Step 3: A updates at once. B shows `11 Pieces` for Eggs within about 35 seconds.
- Step 4: the undo bar is in A only.

**Server check.** `stock1 mac-Eggs`. **Reset.**

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### W2. Closing and reopening windows

**Purpose.** Closing every window leaves the app running and a new window opens connected.

**Needs.** Connected.

**Steps.**

1. Press Cmd-W until no window is left. Look at the menu bar.
2. Choose **File › New Window**.

**Expected.**

- Step 1: the app stays in the menu bar and the Dock.
- Step 2: a window opens already connected and loading stock. The **File** menu has **New
  Window**.

**Server check.** None.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### W3. Settings window

**Purpose.** There is one settings window and it matches the connection form.

**Needs.** Connected.

**Steps.** Press Cmd-,. Press it again. Close it. Open it from the **Victual** menu.

**Expected.**

- A window 480 by 400 points with the **Instance** section (address, key), the **Connect**
  button and the **Connected** section.
- A second Cmd-, brings the same window forward.
- The main window has no sign-out or disconnect control. This window is the only place for
  both.

**Server check.** None.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### W4. Menus and keyboard shortcuts

**Purpose.** Confirm which shortcuts and menu items exist.

**Needs.** Connected, with a booking bar showing and a row selected.

**Steps.** Open every menu in the menu bar. Try each shortcut in the table.

| Key | Expected |
| --- | --- |
| Cmd-N | New window |
| Cmd-W | Close window |
| Cmd-, | Settings |
| Cmd-Q | Quit |
| Cmd-Z | Undo the last booking, while the bar shows |
| Return in a sheet | Presses the action button |
| Esc in a sheet | Cancels |
| Up and Down in the table | Move the selection and load the product |
| Cmd-F | Not bound by the app. Record what happens. |
| Cmd-R | Not bound. The toolbar button has no shortcut. |

**Expected.**

- The menu bar has the standard menus only. There is no stock menu and no menu item for
  Book, Refresh or the five bookings. The plan mentions a commands menu. The code has none.
- **Victual** holds **About Victual**, **Settings…** and the usual items.

**Server check.** None.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### W5. Dark mode

**Purpose.** All screens read well in dark appearance.

**Needs.** Connected. Open System Settings › Appearance.

**Steps.** Choose **Dark**. Look at the connection form (use Disconnect), the table with red
due dates, the inspector, a booking sheet, the undo bar, an alert, and the settings window.
Switch back to **Light** and repeat for the sheet and the bar.

**Expected.** Text is readable on every surface. Red dates are distinguishable from normal text.
The undo bar and the sheet follow the appearance. Nothing is white-on-white or black-on-black.

**Server check.** None.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### W6. Large text and small windows

**Purpose.** Layout holds with larger text and a narrow window.

**Needs.** Connected. Baseline data.

**Steps.**

1. Shrink the window to its smallest size. Look at the table and inspector.
2. Open System Settings › Accessibility › Display. Raise **Text size** if your macOS offers it.
   Otherwise note that it does not. Relaunch the app.

**Expected.**

- Step 1: the window stops at a minimum size. The table keeps **Product**, **Amount**, **Due**
  and **Value** readable. The text does not overlap.
- Step 2: text grows if the system setting reaches this app. Rows, sheets and the undo bar
  still show every control. Record what you set.

**Server check.** None.

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

### W7. Quit with a sheet or bar open, and relaunch

**Purpose.** Nothing half-finished persists.

**Needs.** Connected. Baseline data.

**Steps.** Open a **Consume** sheet. Press Cmd-Q. Relaunch. Then consume 1 Egg, leave the bar
showing, press Cmd-Q and relaunch.

**Expected.**

- The relaunched app opens connected with the list loading and no sheet.
- The bar is gone. The Egg consume stays recorded and is no longer undoable from the app.

**Server check.** `slog 1` shows the consume with `undone` 0. **Reset.**

**Result:** [ ] Pass  [ ] Fail  [ ] Blocked  Notes:

## Results sheet

Fill the header, then mark each case.

| Field | Value |
| --- | --- |
| Tester and date | |
| macOS version | |
| Xcode version | |
| App version from About | |
| Signature and TeamIdentifier | |
| Cmd-U result (total, failures) | |
| Server version | 0.4.0 |
| Seed run date | |
| ATS: C4 outcome | |

| Case | Pass | Fail | Blocked | Notes |
| --- | --- | --- | --- | --- |
| C1 Not a web address | | | | |
| C2 Refused connection | | | | |
| C3 Bare host to HTTPS | | | | |
| C4 Plain HTTP, unmodified | | | | |
| C5 Wrong key | | | | |
| C6 Connect | | | | |
| C7 Relaunch remembered | | | | |
| C8 Disconnect | | | | |
| C9 Forget | | | | |
| C10 No STOCK_VIEW (optional) | | | | |
| L1 First load | | | | |
| L2 Sorting | | | | |
| L3 Search | | | | |
| L4 Status buckets | | | | |
| L5 Locations | | | | |
| L6 Amounts and opened marker | | | | |
| L7 Due colours | | | | |
| L8 Refresh | | | | |
| L9 Change poller | | | | |
| P1 Inspector, several lots | | | | |
| P2 Sub-products | | | | |
| P3 No stock | | | | |
| P4 Long name | | | | |
| B1 Menu gating | | | | |
| B2 Partial consume | | | | |
| B3 Consume across lots | | | | |
| B4 Named container | | | | |
| B5 Location and thrown away | | | | |
| B6 Substitution | | | | |
| B7 Add to stock | | | | |
| B8 Mark opened | | | | |
| B9 Correct inventory | | | | |
| B10 Transfer | | | | |
| B11 Amount rules | | | | |
| B12 Undo bar | | | | |
| B13 Cancel | | | | |
| E1 Unreachable | | | | |
| E2 Poller stops | | | | |
| E3 Forbidden backstop | | | | |
| E4 Stale undo | | | | |
| E5 Changed stock | | | | |
| K1 Child key | | | | |
| K2 Guest role | | | | |
| W1 Several windows | | | | |
| W2 Close and reopen | | | | |
| W3 Settings window | | | | |
| W4 Menus and shortcuts | | | | |
| W5 Dark mode | | | | |
| W6 Large text, small window | | | | |
| W7 Quit and relaunch | | | | |

Overall: [ ] Accept  [ ] Accept with findings  [ ] Reject

After the run: restore the dev instance with `Scripts/seed-dev-household.py`, restore the
Child user's role if you ran E3, and run `git checkout Apps/Victual/project.yml` if you applied
the local ATS change. If the saved key should be the Adult key again, connect with it once
in the settings window.

## Observations from reading the code

These are not steps. Each is something the code or the server payloads showed. Cases that
touch them say where.

1. **Plain HTTP is probably blocked.** No App Transport Security exception exists in the Mac
   application. See C4.
2. **Undo is offered to a key that cannot undo.** `CapabilityGate.canUndo` checks only the
   read-only flag. The server requires `STOCK_EDIT` for undo. A Child key sees the bar, and Undo
   answers 403. See K1.
3. **Inventory with an unchanged count is not blocked.** The form starts at the current amount
   and enables the button. The server answers 400. See B9.
4. **Below-minimum rows show `0` on hand.** The server's missing-product record has no stock
   amount, and the row prints 0 even when some is on hand. A product with no stock row, such as
   Salt, also loses its unit. See L4 and B3.
5. **Parents show only their own stock.** `mac-Pasta` shows `0 Packs` while its children hold
   5. The aggregated amount is not used. See L1 and P2.
6. **Every product shows `Measured 0 Packs`.** The server sends 0, and the row appears for
   any non-null value. See P1.
7. **Unpriced stock reads `0.00` in All stock.** The server sends 0, not an absent value.
   Location views show `—` for the same stock. See L1 and L5.
8. **Negative prices and tiny amounts pass.** The form checks only that the amount is
   positive, and the server stored a price of −1 and an amount of 0.0004 in tests. See B11.
9. **The poller never restarts after three failures.** No message says so. See E2.
10. **Permissions load once per window.** A change on the server shows only after a reconnect.
    The 403 alert is the only signal. See E3.
11. **No commands menu and no refresh shortcut.** The plan lists a commands menu. See W4.
12. **No product-group filter.** The sidebar holds the five buckets and the locations. Sub-products
    appear only through the inspector's checkbox.
13. **A lot due today renders red.** The comparison is date at midnight against now. See L7.
14. **Undo splits lots.** The server returns a restored amount as a separate entry. See B2, B3.
15. **Cream sits in both Overdue and Expired.** This is the server's bucketing. See L4.
16. **The Locations list is long and unsearchable.** The instance has over 170 locations.

## Known gaps and things not covered

- **HealthKit.** The Mac application does not link `VictualHealth`. Nothing here covers it.
- **Scanning.** The Mac application has no scanner. The iPhone guide covers it.
- **Read-only key.** No read-only (MCP) key was supplied. The tooltip `This API key is
  read-only and cannot change anything.` and the subtitle suffix ` · read-only key` are not
  exercised.
- **Newer server.** The dev instance runs 0.4.0, the version the app was built for. The
  warning banner for a newer server cannot appear.
- **Keychain failure.** The banner `This key was not saved…` needs a Keychain that refuses to
  save. Nothing here forces that.
- **Keychain with a signed bundle.** The data-protection Keychain is off. The file-based store
  is exercised. Record the signature in the results sheet. Plan 01 still lists signed-bundle
  restore as open.
- **Key without `STOCK_VIEW`.** Case C10 is optional because no such key was supplied.
- **Other languages and time zones.** Dates parse as local midnight. Nothing here changes the
  Mac's region or time zone.
- **VoiceOver and other accessibility tools.**
- **Distribution.** Notarization, the App Store and Intel hardware.
- **Other server features.** Shopping list, chores, tasks, batteries, recipes and the meal
  plan are out of scope for this application.
