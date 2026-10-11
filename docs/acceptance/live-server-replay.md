# Live-server replay of the ADR-0041 fixtures

This is a third kind of evidence for Victual issue 702. It is neither the server's own fixture run nor evidence from a device. It shows that a deployed Victual instance, reached over HTTP the way a client reaches it, gives the answers the server's fixtures expect. Apple Health produced none of these requests.

Label these results `LIVE-SERVER` in the acceptance matrix. They never fill a `DEVICE` cell.

## What was run

`Scripts/replay-consumption-fixtures.py` reads the server's fixtures from `tests/fixtures/consumption-events/`. For each file it builds a private world (locations, products, purchases) on the instance, replays each step over HTTP, and checks the answer and the stock. Each run uses its own `source_system` and prefix, and it namespaces manual `request_id` values, so reruns do not collide.

The script writes to the instance. Point it at a throwaway one.

## Provenance

| Item | Value |
| --- | --- |
| Date | 2026-10-10 (runs 1 to 3), 2026-10-11 (run 4) |
| Server | Victual 0.3.2 (release date 2026-10-08), PostgreSQL 16, database version 307 |
| Server identity | `/api/system/info` reports no commit, so the served OpenAPI document identifies the build |
| Served spec sha256 | `8f2f619a8383a52583ab8c596761a4e2592d6877b5c62eaf2b9a73796084827f` |
| Vendored spec | upstream `d62efe9`, sha256 `e7468093452df3d5333388433660981c53440487095355c72c322b270cf9b1b8` |
| Difference | Five `ExposedEntity_*` enums, which an instance fills in at runtime. No path or other schema differs |
| Fixtures | `tests/fixtures/consumption-events/`, last changed at server commit `d62efe9` |
| Capabilities | contract version 1: events, mappings, batch, bulk_resolve, manual_consume, deletion_reasons, not_logged, default_quantity, unit_labels, replaces, refill, refill_notices |
| Key | An ADMIN key on a throwaway development instance |

## Results: before and after a server patch

The first runs (24 fixtures, then fixtures 16 and 17 with a second user) used the build described above. A patch was then applied to the same instance for a user-creation regression. The version string stayed 0.3.2 and database version 307, and the served OpenAPI document is byte-identical (same sha256). The whole set was rerun.

| Fixture | ADR row | Before the patch | After the patch | Steps |
| --- | --- | --- | --- | --- |
| 00 | capabilities | pass | pass | 1 |
| 01 | 01 | pass | pass | 3 |
| 02 | 02 | pass | pass | 4 |
| 03 | 3 (sequential repeat) | pass | pass | 4 |
| 04 | 04 | pass | pass | 4 |
| 05 | 05 | pass | pass | 4 |
| 06 | 06 | pass | **fail** (finding 4) | 5 |
| 07a | 7, delete then create | pass | pass | 4 |
| 07b | 7, create then delete | pass | pass | 5 |
| 08 | 08 | pass | pass | 7 |
| 09 | 09 | pass | pass | 7 |
| 09a | 09a | fail | **fail** (finding 1) | 7 |
| 09b | 09b | pass | pass | 10 |
| 09c | 09c | pass | pass | 6 |
| 09d | 09d | pass | pass | 6 |
| 09e | 09e | pass | **fail** (finding 4) | 8 |
| 09f | 09f | pass | pass | 12 |
| 09g | 09g | pass | pass | 11 |
| 10 | 10 | pass | pass | 7 |
| 11 | 11 | pass | pass | 7 |
| 12 | 12 | pass | pass | 7 |
| 13 | 13 | pass | pass | 5 |
| 14 | 14 | pass | pass | 5 |
| 15 | 15 | pass | pass | 6 |
| 16 | 16 | pass | pass | 7 |
| 17 | 17 | pass | pass | 10 |

Before the patch: 25 pass, 1 fail. After the patch: 23 pass, 3 fail.

Fixtures 16 and 17 need a second user with an API key of their own. The API has no route that creates a key for another user, so a second admin user was created and its key supplied as `VICTUAL_DEV_KEY_BOB`. Both rows first ran in a second run on the same build, after the first 24.

Both actors are `ADMIN`. The two rows therefore show the sharing and isolation behavior for admins and do not show that a narrower role is refused.

## Run 4: Victual 0.4.0

The instance was then upgraded to the `v0.4.0` release (tag commit `f73d2bec`, `/api/system/info` release date 2026-10-10, database version 307). The server's fixtures were taken from that tag, which has 28 files: the 26 above plus `18-manual-request-conflict.json` and `19-correction-split-lines.json`. The test data on the instance was kept.

The served OpenAPI document has the same paths as the spec vendored from the tag, and differs only in the five runtime `ExposedEntity_*` enums. Its sha256 is `0f171a90b4e5e73066aeac1dc0f79b6efc1cb6110fe879a6aa33411bdaeeea0a`. The vendored spec is upstream `89cea94`, sha256 `e0b8cc5de387a97e160afb8be770a7aaa90662cea467b208467562ef08905442`.

Result: **28 pass, 0 fail.** Both actors are `ADMIN`, as before. A later run of 16 and 17 with a non-admin second user is under Run 6.

| Fixture | ADR row | Result | Steps |
| --- | --- | --- | --- |
| 00 | appendix (no table row) | pass | 1 |
| 01 | 1 | pass | 3 |
| 02 | 2 | pass | 4 |
| 03 | 3 (sequential repeat) | pass | 4 |
| 04 | 4 | pass | 4 |
| 05 | 5 | pass | 4 |
| 06 | 6 | pass | 5 |
| 07a | 7 (delete then create) | pass | 4 |
| 07b | 7 (create then delete) | pass | 5 |
| 08 | 8 | pass | 7 |
| 09 | 9 | pass | 7 |
| 09a | 9a | pass | 7 |
| 09b | 9b | pass | 10 |
| 09c | 9c | pass | 6 |
| 09d | 9d | pass | 6 |
| 09e | 9e | pass | 8 |
| 09f | 9f | pass | 12 |
| 09g | 9g | pass | 11 |
| 10 | 10 | pass | 7 |
| 11 | 11 | pass | 7 |
| 12 | 12 | pass | 7 |
| 13 | 13 | pass | 5 |
| 14 | 14 | pass | 5 |
| 15 | 15 | pass | 6 |
| 16 | 16 | pass | 7 |
| 17 | 17 | pass | 10 |
| 18 | manual-idempotency | pass | 5 |
| 19 | 6-split-lines | pass | 4 |

My separate probes also agree. Twelve simultaneous identical `PUT` requests give one 201 and eleven 200 responses, with stock down by one. Reusing a manual `request_id` on another recipe now answers 409 `request_id_conflict` and books nothing.

## Run 5: refill fixtures on Victual 0.4.0

The server also ships refill fixtures (`tests/fixtures/consumption-refill/`, last changed at `d62efe98`, 11 files). The runner builds each fixture's recipes, owners and shares, replays the steps over HTTP, and sends each read with its own `as_of`, as the fixtures do. Only the stock check is absent, because these fixtures have none.

Result: **11 pass, 0 fail.**

| Fixture | What it shows | Result | Steps |
| --- | --- | --- | --- |
| 01 | A 30-day fill: the estimate is 16 days after the fill, with its warning and due days | pass | 7 |
| 02 | A 90-day fill: 76 days after the fill, and the boundaries around the warning and reorder d | pass | 11 |
| 03 | Explicit date, then the medication-specific rule, then the fallback | pass | 9 |
| 04 | A short or unknown supply gives an unknown estimate, never an invented date | pass | 11 |
| 05 | An order changes the status; receiving it records the fill and closes the order | pass | 7 |
| 06 | Cancelling an order restores the status the fills and rules say | pass | 4 |
| 07 | Voiding and re-recording an identical fill keeps the notice key; a changed date makes a ne | pass | 9 |
| 08 | A newer fill ends an explicit date for good; voiding the newer fill does not bring it back | pass | 4 |
| 09 | Notices: approaching, then due; per-user acknowledgement; an open order raises none | pass | 14 |
| 10 | The client's calendar date decides the status; without one the server says it used the UTC | pass | 7 |
| 11 | Refill data follows the recipe's shares; a hidden recipe is absent, not forbidden | pass | 13 |

Fixtures 09 and 11 first ran blocked, for want of a third user. They then ran with three users who hold different roles: `alice` is an `ADMIN` (she owns the setup and holds more than the fixtures need), `bob` has the built-in `CHILD` role (14 permissions, including `STOCK_VIEW`, no `STOCK_EDIT`) and `carol` has the built-in `ADULT` role. Fixture 11 is about who can read and who can edit, so it needed users who are not admins, and it passes with them.

The refill list and notices cover every recipe a user owns on the shared instance. The runner keeps only the recipes of the fixture being run, so earlier fixtures and earlier runs do not change the counts.

These rows show the server's answers, including provenance, the approaching and due boundaries, corrected fills with the same and a changed notice key, and the client's `as_of` date. They say nothing about a client reading the notices, scheduling a local notification, or opening the right screen.

## Run 6: non-admin users

The `ADULT` role was assigned to the `Adult-Test` user and `CHILD` to `Child-Test`, using the admin key, and each user's key was used for its own requests. The role assignment is a change to the instance, not a result of the fixtures.

Fixtures 16 and 17 (recipe share revoked, same `source_event_id` from another user) were rerun with `bob` as the `ADULT` user: both pass. This removes the earlier caveat that those rows showed behavior for admins only. The event fixtures were not otherwise rerun in this run.

## Findings

Findings 1, 2 and 4 are resolved in 0.4.0, see Run 4. Finding 4 was resolved by documenting the behavior, not by restoring one line.

1. **`DELETE` ignores a JSON body on this instance** ([victual#760](https://github.com/datagen24/victual/issues/760)). Fixture 09a, step 7, sends `{"reason": "medication_archived"}` as a JSON body. The instance treated it as an unknown reason and answered `needs_review` / `source_deleted`, with `source_removed_reason` of `unknown`. The same reason sent as a query parameter (`?reason=medication_archived`) works and leaves the event `booked`. The failure is safe, since stock is untouched and a person decides. I reproduced it with a plain request and with a charset in the content type. The server's own in-process test passes, so a proxy or the deployment may drop the body. The victual-kit client sends the reason as a query parameter and is not affected.
2. **A reused manual `request_id` replays another recipe's event** ([victual#761](https://github.com/datagen24/victual/issues/761)). Consuming recipe A and then recipe B with the same `request_id` answered 200 with `replayed: true` for recipe A's event. Nothing was booked for B, and no error says so. Fixtures 12 and 13 reuse one id, which is how it showed. The client generates a fresh UUID per request, so the risk is low. A 409 would be safer.
3. **Concurrency holds.** Twelve simultaneous identical `PUT` requests gave one 201 and eleven 200 responses, and stock fell by exactly one. The fixtures cannot show this, because their steps run in order.

4. **After the patch, a correction books its quantity as several one-tablet lines** ([victual#763](https://github.com/datagen24/victual/issues/763)). Fixtures 06 and 09e correct an event from 1 tablet to 2. Before the patch the response and the stored event showed one line of amount 2. After it, they show two lines of amount 1. Stock is correct in both cases: 8 tablets remain from 10, so two were taken. A direct create of 2 or 3 tablets, and a recipe line of 2, still give one line. So the change is confined to the undo-and-rebook path. It looks like the revived stock row from the undone booking is no longer merged, and the new booking draws from two rows. A client that sums line amounts is unaffected. A client that counts lines would see two. Whether this is intended is for the server maintainer.

## Not covered

- Whether the patch itself is correct. The run only shows what changed in the fixtures' answers.
- A client that counts `lines`. On 0.4.0 the server documents `lines` as stock-log allocations, one per entry, so a correction can list several lines for one product. victual-kit only decodes `lines` and does not count them.
- Anything a device produces: real payload fields, identifier behavior on edit, late delivery, revocation.
- The refill routes. The instance has no refill data, and the fixtures do not cover them.
- Bulk-resolution behavior beyond what fixtures 09f and 09g check.

## Reproducing

```
export VICTUAL_DEV_URL=http://HOST
export VICTUAL_DEV_KEY=...            # a key on a throwaway instance
Scripts/replay-consumption-fixtures.py PATH/TO/victual/tests/fixtures/consumption-events
```

Add `--only 02,09b` to run some fixtures, or `--report out.json` for the full record.
