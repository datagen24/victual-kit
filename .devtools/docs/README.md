# Documentation site build

Assembles and builds the site published at
[victual-kit.readthedocs.io](https://victual-kit.readthedocs.io/). The design is the
Victual server's documentation site, reduced to what this repository needs; see the
server's [`.devtools/docs/`](https://github.com/datagen24/victual/tree/master/.devtools/docs).

```sh
python3 -m venv .venv && . .venv/bin/activate
pip install -r .devtools/docs/requirements.txt
python3 .devtools/docs/stage.py
mkdocs serve
```

`stage.py` must run first. `mkdocs.yml`'s `docs_dir` is `.docs-build/`, a generated tree
that does not exist until the script creates it. The script deletes and rebuilds it on
every run, so a stale tree is never published.

## What is published

| Source | Page |
| --- | --- |
| `Sources/README.md` | Swift package › Guide |
| `openapi/README.md` | Swift package › Tracking the specification |
| `Apps/Victual/README.md` | Applications › Victual for macOS |
| `Apps/VictualPhone/README.md` | Applications › Victual for iPhone |
| `.devtools/vale/README.md` | Development › Prose checks |
| `.devtools/docs/README.md` | Development › Documentation site |
| `.devtools/docs/pages/` | Home, and the Development overview |

Plans and concepts are not published. The boundary is the one the server's
[ADR-0020](https://victual.readthedocs.io/en/latest/development/adr/0020-documentation-publication-boundary/)
draws: a plan records work in progress with delivery status as of a date, and a published
site presents it as reference. The home page links to both directories on GitHub.

`PAGES` at the top of `stage.py` is the whole map. Adding a page means adding a line there
and a `nav` entry in `mkdocs.yml`. A page in one and not the other fails
`mkdocs build --strict`.

## Why there is a staging step

The pages are READMEs that sit beside the code they describe. A folder README orients a
reader inside that folder, so moving it into a documentation directory would empty the
folder it exists for.

`stage.py` copies them into one tree and rewrites their links. A link to a published page
becomes a relative link to its new home. A link to anything else, such as a plan or a
source file, becomes an absolute GitHub URL on `main`. Sources are never modified, so the
same link keeps working when the file is read on GitHub.

`check_offsite_links()` then resolves every one of those absolute URLs against
`git ls-files`, and fails the run naming the page and the link if the path is not tracked.
Strict mode does not resolve an absolute URL, so without this check a mistyped link would
publish as a 404.

## Branding

The marks in `assets/` are the Victual server's `branding/icon.svg`, `logo.svg` and
`icon-32.png`, and `assets/extra.css` is the server site's stylesheet. Both sites
therefore share one palette. Both marks are drawn in the brand's deep green, which is also
the header colour, so `stage.py` writes a cream variant of each by swapping that one fill.
Take a changed mark from the server rather than editing the copy here.

## What CI checks

The `docs` workflow runs `stage.py` and `mkdocs build --strict` on every pull request.
Strict mode turns a broken relative link, a page missing from the nav, and an anchor that
does not resolve into a failed pull request rather than a defect on the published site.

Read the Docs builds on push independently of that, using `.readthedocs.yaml` at the
repository root, with `fail_on_warning` set so it is as strict as CI.
