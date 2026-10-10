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

## Result: 23 pass, 1 fail, 2 blocked

| Fixture | ADR row | Result | Steps |
| --- | --- | --- | --- |
| 00 | capabilities | pass | 1 |
| 01 | 1 | pass | 3 |
| 02 | 2 | pass | 4 |
| 03 | 3 (sequential repeat) | pass | 4 |
| 04 | 4 | pass | 4 |
| 05 | 5 | pass | 4 |
| 06 | 6 | pass | 5 |
| 07a | 7, delete then create | pass | 4 |
| 07b | 7, create then delete | pass | 5 |
| 08 | 8 | pass | 7 |
| 09 | 9 | pass | 7 |
| 09a | 9a | **fail**, see finding 1 | 7 |
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
| 16 | 16 | **blocked** | 0 |
| 17 | 17 | **blocked** | 0 |

Rows 16 and 17 need a second user with an API key of their own. The API has no route that creates a key for another user, so they stay open until someone supplies one as `VICTUAL_DEV_KEY_BOB`.

## Findings

1. **`DELETE` ignores a JSON body on this instance.** Fixture 09a, step 7, sends `{"reason": "medication_archived"}` as a JSON body. The instance treated it as an unknown reason and answered `needs_review` / `source_deleted`, with `source_removed_reason` of `unknown`. The same reason sent as a query parameter (`?reason=medication_archived`) works and leaves the event `booked`. The failure is safe, since stock is untouched and a person decides. I reproduced it with a plain request and with a charset in the content type. The server's own in-process test passes, so a proxy or the deployment may drop the body. The victual-kit client sends the reason as a query parameter and is not affected.
2. **A reused manual `request_id` replays another recipe's event.** Consuming recipe A and then recipe B with the same `request_id` answered 200 with `replayed: true` for recipe A's event. Nothing was booked for B, and no error says so. Fixtures 12 and 13 reuse one id, which is how it showed. The client generates a fresh UUID per request, so the risk is low. A 409 would be safer.
3. **Concurrency holds.** Twelve simultaneous identical `PUT` requests gave one 201 and eleven 200 responses, and stock fell by exactly one. The fixtures cannot show this, because their steps run in order.

## Not covered

- Rows 16 and 17 (second user).
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
