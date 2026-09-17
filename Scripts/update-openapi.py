#!/usr/bin/env python3
"""Track and normalize the upstream Victual OpenAPI specification.

The upstream document (https://github.com/datagen24/victual) is written for
Slim/PHP and is not directly consumable by swift-openapi-generator.  This
script vendors the upstream document verbatim, applies a deterministic set of
normalizations, and writes the generator input plus a lock file recording
exactly which upstream revision the checked-in Swift API was generated from.

Usage:
    Scripts/update-openapi.py             # fetch upstream, normalize, write
    Scripts/update-openapi.py --offline   # re-normalize the vendored copy only
    Scripts/update-openapi.py --check     # fail if outputs are stale (CI)
"""

from __future__ import annotations

import argparse
import datetime as _dt
import difflib
import hashlib
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

UPSTREAM_REPO = "datagen24/victual"
UPSTREAM_REF = "master"
UPSTREAM_PATH = "victual.openapi.json"
UPSTREAM_URL = (
    f"https://raw.githubusercontent.com/{UPSTREAM_REPO}/{UPSTREAM_REF}/{UPSTREAM_PATH}"
)

VENDORED = ROOT / "openapi" / "upstream" / "victual.openapi.json"
OVERRIDES = ROOT / "openapi" / "operation-ids.json"
LOCK = ROOT / "openapi" / "spec-lock.json"
GENERATED = ROOT / "Sources" / "VictualAPI" / "openapi.json"

# The upstream `servers` entry is the literal placeholder "xxx".  Victual is
# self-hosted, so there is no canonical origin: callers always supply their own
# instance URL and `VictualServer` appends this prefix.
SERVER_URL = "/api"
SERVER_DESCRIPTION = "Victual REST API, relative to the instance root."

HTTP_METHODS = ("get", "put", "post", "delete", "options", "head", "patch", "trace")


# --------------------------------------------------------------------------
# fetching
# --------------------------------------------------------------------------


def fetch_upstream() -> tuple[bytes, str | None]:
    """Return the raw upstream document and, best effort, its commit SHA."""
    request = urllib.request.Request(
        UPSTREAM_URL, headers={"User-Agent": "victual-kit-spec-sync"}
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = response.read()
    return payload, fetch_upstream_commit()


def fetch_upstream_commit() -> str | None:
    """Look up the commit that last touched the spec. Best effort: the GitHub
    API is rate limited for unauthenticated callers, and a missing SHA must not
    break the sync."""
    url = (
        f"https://api.github.com/repos/{UPSTREAM_REPO}/commits"
        f"?path={UPSTREAM_PATH}&sha={UPSTREAM_REF}&per_page=1"
    )
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "victual-kit-spec-sync",
            "Accept": "application/vnd.github+json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            commits = json.load(response)
    except (urllib.error.URLError, json.JSONDecodeError, TimeoutError):
        return None
    if isinstance(commits, list) and commits:
        return commits[0].get("sha")
    return None


# --------------------------------------------------------------------------
# normalization
# --------------------------------------------------------------------------


def strip_route_constraints(template: str) -> str:
    """`/labels/{kind:a|b}/{id:[0-9]+}/print` -> `/labels/{kind}/{id}/print`.

    Slim allows a regular expression after the parameter name; OpenAPI path
    templating does not, and the constraint is already expressed by the
    parameter's own schema."""
    return re.sub(r"\{([A-Za-z0-9_.\-]+):[^{}]*\}", r"{\1}", template)


def normalize_paths(document: dict) -> tuple[dict, int]:
    """Rewrite path templates, failing loudly on a collision rather than
    silently dropping an operation."""
    rewritten: dict[str, dict] = {}
    changed = 0
    for template, item in document.get("paths", {}).items():
        clean = strip_route_constraints(template)
        if clean != template:
            changed += 1
        if clean in rewritten:
            raise SystemExit(
                f"normalization collision: {template!r} and an earlier path both "
                f"reduce to {clean!r}"
            )
        rewritten[clean] = item
    document["paths"] = rewritten
    return document, changed


def operation_id(method: str, template: str) -> str:
    """Deterministic, collision-free operation name derived from the route.

    Upstream declares no `operationId`, and swift-openapi-generator would
    otherwise synthesize names like `get_sol_stock_sol_products_sol_...`.
    `GET /stock/products/{productId}/price-history` becomes
    `getStockProductsByProductIdPriceHistory`."""
    parts = [method.lower()]
    for segment in template.strip("/").split("/"):
        if not segment:
            continue
        if segment.startswith("{") and segment.endswith("}"):
            parts.append("By")
            words = re.split(r"[^A-Za-z0-9]+", segment[1:-1])
        else:
            words = re.split(r"[^A-Za-z0-9]+", segment)
        parts.extend(word[:1].upper() + word[1:] for word in words if word)
    return "".join(parts)


def assign_operation_ids(document: dict, overrides: dict[str, str]) -> tuple[int, int]:
    """Give every operation a stable `operationId`. Returns (assigned, kept)."""
    seen: dict[str, str] = {}
    assigned = kept = 0
    for template, item in document.get("paths", {}).items():
        for method, operation in item.items():
            if method not in HTTP_METHODS or not isinstance(operation, dict):
                continue
            route = f"{method.upper()} {template}"
            if operation.get("operationId"):
                kept += 1
                name = operation["operationId"]
            else:
                name = overrides.get(route) or operation_id(method, template)
                operation["operationId"] = name
                assigned += 1
            if name in seen:
                raise SystemExit(
                    f"duplicate operationId {name!r} for {route} and {seen[name]}; "
                    f"add a distinct name to {OVERRIDES.relative_to(ROOT)}"
                )
            seen[name] = route
    return assigned, kept


def normalize_nullability(node: object) -> int:
    """Translate the OpenAPI 3.0 `nullable: true` keyword into the 3.1 type
    union the document declares itself to use.

    Left alone, `{"type": "integer", "nullable": true}` parses as a plain
    non-optional integer and every `null` the server sends is a decode failure.
    """
    fixed = 0
    if isinstance(node, dict):
        if node.pop("nullable", None) is True:
            declared = node.get("type")
            if isinstance(declared, str):
                node["type"] = [declared, "null"]
                fixed += 1
            elif isinstance(declared, list) and "null" not in declared:
                node["type"] = [*declared, "null"]
                fixed += 1
        for value in node.values():
            fixed += normalize_nullability(value)
    elif isinstance(node, list):
        for value in node:
            fixed += normalize_nullability(value)
    return fixed


def normalize_composition(node: object) -> int:
    """Drop `type: object` where it sits alongside `oneOf`.

    A schema that is simultaneously a concrete object and a choice between
    other schemas is contradictory, and the generator rejects the pair."""
    fixed = 0
    if isinstance(node, dict):
        if "oneOf" in node and node.get("type") == "object" and "properties" not in node:
            del node["type"]
            fixed += 1
        for value in node.values():
            fixed += normalize_composition(value)
    elif isinstance(node, list):
        for value in node:
            fixed += normalize_composition(value)
    return fixed


def resolve_pointer(document: dict, ref: str) -> bool:
    """Whether a local JSON pointer resolves inside `document`."""
    if not ref.startswith("#/"):
        return True  # external references are not ours to validate
    node: object = document
    for token in ref[2:].split("/"):
        token = token.replace("~1", "/").replace("~0", "~")
        if not isinstance(node, dict) or token not in node:
            return False
        node = node[token]
    return True


def repair_dangling_refs(document: dict) -> list[str]:
    """Replace `$ref`s to schemas the document never defines.

    Upstream points the `entity` path parameter at five variants of
    `ExposedEntity` (`..._NotIncludingNotListable` and friends) that do not
    exist in `components/schemas`, and the generator refuses the document
    outright.  The substitute is a permissive `string`: an untyped parameter is
    inconvenient, but inventing an enum would be worse -- it would silently
    assert an allow-list nobody wrote."""
    repaired: list[str] = []

    def visit(node: object, path: str) -> None:
        if isinstance(node, dict):
            ref = node.get("$ref")
            if isinstance(ref, str) and not resolve_pointer(document, ref):
                description = node.get("description")
                node.clear()
                node["type"] = "string"
                if description:
                    node["description"] = description
                repaired.append(f"{path} -> {ref}")
                return
            for key, value in node.items():
                visit(value, f"{path}/{key}")
        elif isinstance(node, list):
            for index, value in enumerate(node):
                visit(value, f"{path}[{index}]")

    visit(document, "")
    return repaired


def lint(document: dict) -> list[str]:
    """Report upstream modelling mistakes that are left in place deliberately.

    These change what the API *says* it returns, so repairing them would mean
    guessing at the contract.  They are surfaced in the lock file instead, as a
    list of things worth reporting upstream."""
    findings: list[str] = []

    def visit(node: object, path: str) -> None:
        if isinstance(node, dict):
            if node.get("type") == "object" and "items" in node:
                findings.append(
                    f"{path}: declared `object` but carries `items`; generated as "
                    f"a free-form object rather than the referenced type"
                )
            for key, value in node.items():
                visit(value, f"{path}/{key}")
        elif isinstance(node, list):
            for index, value in enumerate(node):
                visit(value, f"{path}[{index}]")

    visit(document.get("paths", {}), "paths")
    visit(document.get("components", {}).get("schemas", {}), "components/schemas")
    return findings


def normalize(raw: bytes, overrides: dict[str, str]) -> tuple[dict, dict]:
    document = json.loads(raw)
    report: dict[str, object] = {}

    document, report["pathsRewritten"] = normalize_paths(document)
    assigned, kept = assign_operation_ids(document, overrides)
    report["operationIdsAssigned"] = assigned
    report["operationIdsFromUpstream"] = kept
    report["nullableKeywordsConverted"] = normalize_nullability(document)
    report["compositionConflictsResolved"] = normalize_composition(document)

    repaired = repair_dangling_refs(document)
    report["danglingRefsRepaired"] = repaired

    document["servers"] = [{"url": SERVER_URL, "description": SERVER_DESCRIPTION}]
    report["serverPlaceholderReplaced"] = True

    report["upstreamIssuesLeftInPlace"] = lint(document)

    return document, report


# --------------------------------------------------------------------------
# entry point
# --------------------------------------------------------------------------


def dump(document: dict) -> str:
    return json.dumps(document, indent="\t", ensure_ascii=False) + "\n"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_overrides() -> dict[str, str]:
    if not OVERRIDES.exists():
        return {}
    data = json.loads(OVERRIDES.read_text())
    return {k: v for k, v in data.items() if not k.startswith("$")}


def report_difference(label: str, expected: str, actual: str) -> None:
    diff = difflib.unified_diff(
        actual.splitlines(keepends=True),
        expected.splitlines(keepends=True),
        fromfile=f"{label} (on disk)",
        tofile=f"{label} (regenerated)",
        n=2,
    )
    sys.stderr.writelines(list(diff)[:80])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--offline",
        action="store_true",
        help="re-normalize the vendored upstream copy without fetching",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero if the vendored or generated spec is stale",
    )
    args = parser.parse_args()

    if args.offline or args.check:
        if not VENDORED.exists():
            print(f"error: {VENDORED.relative_to(ROOT)} is missing", file=sys.stderr)
            return 1
        raw = VENDORED.read_bytes()
        commit = json.loads(LOCK.read_text()).get("upstreamCommit") if LOCK.exists() else None
        if args.check:
            fetched, live_commit = fetch_upstream()
            if sha256(fetched) != sha256(raw):
                print(
                    "error: upstream spec has changed. Run Scripts/update-openapi.py",
                    file=sys.stderr,
                )
                return 1
            commit = live_commit or commit
    else:
        raw, commit = fetch_upstream()

    overrides = load_overrides()
    document, report = normalize(raw, overrides)
    generated = dump(document)

    lock = {
        "upstreamRepository": f"https://github.com/{UPSTREAM_REPO}",
        "upstreamRef": UPSTREAM_REF,
        "upstreamPath": UPSTREAM_PATH,
        "upstreamCommit": commit,
        "upstreamSha256": sha256(raw),
        "generatedSha256": sha256(generated.encode()),
        "syncedAt": _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "normalizations": report,
    }

    if args.check:
        stale = []
        if GENERATED.exists() and GENERATED.read_text() != generated:
            stale.append(str(GENERATED.relative_to(ROOT)))
            report_difference("openapi.json", generated, GENERATED.read_text())
        elif not GENERATED.exists():
            stale.append(str(GENERATED.relative_to(ROOT)))
        if LOCK.exists():
            recorded = json.loads(LOCK.read_text())
            for field in ("upstreamSha256", "generatedSha256"):
                if recorded.get(field) != lock[field]:
                    stale.append(f"{LOCK.relative_to(ROOT)}:{field}")
        else:
            stale.append(str(LOCK.relative_to(ROOT)))
        if stale:
            print("error: stale spec artifacts: " + ", ".join(stale), file=sys.stderr)
            print("       run Scripts/update-openapi.py and commit the result", file=sys.stderr)
            return 1
        print("spec is in sync with upstream")
        return 0

    VENDORED.parent.mkdir(parents=True, exist_ok=True)
    VENDORED.write_bytes(raw)
    GENERATED.parent.mkdir(parents=True, exist_ok=True)
    GENERATED.write_text(generated)
    LOCK.write_text(json.dumps(lock, indent=2) + "\n")

    print(f"upstream    {UPSTREAM_URL}")
    print(f"commit      {commit or 'unknown'}")
    print(f"sha256      {lock['upstreamSha256']}")
    for key, value in report.items():
        if isinstance(value, list):
            print(f"  {key}: {len(value)}")
            for entry in value:
                print(f"      {entry}")
        else:
            print(f"  {key}: {value}")
    print(f"wrote       {GENERATED.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
