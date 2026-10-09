# 03. HealthKit medication sync

**Goal:** the iPhone application reads a person's medication dose events from Apple Health,
with the person's per-medication consent, and submits them to Victual so the household's
stock falls when a dose is logged — once per dose, however many times Health re-delivers,
edits or deletes it.

**Depends on:** [plan 02](02-iphone-scanning-app.md) (the phone application and its stores);
Victual [plan 22](https://github.com/datagen24/victual/blob/master/docs/plans/22-medication-tracking.md)
and the proposed
[ADR-0041](https://github.com/datagen24/victual/pull/711) for the receiving API. Tracked
server-side as [victual#702](https://github.com/datagen24/victual/issues/702), which waits
on #696 (contract), #700 (external events) and #701 (refills). **None of those has
landed, so every server shape below is the proposed one.**

**Status:** see the [plan index](README.md).

**Server impact:** requires Victual 0.5.0 or later. Nothing here is callable on 0.3.0.
[Server feedback](#server-feedback) lists what the contract needs before this client can be
built honestly against it.

## Problem and outcome

A household member who takes medication logs doses in the Health app. Victual already knows
how many tablets are in which organizer. The two disagree until somebody types the dose in
twice. The outcome: log a dose once, in Health; Victual's stock for that product, at that
organizer, falls by that amount, and a later edit or deletion in Health corrects it.

What this plan is **not**: a dose scheduler, reminder, or adherence view. Victual plan 22
rules those out, and this client honours it — a skipped or unanswered dose is never sent as
consumption and leaves no trace on the server.

## What Apple provides

Primary sources: Apple's `HealthKit` reference pages (fetched 2026-10-09) and
[WWDC25 session 321](https://developer.apple.com/videos/play/wwdc2025/321/). Nothing below
has been observed on a device; the [device spike](#phase-0--device-spike) exists to do so.

| Fact | Source | Consequence |
| --- | --- | --- |
| All medication types are **iOS / iPadOS / watchOS / visionOS / macOS 26.0+**. | Reference pages for `HKMedicationDoseEvent`, `HKMedicationConcept`, `HKUserAnnotatedMedication`. | The package targets iOS 17 and the phone app iOS 18. HealthKit code needs its own target, `@available(iOS 26, *)` throughout. Targets are not raised. |
| `HKMedicationDoseEvent` is an `HKSample`. Fields: `medicationConceptIdentifier`, `logStatus`, `scheduleType`, `doseQuantity: Double?`, `scheduledDoseQuantity: Double?`, `scheduledDate: Date?`, `unit: HKUnit`, plus `startDate`/`endDate`/`uuid` from `HKSample`. | Reference. | `doseQuantity` is **optional**. See the [mapping table](#field-mapping). |
| `logStatus` has six cases: `taken`, `skipped`, `snoozed`, `notInteracted`, `notificationNotSent`, `notLogged`. `notLogged` is "the person undoes a previously logged medication status". | `LogStatus` reference. | ADR-0041 has four statuses; `notLogged` has no home. Server feedback 2. |
| `scheduleType` is `.schedule` or `.asNeeded`. | `ScheduleType` reference. | Used only for the `replaces` heuristic. |
| `HKMedicationConcept.identifier` is an `HKHealthConceptIdentifier`: an **opaque `NSSecureCoding` object**, not a string. It exposes only `domain`. The session says it is stable across devices and time. | Reference; session. | `medication_ref` must be *derived* from it. Server feedback 4. |
| Medications are **per-object authorized**: `requestPerObjectReadAuthorization(for:predicate:)` shows a sheet where the person ticks medications. It **always prompts**, even if already granted. Authorizing a medication grants its dose events. `requestAuthorization(toShare:read:)` for these types fails `errorInvalidArgument`. | Reference; session. | Authorization is an explicit, user-initiated "Choose medications" action. Never on launch. |
| Medication data is **read-only** to third parties. | Apple DTS reply, [forum thread 803954](https://developer.apple.com/forums/thread/803954). | Request read only; never `toShare`. `NSHealthShareUsageDescription` only. |
| Dose events can be logged retroactively and **edited by delete-and-recreate**; handle deletions from `HKAnchoredObjectQuery`. | Session. | `HKObject.uuid` is not a stable dose identity. See [replaces](#edits-and-the-replaces-inference). |
| Whether `enableBackgroundDelivery` works for `medicationDoseEventType`, what an anchored query emits when authorization is revoked, and what `unit` looks like for a tablet — **not documented**. | Absence in the above. | Device-spike questions. |

## Design

### A new package target, not new code in `VictualStock`

`VictualHealth` is a new library target depending on `VictualCore`. It is the only target
that imports `HealthKit`. Every public symbol is `@available(iOS 26, *)`. The Mac
application does not link it, and the iOS 17 package floor does not move.

Inside it, three layers, mirroring plan 01:

- **Model and sync logic with no HealthKit import.** `DoseEvent` (a plain value:
  `id`, `medicationRef`, `status`, `quantity?`, `unit`, `occurredAt`, `scheduledDate?`,
  `scheduleType`), `Mapping`, the status translation, the `replaces` heuristic, the anchor
  and outbox state machine. This is where almost all of the testing happens, against the
  fakes in `VictualTestSupport`.
- **`HealthKitDoseSource`**, a thin adapter that turns `HKMedicationDoseEvent` into
  `DoseEvent` and drives `HKAnchoredObjectQuery`. A protocol, `DoseEventSource`, sits in
  front so tests substitute a scripted source.
- **`MedicationSyncStore`** (`@MainActor @Observable`, like `StockStore`) that the phone
  app's screens read.

HealthKit is runtime-gated too: `HKHealthStore.isHealthDataAvailable()` and the OS check
decide whether the Medications screen exists at all.

### Entitlement and Info.plist

`com.apple.developer.healthkit` in the phone app's entitlements, and
`NSHealthShareUsageDescription` — read-only, so no `NSHealthUpdateUsageDescription`. The
HealthKit capability needs a provisioning profile that includes it, which an ad-hoc
unsigned build (plan 01's posture) cannot carry; **this is the first Victual capability
that cannot be exercised without a real team and a registered device.** The usage string is
the only thing a person reads before consenting, so it says what is read, that it is
read-only, and that doses are sent to *their own* Victual server and nowhere else.

### Feature visibility

The Medications screen appears only when all hold: iOS 26+, Health data available,
`SystemInformation.victualVersion >= 0.5.0` (using `ServerVersion`), and the key's
`CapabilityGate` allows `STOCK_CONSUME`. A control that is unavailable says why, per
`CapabilityGate`'s convention, rather than vanishing. A server newer than the package
already warns; this adds a *minimum*, which `ServerVersion` does not yet express and gains a
`isAtLeast(_:)`.

### Field mapping

| Victual field (ADR-0041) | From | Notes |
| --- | --- | --- |
| `source_system` | constant `healthkit` | Matches the ADR's example. |
| `source_event_id` | `HKObject.uuid.uuidString` | Fits `[A-Za-z0-9._:-]{1,128}`. Not stable across edits. |
| `medication_ref` | derived from `medicationConceptIdentifier` | Opaque object, no string form. Proposed: `hk:med:` + lowercase hex SHA-256 of its `NSKeyedArchiver` secure-coded bytes. **Unproven** that the archive is deterministic; the spike records `debugDescription` and archive equality across launches. |
| `status` | `logStatus` | See below. |
| `quantity` | `doseQuantity` | **Optional.** A `taken` event with `nil` quantity is *held locally* and flagged, not sent with a guessed 1. Server feedback 5 asks the contract to say what the mapping's default does. |
| `unit_label` | `unit.unitString` | Compared by exact string by the server. What Health reports for "tablet" is unknown; spike item. |
| `occurred_at` | `startDate` | RFC 3339 with the device's current offset. `scheduledDate` is *not* used: the person may take a dose hours late. |
| `source_updated_at` | client observation time | `HKObject` exposes no modification time. Server feedback 3. |
| `replaces` | inferred, see below | The only place this client infers. |
| `location_id` | the mapping's organizer choice | Sent when the mapping is `explicit`; otherwise omitted. |

Status translation:

| `HKMedicationDoseEvent.LogStatus` | Sent as | Why |
| --- | --- | --- |
| `taken` | `taken` | The only value that books. |
| `skipped` | `skipped` | |
| `notInteracted`, `notificationNotSent` | `unanswered` | Reminder states; never a consumption. |
| `snoozed` | `scheduled` | |
| `notLogged` | `unanswered` **until the server defines `not_logged`** | A person undid a prior `taken`. Through ADR rule 3 any non-`taken` status voids a booked row, which is the right effect; only the label is imprecise. |

Only events with a **non-`taken`** status for an id the client has *already sent as taken*
are worth sending. Skipped, snoozed and unanswered events for ids never sent are dropped
on the device. That keeps Victual's "no adherence record" promise from depending on the
server to enforce it and saves traffic.

### Sync: anchored query, durable outbox

1. One `HKAnchoredObjectQuery` for `medicationDoseEventType()`, predicated to the authorized
   medications and to `startDate >= mapping.effectiveFrom`. The server also enforces
   `effective_from` (rule 4); the client filter means connecting never reads, let alone
   uploads, old history.
2. Results become an **outbox**: one record per `(source_event_id, revision)` stored
   on disk in the app container, before the anchor advances. The anchor is persisted only
   after the outbox write, so a crash replays rather than loses.
3. A sender drains the outbox with `PUT /consumption/events/healthkit/{id}`. The identity is
   in the path, so a retry is safe by construction and the client needs no idempotency
   header. Offline simply leaves records queued.
4. Anchors are keyed by **(server, account, mapping set)**. Switching servers or users must
   not reuse another's anchor; re-mapping resets to `effectiveFrom`.
5. Deleted objects arrive as `HKDeletedObject` carrying only a `uuid`. The client looks the
   uuid up in its local ledger of ids it has sent. Unknown uuid: nothing to do. Known and
   booked: `DELETE`.

The ledger of sent ids is local state, not an extra source of truth: the server's
event row is authoritative and the ledger is an optimisation that lets the client skip
sending noise.

Delivery is foreground-driven (on launch, on foreground, on pull-to-refresh) until the
spike answers whether `enableBackgroundDelivery` is honoured for dose events. A background
path is added only if observed to work on a device; no claim is made from the API existing.

### Edits and the `replaces` inference

HealthKit edits are delete-and-recreate, and the client cannot read the old id from the
new sample. The server's `replaces` field is the clean way to make that one atomic
operation. The client can only *infer* the pairing, so it infers narrowly:

> Send `replaces: <old id>` only when a deletion and an insertion arrive **in the same
> anchored-query batch**, with the same `medicationConceptIdentifier` **and** the same
> non-nil `scheduledDate`, and `scheduleType == .schedule`. Never for `.asNeeded`.

Anything else is sent as an independent delete and create, which the ADR guarantees ends
at one deduction (rule 7) with a brief window of zero or two. An `.asNeeded` edit has no
natural key, and guessing one would risk voiding a different, real dose. This is open
question 3.

### Mapping: the person decides, the client never guesses

Server ADR rule 4: an event books only through a mapping the person approved. The screen
lists the authorized medications (`HKUserAnnotatedMedicationQueryDescriptor`; archived ones
shown separately), and for each the person picks a Victual product or recipe, the unit it
is counted in, and an organizer location rule (fixed, single, explicit). The client does
not match a medication name to a product, does not infer a conversion from a strength, and
does not pick an organizer. `nickname` and `displayText` are shown to the person and
**never sent**: the server needs an opaque reference, not a drug name.

**Privacy of what is held on device and sent.** The payload contains an opaque reference,
a quantity, a unit and a time. It contains no medication name. The mapping screen displays
names from Health locally. Evidence for issue 702 records no real health details.

### Revocation and the Health app's own changes

The person can change authorization in the Health app at any time. On each foreground the
client re-queries the authorized medications and compares to its mappings:

- A mapped medication that no longer appears marks the mapping *locally unavailable* and
  asks the person to re-grant. It sends **nothing** to the server — in particular no
  deletion — because losing read access is not the same as the dose not having happened.
- A newly authorized medication with no mapping appears as "needs mapping" in the screen;
  nothing books.

Whether revocation surfaces as `HKDeletedObject`s in an anchored query is unknown, and it
matters: if it does, a naive sender would restore stock for every dose. The sender
therefore treats a **burst** of deletions coinciding with a medication vanishing from the
authorized list as revocation, not as deletion, and holds them. This is conservative by
design; the spike confirms or removes the need.

### Pairing with the Siri concept

Orthogonal. Each household member's phone holds *their own* API key, so events book as
their own Victual user (ADR-0041 "imported events book as the authenticated user").
The app-intents work in `docs/concepts/siri-and-app-intents.md` neither depends on this nor
blocks it. One interaction to watch: the expiring-API-key problem in that concept applies
here harder, because sync fails *silently* when the key lapses. The sync status screen
shows "last synced" and an unmistakable failure state, so a 401 is not a quiet outage.

## Server feedback

What the Victual core API needs, in the order it blocks this client. These are for the
maintainer; no comment has been posted to #702, #696 or #711 — that needs authorization.

1. **Deletion is not un-consumption.** ADR-0041 rule 7 makes `DELETE` void the event and
   *restore stock*. That is right for "I logged a dose by mistake" and wrong for "I cleared
   my Health history", "I removed an archived medication", or — if the device shows it —
   "I revoked access". Those are not un-swallowed pills. Ask for either a `reason` on
   `DELETE` (`source_deleted` vs `access_revoked`), or a server policy: deletions older
   than N days, or for a transaction already reconciled or linked, go to `needs_review`
   instead of `voided`. The real un-taken signal in HealthKit is `notLogged`, not deletion.
2. **Status vocabulary.** HealthKit has six statuses; the ADR names four. Add `not_logged`
   ("the person undid a previous status"), or document the mapping in the ADR so every
   client does not invent one. Until then this client sends `unanswered`.
3. **`source_updated_at` is required, but HealthKit samples are immutable.** An edit is a
   new uuid and `HKObject` exposes no modification time. Make it optional for such
   sources, or define it as "the client's observation time" so a replay of the same sample
   carries a *different* value and trips `same_version_different_payload` (409) for no
   reason. A replay must reuse the original value; the outbox stores it. State this.
4. **`medication_ref` character set and length.** It sits in a URL path. Give it a pattern
   (the ADR gives `source_event_id` one). `HKHealthConceptIdentifier` has no string form, so
   the proposal above hex-encodes a hash; the server should accept `^[A-Za-z0-9._:-]{1,128}$`.
5. **`quantity` when HealthKit has none.** `doseQuantity` is optional. Say whether a
   mapping can hold a default quantity, or the event goes to `needs_review`
   (`missing_quantity`). The client will not invent one.
6. **Unit matching is by exact string.** `unit_label` mismatches give `unit_mismatch`. What
   Health reports is unverified. Prefer a mapping that *learns* the label from the first
   event the person approves, or lists acceptable labels, over one the person has to type
   to match a string they cannot see.
7. **Data the mapping screen needs, which the contract does not yet provide.** (a) The
   product's available unit conversions, to offer only valid units, so a 422
   `invalid_mapping` is the exception; (b) which locations hold stock of a product, for the
   `fixed`/`single` choice; (c) a way to ask "does this server support consumption events"
   other than guessing from the version string — an entry in `GET /system/info` or
   `GET /user/capabilities`. Check which already exist before asking.
8. **OpenAPI.** The ADR-0041 fragment is a `.devtools` design file and is not in
   `victual.openapi.json` until #700. This package generates its client from that spec, so
   nothing is generated until then; see [phasing](#phasing).
9. **Dependency edge to flag on #702.** Acceptance criterion 3 calls for "revoked access"
   handling. That is meaningful only if the contract distinguishes revocation from
   deletion — which is item 1.

## Phasing

The order is chosen so nothing is built on an unverified assumption longer than necessary.

### Phase 0 — device spike

A debug-only screen in the phone app that authorizes medications, runs the anchored
query, and shows what arrives, **locally, with no network**. It records, for the
[acceptance contract](#verification): iOS version and device, which fields are non-nil,
`doseQuantity` and `unit.unitString` for a tablet, a liquid and a single-use item,
what an edit emits (delete + new uuid, or an in-place change), what undo-in-Health emits
(`notLogged` new sample or deletion), late-logged latency, whether the
`medicationConceptIdentifier` is stable across launches and archives deterministically,
background-delivery behavior, and what revoking a medication emits. Result: a table pasted
into [Executed](#executed) and a go/no-go on items in [Open questions](#open-questions).

Needs a physical iPhone on iOS 26+ with medications entered in Health. The household
phones are iPhone 16s on iOS 27. The simulator is not used; it has no medication data.

### Phase 1 — model, sync engine and tests (no server, no HealthKit import)

`VictualHealth` model target; `DoseEventSource` and `ConsumptionEventSubmitter` protocols;
hand-written `Codable` request/response types matching ADR-0041; the outbox, anchor and
ledger; status translation; the `replaces` heuristic; revocation holding. Unit tests
against scripted sources and a fake submitter, covering the client half of the 17
sequences. Hand-written types are deliberate: the specification does not contain them yet,
and they are replaced, not wrapped, when it does.

### Phase 2 — phone UI

A Medications screen under Settings: choose medications, map each, sync status ("last
synced", failures, held events), and a list of events needing the person. Presentation of
`needs_review` reasons comes from the server's `reason`, unrewritten.

### Phase 3 — against a real server

When Victual #700 lands and 0.5.0 ships: regenerate (`Scripts/` sync), delete the
hand-written types in favour of the generated ones, bump `supportedServerVersion`, add
`ServerVersion.isAtLeast`, run the device scenario.

### Phase 4 — refill notices

Consume the server's refill state (#701) and present local notifications:
approaching, due, corrected fill, no repeat after a retry. Out of this plan until #701
fixes its schema; it appears here so that the work is not forgotten.

## Out of scope, named

Writing anything to HealthKit. Dose reminders and any schedule view. Reading symptoms or any
other Health type. A Mac or Watch front end (HealthKit lists macOS 26 and watchOS 26, but
whether a Mac holds a household's Health data is unverified and not wanted here). Inferring
a product from a medication. App Intents, which stay with the Siri concept.

## Open questions

1. **Does `HKHealthConceptIdentifier` archive deterministically?** If not, the derived
   `medication_ref` changes between launches and every mapping silently breaks. Fallback:
   store the archive bytes with the mapping and send a locally assigned UUID as the ref.
   Phase 0 decides.

2. **Is delete-and-recreate really what an edit looks like, and what does undo look like?**
   The session says edits delete and recreate; `notLogged` exists for undo. Whether undo
   produces a `notLogged` sample, a deletion, or both determines Server feedback 1 and 2.

3. **Is the `replaces` heuristic acceptable, or should the client never send it?** Sending
   it is atomic when right and could void the wrong dose when wrong. The narrow rule above
   (same medication, same scheduled date, schedule type `.schedule`, same batch) is a
   proposal. The alternative is never to send it and accept the brief window of 0 or 2
   deductions the ADR already tolerates.

4. **Where does the outbox live?** The app container, unencrypted beyond file protection,
   holds opaque refs, quantities and times. Is that acceptable for health-adjacent data or
   does it belong in the Keychain/an encrypted store? Needs the maintainer's stance on
   what is sensitive at rest.

5. **Foreground sync only, or background?** Depends on the spike. A person who logs a dose
   in Health and opens Victual later sees stock catch up on open — acceptable for stock,
   not for a refill notice.

6. **Where does the mapping live — server or device?** ADR-0041 puts mappings on the
   server (`PUT /consumption/mappings/...`), which lets a second phone share them. The
   device keeps only a cache. Confirm that two of one person's devices submitting the same
   dose is intended to be one event (ADR rule 1: yes) and that a mapping edited on one
   phone applies to the other.

## Verification

1. `swift test` — Phase 1 suites: status translation, field mapping, outbox ordering and
   crash replay, anchor persistence keyed per server/account, deletion by ledger lookup,
   revocation holding, the `replaces` heuristic positive and negative cases, key lapse
   (401) surfacing as a failure state, and `ServerVersion.isAtLeast`.
2. The macOS application still builds and does not link `VictualHealth`.
3. CI's `phone` job builds with the HealthKit entitlement, on the iOS 26+ SDK.
4. **On a device (cannot be done in CI or the simulator).** Against a Victual 0.5.0
   instance with #700 landed, running the sequences from ADR-0041's native acceptance
   contract. Split by what proves what:

   | ADR-0041 sequence | Server fixture (#700) | Device evidence (#702) | This client's part |
   | --- | --- | --- | --- |
   | 1 taken, no mapping | ✔ | ✔ real payload fields | send once, show "needs mapping" |
   | 2 approve, retry → booked | ✔ | ✔ | mapping screen, one booking |
   | 3 same request twice / parallel | ✔ | | outbox never double-sends after crash |
   | 4 before `effective_from` | ✔ | | device-side filter too |
   | 5 late event | ✔ | ✔ **late-delivery latency** | sends `startDate`, not now |
   | 6–7 edit with/without `replaces` | ✔ | ✔ **identifier behaviour on edit** | heuristic |
   | 8 status → skipped after booked | ✔ | ✔ what Health actually emits | translation table |
   | 9 skipped/unanswered, no row | ✔ | | dropped locally |
   | 10–11 undo in stock, replay | ✔ | | no rebooking; show `undone` |
   | 12–13 manual vs import, link | ✔ | | surface `possible_duplicates` |
   | 14–15 insufficient stock / ambiguous | ✔ | | show `reason` |
   | 16 share revoked (recipe) | ✔ | | show `recipe_unavailable` |
   | 17 other user, same id | ✔ | | key scoped to the signed-in user |
   | *(device-only)* **identifier behaviour on delete** | | ✔ | |
   | *(device-only)* **revocation emission** | | ✔ | holding |
   | *(device-only)* **background delivery** | | ✔ | Open question 5 |

   Evidence records iOS version, device model, real payload field presence, and exact
   client and server commits. No real medication name or dose is committed or posted.

## Executed

Not started. Written 2026-10-09 from the sources named above. The Apple reference pages
were read; no HealthKit code has been compiled or run, and nothing has been exercised on
a device.
