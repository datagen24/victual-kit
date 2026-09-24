# VictualKit

The Apple side of [Victual](https://github.com/datagen24/victual), a self-hosted groceries
and household management server: a Swift package for talking to a Victual instance, and
the applications built on it.

Documentation is published at **[victual-kit.readthedocs.io](https://victual-kit.readthedocs.io/)**.

## What is in this repository

| Path | What it is |
| --- | --- |
| [`Sources/`](Sources/README.md) | The **VictualKit Swift package**: `VictualAPI` (generated from the server's OpenAPI document), `VictualCore`, `VictualUI` and `VictualStock`. Every Apple platform from macOS 14 and iOS 17. |
| [`Apps/Victual/`](Apps/Victual/README.md) | **Victual for macOS**, `0.1.0-MVP`. Connects to an instance, shows a household's stock, and books the five stock actions with undo. The package's first consumer. |
| [`openapi/`](openapi/README.md) | The server's OpenAPI document, vendored and pinned to Victual **0.2.0-MVP**, with the record of every normalization applied to it. |
| [`docs/plans/`](docs/plans/README.md) | Design records for major changes, with delivery status. |
| [`docs/concepts/`](docs/concepts/siri-and-app-intents.md) | Earlier-stage thinking. The Siri and App Intents concept for an iPhone app lives here; that app is not in the repository yet. |
| [`.devtools/`](.devtools/vale/README.md) | Prose checks for the documentation, and the documentation site's build. |

## Compatibility

The package and the macOS application need a Victual server at **0.2.0-MVP or later**.
That release made the server send its documented booleans as `true`/`false`, and a
booking response from an older server does not decode. The
[package guide](Sources/README.md#requirements) has the detail.

## Using the package

```swift
.package(url: "https://github.com/datagen24/victual-kit.git", branch: "main")
```

```swift
.product(name: "VictualUI", package: "victual-kit")
```

The [package guide](Sources/README.md) covers the modules, connecting and reading stock,
errors, and Keychain credential storage.

## Development

```sh
Scripts/build.sh test                  # swift test, with the generated-code noise filtered out
Scripts/verify-platforms.sh            # build every product for every supported platform
Scripts/update-openapi.py              # re-sync the specification from upstream
cd Apps/Victual && xcodegen generate   # regenerate the macOS application's project
```

On every pull request the `CI` workflow runs the package tests, a build for each platform,
the macOS application build, and a check that the vendored specification matches upstream.
The `prose` workflow lints the documentation with Vale. To run the same check before each
commit, see [.devtools/vale/](.devtools/vale/README.md#check-commits-locally).

Architectural decisions are not recorded here. They are in
[Victual's ADR corpus](https://github.com/datagen24/victual/blob/master/docs/adr/README.md),
which governs this repository too, and so does the server's
[writing style](https://github.com/datagen24/victual/blob/master/docs/style-guide.md).

## Licence

BSD 3-Clause. See [LICENSE](LICENSE).

`openapi/upstream/victual.openapi.json` is vendored verbatim from Victual and
carries that project's terms (MIT © Bernd Bestel for grocy-derived material, AND
BSD 3-Clause © Steven Peterson). No grocy-derived code is present in this
package.
