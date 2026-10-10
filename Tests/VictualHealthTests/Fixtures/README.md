# Fixtures

`adr-examples.json` holds the response bodies shown in ADR-0041's "Examples" appendix, with the
ADR's elided ids (`6F1C...A9`) written out in full so they decode. They are decoded through the
generated `ConsumptionExternalEvent` and adapted, and through the hand-written event type.

The specification the wire types are checked against is the vendored
`Sources/VictualAPI/openapi.json`, recorded in `openapi/spec-lock.json`; `WireContractTests`
reads it directly, so re-running `Scripts/update-openapi.py` re-points those tests.
