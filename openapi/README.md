# Tracking the OpenAPI specification

`VictualAPI` is generated from Victual's own OpenAPI document. This directory holds the
vendored copy and the record of which upstream revision it came from.
`Scripts/update-openapi.py` is the only thing that writes to it:

```sh
Scripts/update-openapi.py            # fetch upstream, normalize, write, re-lock
Scripts/update-openapi.py --offline  # re-normalize the vendored copy
Scripts/update-openapi.py --check    # CI: fail if the artifacts are stale
```

| Path | What it is |
| --- | --- |
| `openapi/upstream/victual.openapi.json` | The upstream document, byte for byte. |
| `openapi/spec-lock.json` | Upstream commit, both checksums, and a report of every normalization applied. |
| `openapi/operation-ids.json` | Optional nicer names for individual operations. |
| `Sources/VictualAPI/openapi.json` | The normalized document the generator reads. Never edit by hand. |

CI runs `--check` on every pull request and weekly on a schedule, so an upstream change
surfaces as a failing job rather than as drift. The pinned revision is upstream commit
`38445d4`, the Victual **0.2.0-MVP** release.

## What the normalizer fixes, and why

Victual's document is generated from Slim/PHP routes and did not load in
swift-openapi-generator as published.

As of 0.2.0-MVP only repair 2 and repair 6 still change anything. The sync report in
`spec-lock.json` shows every other count at zero, because upstream now publishes those
shapes correctly. The repairs stay in the script, and `Tests/VictualAPITests` keeps
asserting the shapes they produced. A repair that is a no-op today guards against the same
defect returning.

1. **Slim route constraints in path templates.** Three routes are written
   `/labels/{kind:location|product|…}/{id:[0-9]+}/print`. That is not legal
   OpenAPI path templating; the constraint is already in the parameter's schema,
   so the suffix is stripped.
2. **No `operationId` anywhere.** All 145 operations would otherwise be named
   things like `get_sol_stock_sol_products_sol__lcub_productId_rcub_`. Names are
   derived deterministically from the route
   (`getStockProductsByProductIdPriceHistory`), with a collision check, and can
   be overridden per route in `operation-ids.json`.
3. **Five dangling `$ref`s.** The `entity` path parameter pointed at
   `ExposedEntity_NotIncludingNotListable` and four sibling variants that the
   document never defined, and the generator rejected the whole document over it.
   They become a permissive `string`. Inventing an enum would assert an
   allow-list nobody wrote.
4. **OpenAPI 3.0 `nullable` inside a 3.1 document.** Twenty-five properties used
   the 3.0 spelling, which a 3.1 parser ignores. Two of them —
   `UserPermission.parent` and `UserPermission.via_roles` — are also `required`,
   so without translation to `["integer", "null"]` they generate as
   non-optional and every response where a permission has no parent fails to
   decode. `Tests/VictualAPITests` pins this.
5. **`type: object` alongside `oneOf`.** Contradictory, and rejected by the
   generator. The redundant `type` is dropped.
6. **The `servers` placeholder.** Upstream publishes `{"url": "xxx"}`. Victual
   is self-hosted, so it becomes the relative prefix `/api`; `VictualServer`
   supplies the origin at runtime.
7. **Flags typed `boolean` that the server sent as `0`/`1`.** Retyped to `integer`, or a
   booking response failed to decode after the booking had been written. The list is
   empty since 0.2.0-MVP, which sends those fields as real booleans
   ([issue #230](https://github.com/datagen24/victual/issues/230)). Retyping them now
   would refuse the server's `false`, so `Tests/VictualAPITests` asserts they stay
   `boolean`.

## Known upstream issues left in place

A defect that changes what the API *says* it returns is not repaired here, because
repairing it would mean guessing at the contract. Such defects are recorded in
`spec-lock.json` under `upstreamIssuesLeftInPlace` and reported upstream.

The list is empty as of 0.2.0-MVP. The one entry it held, `GET /user` typed as an object
carrying `items`, is fixed upstream
([issue #233](https://github.com/datagen24/victual/issues/233)): the route is documented
as the array of one `UserDto` it has always returned.
