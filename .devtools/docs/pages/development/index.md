# Development

This section is for someone changing VictualKit rather than using it.

## Building and testing

```sh
Scripts/build.sh test                  # swift test, with the generated-code noise filtered out
Scripts/verify-platforms.sh            # build every product for every supported platform
Scripts/update-openapi.py              # re-sync the specification from upstream
cd Apps/Victual && xcodegen generate   # regenerate the macOS application's project
cd Apps/VictualPhone && xcodegen generate   # and the iPhone application's
```

`Scripts/build.sh` filters the output because swift-openapi-generator emits about 2.7 MB
of Swift, and its deprecation warnings would otherwise bury real diagnostics.

On every pull request the `CI` workflow runs five jobs:

| Job | What it checks |
| --- | --- |
| `test` | `swift test` on macOS. |
| `platforms` | A `VictualUI` build for macOS, iOS, iOS Simulator, tvOS, watchOS and visionOS. |
| `app` | The macOS application, generated with XcodeGen and built unsigned. |
| `phone` | The iPhone application, built unsigned for the simulator. The live scanner is verified on a phone. |
| `spec-drift` | That the vendored specification matches upstream. It also runs weekly. |

The `prose` and `docs` workflows check the documentation; see
[Prose checks](prose.md) and [Documentation site](docs-site.md).

## Where decisions are recorded

Architectural decisions are in
[Victual's ADR corpus](https://victual.readthedocs.io/en/latest/development/adr/),
which governs this repository too. Design plans are in
[docs/plans/](https://github.com/datagen24/victual-kit/tree/main/docs/plans) in the
repository, and are not published on this site.

Documentation follows the server's
[documentation conventions](https://victual.readthedocs.io/en/latest/development/documentation-conventions/)
and [writing style](https://victual.readthedocs.io/en/latest/development/writing-style/).
