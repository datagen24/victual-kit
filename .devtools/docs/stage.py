#!/usr/bin/env python3
"""Assemble the documentation site's source tree.

No section of the site maps to a directory in this repository: the pages are READMEs
that sit beside the code they describe. This script copies them into one tree and
rewrites their links, so the sources stay where they are and keep working on GitHub.

Ported from the Victual server's .devtools/docs/stage.py. What is published follows the
server's ADR-0020: reference documentation is published, plans and concepts stay in the
repository. See .devtools/docs/README.md.
"""
from __future__ import annotations

import argparse
import posixpath
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BLOB = "https://github.com/datagen24/victual-kit/blob/main/"
TREE = "https://github.com/datagen24/victual-kit/tree/main/"

# Repository path -> path within the staged tree. Anything not named here is not
# published, and a link to it is rewritten to GitHub.
PAGES = {
    "Sources/README.md": "package/index.md",
    "openapi/README.md": "package/openapi.md",
    "Apps/Victual/README.md": "apps/macos.md",
    ".devtools/vale/README.md": "development/prose.md",
    ".devtools/docs/README.md": "development/docs-site.md",
}

# Pages written for the site itself, under .devtools/docs/pages/.
SITE_PAGES = ("index.md", "development/index.md")

LINK = re.compile(r"(?<!\!)\[([^\]]*)\]\(([^)\s]+)(\s+\"[^\"]*\")?\)")
REPO_URL = re.compile(
    r"https://github\.com/datagen24/victual-kit/(?:blob|tree)/main/([^)\"\s]+)"
)

# Every link rewritten to an absolute repository URL, as (page, link, resolved path).
# check_offsite_links() is what makes these verifiable.
OFFSITE: list[tuple[str, str, str]] = []


def rewrite_link(target: str, source_repo_path: str, staged_path: str) -> str:
    """Resolve one link against its original home, then point it at its new one."""
    if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
        return target

    path, _, fragment = target.partition("#")
    if not path:
        return target

    resolved = posixpath.normpath(
        posixpath.join(posixpath.dirname(source_repo_path), path)
    )
    if resolved.startswith(".."):
        return target

    destination = PAGES.get(resolved)
    if destination is None:
        # Not published. Point at the repository, and keep a trailing slash meaning
        # "directory" so the URL lands on a tree listing rather than a 404.
        base = TREE if path.endswith("/") or (REPO / resolved).is_dir() else BLOB
        url = base + resolved.rstrip("/")
        OFFSITE.append((source_repo_path, target, resolved.rstrip("/")))
        return url + ("#" + fragment if fragment else "")

    relative = posixpath.relpath(destination, posixpath.dirname(staged_path))
    return relative + ("#" + fragment if fragment else "")


def rewrite(text: str, source_repo_path: str, staged_path: str) -> str:
    def replace(match: re.Match) -> str:
        label, target, title = match.group(1), match.group(2), match.group(3) or ""
        return f"[{label}]({rewrite_link(target, source_repo_path, staged_path)}{title})"

    return LINK.sub(replace, text)


def copy_page(repo_path: str, staged_path: str, out: Path) -> None:
    destination = out / staged_path
    destination.parent.mkdir(parents=True, exist_ok=True)
    text = (REPO / repo_path).read_text()
    destination.write_text(rewrite(text, repo_path, staged_path), encoding="utf-8")


def record_literal_links(text: str, staged_path: str) -> None:
    """Repository URLs written by hand, which rewrite_link never sees."""
    for match in REPO_URL.finditer(text):
        target = match.group(1).partition("#")[0].rstrip("/").rstrip(".,")
        OFFSITE.append((staged_path, match.group(0), target))


def tracked_paths() -> tuple[frozenset[str], frozenset[str]]:
    """What git tracks, as files and as the directories those files sit in."""
    listing = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=REPO,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    files = [path for path in listing.split("\0") if path]
    directories = set()
    for path in files:
        parts = path.split("/")
        for depth in range(1, len(parts)):
            directories.add("/".join(parts[:depth]))
    return frozenset(files), frozenset(directories)


def check_offsite_links() -> None:
    """Every link sent to GitHub must name something the repository actually holds.

    `mkdocs build --strict` cannot see an absolute URL, so a typo in a link rewritten
    to GitHub would otherwise publish as a 404 with nothing in the build to say so.
    Tracking is the test rather than existence on disk, because a gitignored path that
    exists locally is still a 404 on GitHub.
    """
    files, directories = tracked_paths()
    broken = sorted(
        {
            (page, link, resolved)
            for page, link, resolved in OFFSITE
            if resolved not in files and resolved not in directories
        }
    )
    if not broken:
        print(f"  {len(OFFSITE)} links to the repository, all resolving")
        return
    listing = "\n".join(
        f"    {page}: [{link}] -> {resolved}" for page, link, resolved in broken
    )
    raise SystemExit(
        f"{len(broken)} link(s) rewritten to GitHub name a path the repository does "
        f"not track:\n{listing}\n"
        "  Correct the link in the source document. A rewritten link naming nothing is\n"
        "  a 404 on the published site, and mkdocs --strict cannot see it."
    )


BRAND_INK = "#174B3A"
BRAND_CREAM = "#F2E7D3"


def stage_assets(out: Path) -> None:
    """Copy the marks and stylesheet, plus a cream variant of each mark for dark headers.

    The marks are the Victual server's `branding/` files, drawn in the brand's deep
    green, which disappears on the green header. The variant swaps that one fill for
    the brand's cream, the same recolour the server's site makes.
    """
    source = HERE / "assets"
    assets = out / "assets"
    assets.mkdir(parents=True, exist_ok=True)
    for name in ("icon.svg", "logo.svg"):
        svg = (source / name).read_text()
        (assets / name).write_text(svg, encoding="utf-8")
        (assets / f"{Path(name).stem}-dark.svg").write_text(
            svg.replace(BRAND_INK, BRAND_CREAM), encoding="utf-8"
        )
    for name in ("icon-32.png", "extra.css"):
        shutil.copy2(source / name, assets / name)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out", default=".docs-build", help="staging tree (default: .docs-build)"
    )
    args = parser.parse_args()

    out = (REPO / args.out).resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    for repo_path, staged_path in PAGES.items():
        copy_page(repo_path, staged_path, out)
    for name in SITE_PAGES:
        source = HERE / "pages" / name
        (out / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, out / name)
        record_literal_links(source.read_text(), name)

    stage_assets(out)
    check_offsite_links()

    pages = sum(1 for _ in out.rglob("*.md"))
    try:
        where = out.relative_to(REPO)
    except ValueError:
        where = out
    print(f"  staged {pages} Markdown pages into {where}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
