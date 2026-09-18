# Concept: Siri and App Intents for the Victual iPhone app

**Status:** concept, not a decision. Written 2026-09-17, ahead of the iPhone app being cut.
**Scope:** what it takes for a household member to talk to a self-hosted Victual instance
through Siri, what `victual-kit` has to grow to allow it, and which of those things are
constrained by decisions the server has already taken.

This document lives in `victual-kit` because the SDK is what changes. It should travel to
the app repository once that exists.

---

## 1. The premise

The audience is one person: a household member who is not going to open an app, navigate to
a product, and tap a stepper. She will say a sentence while her hands are wet, or while
standing in front of an open fridge, or in a shop. If that sentence does not work the first
time, she will not say it a second time.

That framing is the whole design constraint. It rules out a long intent catalogue, it rules
out anything that asks a follow-up question it could have answered itself, and it makes
silent failure the worst possible outcome — worse than refusing outright, because a shopping
list that silently did not get the milk is a shopping list she stops trusting.

## 2. Framework choice

App Intents. It is not really a choice: SiriKit custom intents are the previous generation,
and App Intents is the current path to Siri, Spotlight, the Shortcuts app, widgets, Control
Center and the Action button from one set of declarations.

`victual-kit`'s floor (iOS 17 / watchOS 10 / macOS 14, set by Observation) already clears
App Intents' own (iOS 16 / watchOS 9). See §9 for whether the app should sit higher.

## 3. Shape

Three layers, and the middle one is new:

```
PantryApp (iOS app target)            SwiftUI, VictualSession, the screens
  └── VictualIntents (new)            AppIntent / AppEntity / AppShortcutsProvider
        └── VictualKit                VictualUI, VictualCore, VictualAPI
```

`VictualIntents` exists as its own module because intents run in contexts the app's UI layer
does not: background, out of process, possibly in an app extension, always without a window.
Mixing them into the app target works until the first time you want an extension, and then
it does not.

### 3.1 Where the intent types are allowed to live

App Intents metadata is extracted by the compiler at **app** build time. A library can host
the declarations via `AppIntentsPackage`:

```swift
// VictualIntents
public struct VictualIntentsPackage: AppIntentsPackage {}

// PantryApp
struct PantryAppPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [VictualIntentsPackage.self] }
}
```

**Risk, unverified:** Apple documents this in terms of a *framework*. Whether extraction is
reliable from a SwiftPM **static** library target in the current toolchain is the one thing
in this concept I have not confirmed, and it is load-bearing for the module split above.

**Mitigation:** on day one, declare one trivial intent directly in the app target and confirm
it appears in the Shortcuts app. Then move it to `VictualIntents` and confirm it *still*
appears. That is a thirty-minute experiment that decides the architecture, and doing it
before anything else costs nothing.

## 4. The intents worth having

Deliberately short. Every entry earns its place by being a sentence she would actually say.

The sentences below spell the app name "Victual" because that is its name today. Every one of
them is affected by the naming question in §7.6 — read that before taking these as final.

| # | Sentence | Operation | Params | Notes |
|---|---|---|---|---|
| 1 | "Add what I'm out of to Victual" | `postStockShoppinglistAddMissingProducts` | none | Zero-parameter, background, idempotent-ish. **Build this first.** |
| 2 | "Add milk to Victual" | `postStockShoppinglistAddProduct` | product, amount | The one she'll actually use daily. Needs §5. |
| 3 | "What's expiring in Victual" | `getVolatileStock` | none | Read-only. Also the widget. |
| 4 | "How much milk is in Victual" | `getStockProductsByProductId` | product | Read-only. |
| 5 | "I used two eggs in Victual" | `postStockProductsByProductIdConsume` | product, amount | Destructive — see §7.5. |
| 6 | "Mark the bins as done in Victual" | `getChores` + `postChoresByChoreIdExecute` | chore | Second wave. |

Not in scope for v1: purchase/add-to-stock (needs dates, prices, locations — a form, not a
sentence), transfers, inventory corrections, recipes, batteries.

Intent 1 is the recommended first build because it exercises the entire vertical — Keychain
read in a background context, client construction without `VictualSession`, a live call, a
spoken result — while having no parameters at all. It isolates the plumbing from the hard
part, which is §5.

## 5. The hard part: turning a spoken word into a product id

Everything interesting in intents 2, 4 and 5 hinges on resolving "milk" to
`product_id = 37`. This is the actual engineering. The rest is wiring.

```swift
struct ProductEntity: AppEntity {
    let id: Int
    let name: String

    static var defaultQuery = ProductQuery()
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Product" }
}

struct ProductQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [ProductEntity] { … }
    func entities(for ids: [Int]) async throws -> [ProductEntity] { … }
}
```

Four things make this hard, and three of them are Victual's, not Apple's:

**5.1 Latency.** `entities(matching:)` is on the critical path of a spoken interaction. It
cannot be a round trip to a PHP app on a home server. The catalogue must be cached locally
(`GET /objects/products`), refreshed by the app on foreground and by a background task, and
queried from disk. Plan the cache before the intent.

**5.2 Speech is not text.** Siri will hand you "to mater sauce", "whole milk", "milks". Exact
prefix matching will fail constantly. This needs normalisation and fuzzy scoring against
product names — and probably against a household alias table, because she calls it "the good
olive oil" and Victual calls it "Olive oil, extra virgin (500ml)". An alias store is a small
feature that will do more for perceived quality than any other item in this document.

**5.3 Packaging ambiguity (ADR-0023).** `parent_product_id` means *packaging* and is one
level deep; taxonomy lives in nested `product_groups`. So "milk" may legitimately match both
a single carton and a case of twelve. For shopping-list and consume intents, resolving to the
stock-unit child is almost always what she means. The parent should be filtered out of
`entities(matching:)` results rather than offered as a disambiguation — offering it is a
question she cannot answer.

**5.4 Aggregation (ADR-0022 and `is_aggregated_amount`).** "How much milk do I have" has to
decide what to say when there are three sealed cartons and one opened one with a measured
remainder. `CurrentStockResponse` gives you `amount`, `amount_opened`, and the `_aggregated`
pair. A spoken answer should be one number and a qualifier — "four cartons, one of them
open" — not a reading of the data model.

## 6. What `victual-kit` has to grow

Concrete, in the order an app will need them.

**6.1 A non-`@MainActor` way to get a client.** `VictualSession` is `@MainActor` and models a
*UI* lifecycle — `serverText`, `apiKeyText`, `.connecting`. An intent's `perform()` is
nonisolated, runs in the background, and may run in another process. **Intents must not touch
`VictualSession`.** What they need is a small resolver in `VictualCore`:

```swift
public struct VictualClientResolver: Sendable {
    public init(credentialStore: any VictualCredentialStore = KeychainCredentialStore(…))
    public func resolveClient() async throws(VictualError) -> VictualClient
}
```

reading the saved server and key and building a client, with no UI types anywhere in it.
`KeychainCredentialStore.savedServers()` already provides the lookup this needs.

**6.2 Keychain configuration the app must get right.** Two settings that are already
supported and will silently break intents if left at defaults:

- `accessibility: .afterFirstUnlock` — a background intent firing after a reboot cannot read
  a `whenUnlocked` item.
- `accessGroup` — required the moment intents move into an app extension, and cheaper to set
  on day one than to retrofit.

**6.3 Convenience methods.** `VictualClient+Convenience.swift` currently covers
`systemInfo()` and `currentStock()`, and says explicitly that it is a pattern to extend. Each
intent in §4 needs one method written in that shape: generated call in, `VictualError` out.

**6.4 A product catalogue cache.** Per §5.1. Arguably belongs in the app rather than the SDK,
but every future Victual client will want it, which is an argument for `VictualCore`.

## 7. Constraints that will bite

Grounded in the server source, not speculation.

### 7.1 API keys now expire, and the app cannot rotate them

This is the sharpest edge in the whole design, and it is new in the fork.

`ApiKeyService::CreateApiKey()` gives a regular key a finite expiry — the requested lifetime
clamped to `API_KEY_MAX_LIFETIME_DAYS`, **default 365**. Upstream grocy set expiry to the
year 2999; Victual does not.

Rotation exists, but `POST /manageapikeys/{id}/rotate` sits in the root route group
(`routes.php:173`), which is session-authenticated web UI. The `/api` group does not start
until line 176. **There is no API-accessible rotation path.** An app holding a key can
observe that it is about to die but cannot do anything about it.

So: roughly a year after setup, every Siri phrase starts returning 401, in a context with no
UI to explain it, to a person who did not set the key up. Silent, total, and confusing.

Minimum viable handling:

- Treat `VictualError.unauthorized` from an intent as a first-class, *loud* outcome: a spoken
  dialog that says the connection needs attention, not a generic failure.
- Have the app check key age and warn well before expiry, in-app and via notification.
- Consider asking the server for an `/api`-reachable rotation endpoint. That is a Victual
  change, not an app change, and it is the only actual fix. Worth raising as an issue against
  the server before the app ships, because the app's design around it differs a lot depending
  on the answer.

### 7.2 The instance is probably not reachable from a shop

Self-hosted. "Add milk to Victual" while standing in the supermarket is the single highest-
value moment for this feature and the one most likely to fail.

Two answers, and they should be chosen now because they change the intent's error path:

- **Expose the instance** (Tailscale, or a reverse proxy with the key over TLS). Simplest;
  a household decision, not a code one.
- **Queue locally and drain on reach.** The intent succeeds immediately, writes to a local
  outbox, and a background task flushes it. Better UX, materially more code, and it means an
  intent's "yes, added" is a promise rather than a fact — which is only acceptable for the
  shopping list, never for consume.

### 7.3 Permissions are per key, because a key belongs to a user

`ApiKeyAuthenticator` resolves a key to its owning user; the permission hierarchy is real and
granular. The relevant grants:

| Intent | Needs |
|---|---|
| Add to shopping list | `SHOPPINGLIST_ITEMS_ADD` |
| Read stock / expiring | `STOCK_VIEW` |
| Consume | `STOCK_CONSUME` |
| Chores | `CHORE_TRACK_EXECUTION` |

Give her key exactly these and nothing else. A 403 from an intent should say which capability
is missing, because the person who can fix it is not the person who heard the error.

### 7.4 Auth is a header

`VICTUAL-API-KEY`, header only. The query-string fallback was deliberately removed as a
security fix; do not reintroduce it, and do not let a key end up in a URL anywhere in the app.

### 7.5 Consume is destructive and Siri is lossy

Intent 5 removes stock. Misheard amounts are a real failure mode ("two" / "ten"). It should
require confirmation — `requestConfirmation` before performing — and the confirmation should
speak back the resolved product and amount, not the raw utterance. Undo exists server-side
(`postStockTransactionsByTransactionIdUndo`), which is worth surfacing as its own intent
before this one ships.

### 7.6 Every phrase must contain the app name — and "Victual" is a trap

`AppShortcutPhraseToken` has exactly one case: `.applicationName`. Every spoken phrase must
contain the app's name. There is no way around it.

```swift
AppShortcut(
    intent: AddToShoppingListIntent(),
    phrases: ["Add \(\.$product) to \(.applicationName)"],
    shortTitle: "Add to shopping list",
    systemImageName: "cart.badge.plus"
)
```

That makes the app's name a **speech-recognition decision, not a branding one** — and this
project has an unusually bad one.

**Victual is pronounced /ˈvɪtəl/ — "vittle".** The plural, *victuals*, is "vittles"
(/ˈvɪtəlz/). The spelling and the sound diverged on purpose: the word arrived in Middle
English from Old French *vitaille*, already pronounced without a /k/; sixteenth-century
scholars re-inserted the *c* and *u* to make it resemble Latin *victualia*, and nobody
changed how they said it. The Latinate spelling is a four-hundred-year-old affectation
layered over the spoken form, and the spoken form won.

So the name breaks Siri in both directions at once:

- **Hearing.** She says "vittle". Siri's recogniser, absent a hint, is matching against an app
  named "Victual" and may well be expecting "VIK-choo-al". The phrase fails to route, and —
  per §1 — she does not try twice.
- **Speaking.** Siri reads results back. "Added milk to VIK-choo-al" is wrong in a way that is
  both grating and, for a household member who never asked for any of this, faintly absurd.

**What Apple offers, and how well it works.** Two mechanisms, neither reliable:

| Key | Fixes | Status |
|---|---|---|
| `CFBundleSpokenName` | Speaking (TTS, and VoiceOver) | Documented, current. "A replacement for the app name in text-to-speech operations." |
| `INAlternativeAppNames` + `INAlternativeAppNamePronunciationHint` | Hearing | SiriKit-era, **archived** documentation. "Sounds like" spelling, e.g. `vittle`. Max three entries per localised `Info.plist`. Historically required an Intents app extension. |

Both belong in the **main app bundle's** `Info.plist`, not an extension's:

```xml
<key>CFBundleSpokenName</key>
<string>vittle</string>
<key>INAlternativeAppNames</key>
<array>
    <dict>
        <key>INAlternativeAppName</key>
        <string>Vittles</string>
        <key>INAlternativeAppNamePronunciationHint</key>
        <string>vittles</string>
    </dict>
</array>
```

**The honest caveat:** a 2026 Apple Developer Forums thread has a developer who set *both*
keys and still could not fix Siri's stress pattern on a portmanteau app name. Apple DTS's
answer was to file a bug report and include how VoiceOver pronounces it. `AppIntentVocabulary.plist`
has no documented key path for the app name itself. These keys are worth setting, but they
are a mitigation, not a fix, and betting the app's primary interaction on them is unwise.

**Recommendation: name the app "Vittles".**

It is not a rebrand — *vittles* is an accepted phonetic spelling of the same word, and the
one English actually kept. It is spelled the way it is said, so recognition and read-back
both work with no plist keys and no bug reports. It is warm and domestic in a way "Victual"
is not, which suits a shared household pantry far better than a Latinate server name does.
And it keeps the server/client naming honest: the server is Victual, the thing in her hand
is Vittles, and the relationship between the two words is the joke rather than the bug.

Set `CFBundleSpokenName` anyway, and register "Victual" as an `INAlternativeAppName` with the
hint `vittle` so the formal name still routes when someone reads it off the icon.

If the name stays "Victual", then set both keys, verify by ear on a real device early — VoiceOver
on the Home screen is the cheapest test — and know that she can rename the app in the Shortcuts
app as a last resort.

### 7.7 Parameterised phrases need a bounded option set

Speaking the product inline — `"Add \(\.$product) to \(.applicationName)"` — requires the
parameter to publish a bounded set of options, refreshed via
`AppShortcutsProvider.updateAppShortcutParameters()` whenever the catalogue changes. For a
pantry of hundreds of items that means limiting inline phrases to a favourites subset and
letting the long tail take a "which product?" follow-up. Pick the favourites from actual
purchase frequency, not alphabetically.

## 8. Build order

Tomorrow, roughly in this sequence:

1. **The extraction spike** (§3.1). One trivial intent in the app target; confirm it appears
   in Shortcuts. Then move it to a package module; confirm again. Decides the architecture.
2. **`VictualClientResolver`** (§6.1) plus Keychain accessibility and access group (§6.2).
3. **Intent 1**, "add what I'm out of". End to end, no parameters. This is the vertical slice.
4. **The product cache** (§5.1) and `ProductEntity` / `ProductQuery` (§5).
5. **Intent 2**, "add milk". The one that matters.
6. Error surfaces: 401 (§7.1) and 403 (§7.3) as spoken, specific, actionable dialogs.
7. Everything else.

Steps 1–3 are a day. Step 4 is where the real time goes.

## 9. Open questions

1. **Deployment target.** Staying at iOS 17 keeps parity with `victual-kit`'s floor. Going
   higher buys newer App Intents affordances (`supportedModes` for foreground/background
   control, richer snippets, tighter Apple Intelligence integration). Given the audience is
   one phone in one household, there is no compatibility argument for staying low —
   recommend targeting the current OS and raising the app's floor above the SDK's.
2. **Does `AppIntentsPackage` work from a SwiftPM static library?** Answered by step 1.
3. **The app's name** (§7.6). Recommend "Vittles". This is the highest-leverage decision in
   the document and the cheapest to take now — it is a `CFBundleDisplayName` on day one and a
   migration later. Settle it before the first `AppShortcut` is written.
4. **Reachability** (§7.2) — expose, or queue? Decide before intent 2.
5. **Key rotation** (§7.1) — does Victual grow an `/api` rotation route? Raise upstream now.
6. **Watch app?** Siri on the wrist is arguably the best surface for this entire feature
   (hands wet, phone elsewhere). Out of scope for v1, but the module split in §3 is what keeps
   it cheap later, which is an argument for doing the split properly.
7. **No app-schema domain fits.** There is no groceries or pantry domain among Apple's
   schemas, so every intent here is custom. That is fine for Shortcuts and App Shortcuts, but
   it does mean weaker automatic Apple Intelligence understanding than a mail or photos app
   gets. Nothing to do about it; worth knowing before being disappointed.

## References

- Apple, [Getting started with the App Intents framework](https://developer.apple.com/documentation/appintents/getting-started-with-the-app-intents-framework)
- Apple, [`AppIntentsPackage`](https://developer.apple.com/documentation/appintents/appintentspackage)
- Apple, [App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts)
- Victual ADR-0022, open containers carry a measured remainder
- Victual ADR-0023, taxonomy is groups, packaging is parent product
- Victual ADR-0024, the fork writes its own clients — this app is a first-party client, and
  the wire contract is maintained for it
- Victual `docs/security-sweep.md` S11, API key hashing, expiry and rotation
