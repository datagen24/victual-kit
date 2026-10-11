# Live-server replay of the ADR-0041 fixtures

This is a third kind of evidence for Victual issue 702. It is neither the server's own fixture run nor evidence from a device. It shows that a deployed Victual instance, reached over HTTP the way a client reaches it, gives the answers the server's fixtures expect. Apple Health produced none of these requests.

Label these results `LIVE-SERVER` in the acceptance matrix. They never fill a `DEVICE` cell.

## What was run

`Scripts/replay-consumption-fixtures.py` reads the server's fixtures from `tests/fixtures/consumption-events/`. For each file it builds a private world (locations, products, purchases) on the instance, replays each step over HTTP, and checks the answer and the stock. Each run uses its own `source_system` and prefix, and it namespaces manual `request_id` values, so reruns do not collide.

The script writes to the instance. Point it at a throwaway one.

## Provenance

| Item | Value |
| --- | --- |
| Date | 2026-10-10 |
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

## Findings

1. **`DELETE` ignores a JSON body on this instance** ([victual#760](https://github.com/datagen24/victual/issues/760)). Fixture 09a, step 7, sends `{"reason": "medication_archived"}` as a JSON body. The instance treated it as an unknown reason and answered `needs_review` / `source_deleted`, with `source_removed_reason` of `unknown`. The same reason sent as a query parameter (`?reason=medication_archived`) works and leaves the event `booked`. The failure is safe, since stock is untouched and a person decides. I reproduced it with a plain request and with a charset in the content type. The server's own in-process test passes, so a proxy or the deployment may drop the body. The victual-kit client sends the reason as a query parameter and is not affected.
2. **A reused manual `request_id` replays another recipe's event** ([victual#761](https://github.com/datagen24/victual/issues/761)). Consuming recipe A and then recipe B with the same `request_id` answered 200 with `replayed: true` for recipe A's event. Nothing was booked for B, and no error says so. Fixtures 12 and 13 reuse one id, which is how it showed. The client generates a fresh UUID per request, so the risk is low. A 409 would be safer.
3. **Concurrency holds.** Twelve simultaneous identical `PUT` requests gave one 201 and eleven 200 responses, and stock fell by exactly one. The fixtures cannot show this, because their steps run in order.

4. **After the patch, a correction books its quantity as several one-tablet lines** (not filed). Fixtures 06 and 09e correct an event from 1 tablet to 2. Before the patch the response and the stored event showed one line of amount 2. After it, they show two lines of amount 1. Stock is correct in both cases: 8 tablets remain from 10, so two were taken. A direct create of 2 or 3 tablets, and a recipe line of 2, still give one line. So the change is confined to the undo-and-rebook path. It looks like the revived stock row from the undone booking is no longer merged, and the new booking draws from two rows. A client that sums line amounts is unaffected. A client that counts lines would see two. Whether this is intended is for the server maintainer.

## Not covered

- A second user without `ADMIN`. Rows 16 and 17 ran with two admins.
- Whether the patch itself is correct. The run only shows what changed in the fixtures' answers.
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
