# Plan 22 native acceptance matrix (victual#702)

The native half of Victual plan 22: medication dose sync from Apple Health (ADR-0041) and
refill notices (ADR-0042), as this client implements them. One block per scenario; each
block has the rows that exist for it, and a `DEVICE` row that says `NOT RUN` until the
maintainer runs it. **Nothing in this file claims a device or a server accepted anything.**
A `UNIT` or `FIXTURE` result means a test in this repository passed against this client's own
fakes and recorded payloads, not that a real server or a real Health store behaved that way.

**Provisional.** The specification is vendored from Victual master while
[victual#701](https://github.com/datagen24/victual/issues/701) is open. Re-run
`Scripts/update-openapi.py` for the final handoff and update the commit and hash below.

| | |
| --- | --- |
| Client commit | `2730530` (branch `claude/healthkit-refills`, on `claude/healthkit-phase3`) |
| Server commit | Victual master `6ec4173` (the spec file last changed in `d62efe9`) |
| Spec sha256 | `e7468093452df3d5333388433660981c53440487095355c72c322b270cf9b1b8` (`openapi/spec-lock.json`) |
| Spec `info.version` | 0.3.2 |
| Client test run | `swift test`, 2026-10-10: all five test targets passed (16, 61, 137, 116 and 8 tests) |

Evidence kinds: `FIXTURE` (a recorded payload decoded), `UNIT` (a test against fakes),
`SIMULATOR-BUILD` (compiles and links for iOS; no simulator is booted), `DEVICE` (a physical
iPhone against a real server). Test names are `Suite.test` in `Tests/VictualHealthTests/`
unless a path is given. Observations contain no medication name, nickname or real health detail.

## Rows

| # | Scenario | How to reproduce | Evidence | Result | Sanitized observation | Client commit | Server commit + spec sha256 | Link |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1.U | Explicit medication selection and per-medication authorization | `swift test --filter MedicationSetupStoreTests` | UNIT | PASS | No item is mapped until the person maps it; archived items are separate; nothing is inferred from a name (`everyItemStartsUnsettledAndNothingIsGuessed`, `archivedMedicationsAreSeparateAndNotOnTheWizardList`, `aSavedMappingNeverCarriesAName`) | `2730530` | n/a (client only) | [tests](../../Tests/VictualHealthTests/MedicationSetupTests.swift) |
| 1.S | The authorization request is read-only and per object | `xcodebuild -project Apps/VictualPhone/VictualPhone.xcodeproj -scheme VictualPhone -destination generic/platform=iOS build CODE_SIGNING_ALLOWED=NO` | SIMULATOR-BUILD | BUILD SUCCEEDED (Debug and Release, 2026-10-10) | `requestPerObjectReadAuthorization(for: userAnnotatedMedicationType(), predicate: nil)` compiles; no `toShare` | `2730530` | n/a | [source](../../Sources/VictualHealth/HealthKitDoseSource.swift) |
| 1.D | Choose medications in Health, grant one, revoke one | Spike steps 1 and 8 in [Apps/VictualPhone/README.md](../../Apps/VictualPhone/README.md#healthkit-device-spike-debug-builds) | DEVICE | NOT RUN | | | | |
| 2.U | Approved product and unit mapping; organizer source (`fixed`, `single`, `explicit`); default quantity | `swift test --filter MappingWireTests` | UNIT | PASS | Draft names each missing choice; `qu_id` absent for the stock unit; only `fixed` stores an organizer (the server refuses `location_id` for `single` and `explicit`); default quantity must be above zero (`eachMissingChoiceIsNamed`, `onlyFixedStoresAnOrganizer`, `theStockUnitIsSentAsNoUnit`, `editingRestoresTheStoredUnit`, `aProductDraftEncodesTheFragmentsKeys`) | `2730530` | `6ec4173`, `e7468093…b1b8` | [tests](../../Tests/VictualHealthTests/MedicationSetupTests.swift) |
| 2.U2 | Missing quantity is omitted, never invented | `swift test --filter DoseSyncEngineTests` | UNIT | PASS | `nilQuantityIsOmittedFromTheBody`; `WireContractTests.nilQuantityIsOmittedNotNull` | `2730530` | `6ec4173`, `e7468093…b1b8` | [tests](../../Tests/VictualHealthTests/DoseSyncEngineTests.swift) |
| 2.U3 | Unit-label approval shows the exact string | `swift test --filter MedicationSyncStoreTests` | UNIT | PASS | `unitUnconfirmedShowsTheExactStringAndApprovalResolvesIt` | `2730530` | `6ec4173`, `e7468093…b1b8` | [tests](../../Tests/VictualHealthTests/MedicationSyncStoreTests.swift) |
| 2.F | The ADR examples decode through the generated event type | `swift test --filter WireContractTests` | FIXTURE | PASS | `adrExamplesDecode`, `adrExamplesAdaptFromTheGeneratedType` | `2730530` | `6ec4173`, `e7468093…b1b8` | [fixture](../../Tests/VictualHealthTests/Fixtures/adr-examples.json) |
| 2.D | Map one item, log a dose with no quantity, approve the unit string Health reports, observe one booking | Phone: Settings > Medications; then the Health app | DEVICE | NOT RUN | | | | |
| 3.U | A taken event deducts once across retries and offline sync | `swift test --filter DoseSyncEngineTests` | UNIT | PASS | The client's half: `crashBeforeTheAnchorAdvancesReplaysWithoutDuplicatingOrChangingBytes`, `crashAfterSendingBeforeRemovalResendsIdenticalBytes`, `redeliveredBatchAfterSendingIsANoOp`, `outboxSendsInOrderAndStopsAtARetryableFailure`, `VictualConsumptionServiceTests.aPutSendsExactlyTheStoredBytes`; identity is in the path, bytes are stored | `2730530` | `6ec4173`, `e7468093…b1b8` | [tests](../../Tests/VictualHealthTests/DoseSyncEngineTests.swift) |
| 3.D | Airplane-mode dose, reconnect, retry; stock falls once | Log a dose offline, reconnect, sync twice; read stock | DEVICE | NOT RUN | | | | |
| 4.U | Late events, anchored queries, deletion and recreation, the `replaces` pairing | `swift test --filter DoseSyncEngineTests` | UNIT | PASS | `lateDoseCarriesItsOwnStartDate`, `scheduledEditInOneBatchSendsReplaces`, `asNeededEditNeverSendsReplaces`, `nilScheduledDateNeverSendsReplaces`, `differentScheduledDateOrMedicationNeverSendsReplaces`, `deleteAndRecreateInSeparateBatchesNeverSendsReplaces`, `twoCandidatesAreAmbiguousAndNotPaired`, `anchorsDoNotCrossServersAccountsOrMappingSets` | `2730530` | `6ec4173`, `e7468093…b1b8` | [tests](../../Tests/VictualHealthTests/DoseSyncEngineTests.swift) |
| 4.D | Edit a logged dose; log a dose for an earlier time; record what Health emits and when | Spike step 4 | DEVICE | NOT RUN | | | | |
| 5.U | An unknown deletion reason enters review; clearing history or losing access never restores stock | `swift test --filter DoseSyncEngineTests` and `MedicationSyncStoreTests` | UNIT | PASS | The client never sends `entered_in_error`, `history_cleared` or `unknown` (`neverSendsEnteredInErrorOrHistoryClearedOrUnknown`); a bare deletion carries no reason (`bareDeletionOfActiveMedicationOmitsTheReason`); a burst is one row (`aBurstOfBareDeletionsIsOneRow`) decided with one bulk request (`VictualConsumptionServiceTests.bulkResolveIsOneRequestPer50AndReportsEachEvent`). That stock stays consumed is the server's rule and is not shown by these tests | `2730530` | `6ec4173`, `e7468093…b1b8` | [tests](../../Tests/VictualHealthTests/DoseSyncEngineTests.swift) |
| 5.D | Delete a logged dose; clear history; stop sharing a medication; read stock and the review list | Spike steps 4 and 8, then Settings > Medications | DEVICE | NOT RUN | | | | |
| 6.U | Skipped, unanswered and scheduled-only events cause no deduction | `swift test --filter DoseSyncEngineTests`, `MappingAndStatusTests` | UNIT | PASS | `nonTakenForADoseNeverSentIsDropped(status:)` (every non-taken status); `everyHealthStatusTranslates` (only `taken` books) | `2730530` | `6ec4173`, `e7468093…b1b8` | [tests](../../Tests/VictualHealthTests/MappingAndStatusTests.swift) |
| 6.D | Skip a dose, ignore a reminder, snooze one; confirm no event and no stock change | Health app | DEVICE | NOT RUN | | | | |
| 7.U | Manual and imported events are linked, not rebooked; a direct-stock undo is not silently rebooked | `swift test --filter MedicationSyncStoreTests` and `DoseSyncEngineTests` | UNIT | PASS | The client surfaces `possible_duplicates` (`possibleDuplicatesAreSurfaced`), keeps an undone event undone across syncs (`undoneEventStaysUndoneAcrossSyncs`) and never re-sends it (`undoneEventIsNeverRebookedByReplay`). Linking itself is server behaviour | `2730530` | `6ec4173`, `e7468093…b1b8` | [tests](../../Tests/VictualHealthTests/MedicationSyncStoreTests.swift) |
| 7.D | Book by hand, then log the same dose in Health; undo in stock; sync again | Phone and web UI | DEVICE | NOT RUN | | | | |
| 8.U | Conditional `undo_refused` (bookings sharing a purchase) is shown as the server sent it | `swift test --filter MedicationSyncStoreTests` | UNIT | PASS | `otherReasonsAreShownAsTheServerSentThem(reason:)` runs for every review reason, `undo_refused` and `stock_error` included | `2730530` | `6ec4173`, `e7468093…b1b8` | [tests](../../Tests/VictualHealthTests/MedicationSyncStoreTests.swift) |
| 8.D | Two bookings sharing a purchase; undo one; read the reason | Web UI and phone | DEVICE | NOT RUN | | | | |
| 9.U | Refill provenance, `as_of` dates, approaching and due boundaries | `swift test --filter RefillStoreTests` | UNIT | PASS | `theClientsLocalDateIsWhatIsSent`, `statusFlipsAtLocalMidnightNotUTCMidnight`, `approachingAndDueBoundaries(local:expected:)` (six days around the date), `countdownWordsFollowTheSameArithmetic`, `provenanceIsStatedForEveryKindOfDate`; `CalendarDayTests.theLocalDayIsNotTheUTCDay`, `aDaylightSavingNightStillHasOneDayChange`. The status in these tests is computed by a stand-in for the server's rule (ADR-0042 §4), so they show the client sends and shows the right day, not that the server computes it so | `2730530` | `6ec4173`, `e7468093…b1b8` | [tests](../../Tests/VictualHealthTests/RefillTests.swift) |
| 9.U2 | Corrected fills, acknowledgement, repeat suppression | `swift test --filter RefillStoreTests` | UNIT | PASS | `aCorrectedFillShowsWhatTheDateChangedFrom`, `aCorrectedDateIsANewNoticeAndTheOldOneIsTakenDown`, `aRaisedNoticePostsOnceAndNeverAgainAcrossRetriesAndRelaunch`, `anAcknowledgementIsRetriedUntilTheServerConfirmsAndNeverRepostsMeanwhile`, `aKeyTheServerNoLongerKnowsEndsTheRetry`, `anOrderOrAcknowledgementElsewhereTakesTheNotificationDown` | `2730530` | `6ec4173`, `e7468093…b1b8` | [tests](../../Tests/VictualHealthTests/RefillTests.swift) |
| 9.U3 | Wire shapes of the refill routes | `swift test --filter RefillWireTests` | UNIT | PASS | `as_of` goes out as the local date; `current_fill` and `open_order` are kept; a malformed notice key is refused; voided fills are marked | `2730530` | `6ec4173`, `e7468093…b1b8` | [tests](../../Tests/VictualHealthTests/RefillTests.swift) |
| 9.D | Refill with a 30-day and a 90-day fill; cross local midnight; acknowledge on one phone and see it clear on another | Web UI to record fills; phone to read | DEVICE | NOT RUN | | | | |
| 10.U | Revocation removes private access and suppresses stale private presentation | `swift test --filter RefillStoreTests` | UNIT | PASS | `aRefusedCallerLosesEverythingPrivate`, `aRevokedKeyOnTheCapabilitiesCallDoesTheSame`, `aPrescriptionThatDisappearsLosesItsNotifications`, `signingOutErasesState`; `noNotificationTextNamesAnything` (no name, not even a date). Medication side: `deletionOfARevokedMedicationSaysAccessRevoked`, `revokedMedicationIsMarkedUnavailable` | `2730530` | `6ec4173`, `e7468093…b1b8` | [tests](../../Tests/VictualHealthTests/RefillTests.swift) |
| 10.S | Disconnect and server change revoke; the Refills screen blurs when the app is not in front | `xcodebuild … build` as in 1.S | SIMULATOR-BUILD | BUILD SUCCEEDED (the blur and the disconnect hook compile; neither is exercised) | | `2730530` | n/a | [RootView](../../Apps/VictualPhone/Sources/RootView.swift) |
| 10.D | Remove the key on the server, share then unshare a prescription, sign out; check the lock screen and the app switcher | Web UI and phone | DEVICE | NOT RUN | | | | |
| 11.U | The Medications and Refills entries are gated on `features[]`, never on a version | `swift test --filter MedicationSyncStoreTests` and `RefillStoreTests` | UNIT | PASS | `olderServerHidesMedicationsWithAReason`, `missingFeatureNamesWhatIsMissing`, `theScreenIsGatedOnFeaturesNotVersions`, `WireContractTests.requiredFeaturesAreNamesTheSpecDefines`, `capabilitiesToleratesFeaturesItDoesNotKnow` | `2730530` | `6ec4173`, `e7468093…b1b8` | [tests](../../Tests/VictualHealthTests/WireContractTests.swift) |

## Spike report

Paste the output of **Settings > Debug > HealthKit spike > Share report** here. It has no
medication names, no nicknames, and times to the minute only. Fill the fields before it.

| Field | Value |
| --- | --- |
| iOS version | |
| Device model (hardware identifier) | |
| Build (Debug) and client commit | |
| Server version and commit | |
| Date of the run | |

```text
(not run)
```

The report answers these Phase 0 questions of plan 03:

- Which fields are non-nil.
- What `doseQuantity` and the unit string are for a tablet, a liquid and a single-use item.
- Whether an edit emits a deletion and a new uuid, or changes in place.
- Whether undo emits a `notLogged` sample, a deletion, or both.
- The delivery latency for a dose logged now.
- Whether the `description` or the hashed `medication_ref` is stable across launches.
- What revoking one medication emits.
- Whether background delivery is accepted.

## Differences found between the records and the schema

Reported, not worked around.

1. **`location_id` is refused for `single` and `explicit`.** ADR-0041 says an `explicit`
   mapping means "each event carries `location_id`", and plan 03 had the mapping hold an
   organizer for it. The schema allows `location_id` only for `fixed`. This client cannot name
   a per-dose organizer, so it does not offer `explicit`.
2. **The feature names are not in ADR-0041's prose.** The schema lists `refill` and
   `refill_notices` beside the ADR's ten names; the ADR text lists only the ten.
3. **`supplied_days` is nullable in the schema.** ADR-0042 §1 says it is entered for each fill
   and is 1 to 730; `RefillCurrentFill.supplied_days` and `RefillFill.supplied_days` are
   `integer | null`. The client shows "Days supplied not recorded".
4. **The generator drops `current_fill` and `open_order`.** `oneOf: [$ref, null]` is not
   supported, so the generated `RefillState` lacks the two fields the screen needs. The client
   decodes refills by hand.
5. **Closed enums.** A generated `@frozen` enum fails on a value a newer server adds, so
   capabilities and mappings are hand-written, and an unknown event state or reason surfaces as
   a failed sync.
6. **Info version.** `info.version` is still 0.3.2 while the spec adds routes. No version in
   this repository moved; the client gates on `GET /consumption/capabilities`.
