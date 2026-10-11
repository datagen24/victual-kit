#!/usr/bin/env python3
"""Seed a disposable Victual instance for the macOS manual test.

Writes a small household whose every location, product and stock entry is named
with the prefix `mac-`, so the data for docs/acceptance/macos-app-manual-test.md
can be told from anything else on the instance. Nothing outside that prefix is
read for writing, changed or removed.

Re-running restores the baseline. A product whose stock already matches is left
alone. A product whose stock differs (the tester consumed some, moved some) is
emptied by an inventory correction to zero and filled again. Due dates are
relative to the day the script runs, so a run on a later day moves them.

The key needs MASTER_DATA_EDIT (to create products and locations) and the stock
permissions (STOCK_PURCHASE, STOCK_INVENTORY). The administrator key does.

Usage:
    export VICTUAL_DEV_URL=http://your-instance.example   # no key here
    export VICTUAL_DEV_KEY=...                            # from your shell, not a file
    Scripts/seed-dev-household.py            # create or restore the baseline
    Scripts/seed-dev-household.py --dry-run  # print the plan, write nothing
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import sys
import urllib.error
import urllib.request

PREFIX = "mac-"

# Locations: (name, parent name, is_freezer). Parents come first.
LOCATIONS = [
    ("mac-Pantry", None, False),
    ("mac-Pantry Shelf", "mac-Pantry", False),
    ("mac-Fridge", None, False),
    ("mac-Freezer", None, True),
    ("mac-Garage", None, False),  # stays empty on purpose
]

# Products. `lots` are (amount, days from today, price or None, location).
# `due_type` 1 is "best before" (goes overdue), 2 is "expires" (goes expired).
PRODUCTS = [
    {
        "name": "mac-Milk",
        "unit": "Pack",
        "location": "mac-Fridge",
        "min": 3,
        "details": "Whole, one litre.",
        "lots": [
            (1, 2, 1.50, "mac-Fridge"),
            (2, 9, 1.60, "mac-Fridge"),
            (1, 20, None, "mac-Pantry"),
        ],
    },
    {
        "name": "mac-Eggs",
        "unit": "Piece",
        "location": "mac-Fridge",
        "lots": [(12, 14, 0.30, "mac-Fridge")],
    },
    {
        "name": "mac-Rice",
        "unit": "Pack",
        "location": "mac-Pantry",
        "lots": [(5, 300, 3.20, "mac-Pantry")],
    },
    {
        "name": "mac-Flour",
        "unit": "Pack",
        "location": "mac-Pantry Shelf",
        "lots": [(2.5, 120, 1.10, "mac-Pantry Shelf")],
    },
    {
        "name": "mac-Yoghurt",
        "unit": "Piece",
        "location": "mac-Fridge",
        "lots": [(4, -3, 0.80, "mac-Fridge")],
    },
    {
        "name": "mac-Cream",
        "unit": "Piece",
        "location": "mac-Fridge",
        "due_type": 2,
        "lots": [(2, -5, 1.20, "mac-Fridge")],
    },
    {
        "name": "mac-Butter",
        "unit": "Pack",
        "location": "mac-Fridge",
        "lots": [(3, 40, 2.40, "mac-Fridge")],
    },
    {
        "name": "mac-Peas",
        "unit": "Pack",
        "location": "mac-Freezer",
        "lots": [(6, 200, 1.75, "mac-Freezer")],
    },
    {
        "name": "mac-Salt",
        "unit": "Pack",
        "location": "mac-Pantry",
        "min": 2,
        "lots": [],  # below its minimum with nothing in stock
    },
    {"name": "mac-Pasta", "unit": "Pack", "location": "mac-Pantry", "lots": []},
    {
        "name": "mac-Pasta Penne",
        "unit": "Pack",
        "location": "mac-Pantry",
        "parent": "mac-Pasta",
        "lots": [(2, 200, 1.30, "mac-Pantry")],
    },
    {
        "name": "mac-Pasta Spaghetti",
        "unit": "Pack",
        "location": "mac-Pantry",
        "parent": "mac-Pasta",
        "lots": [(3, 220, 1.20, "mac-Pantry")],
    },
    {
        "name": "mac-Long name check: a product whose name is long enough to need truncating in the table",
        "unit": "Piece",
        "location": "mac-Pantry",
        "lots": [(1, 60, None, "mac-Pantry")],
    },
]


class Api:
    def __init__(self, base: str, key: str, dry_run: bool) -> None:
        self.base = base.rstrip("/") + "/api"
        self.key = key
        self.dry_run = dry_run
        self.writes = 0

    def call(self, method: str, path: str, body: dict | None = None):
        data = None
        headers = {"VICTUAL-API-KEY": self.key}
        if body is not None:
            data = json.dumps(body).encode()
            # The server compares this header with the bare media type, so a
            # charset parameter is refused.
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            self.base + path, data=data, headers=headers, method=method
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                text = response.read().decode()
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")[:300]
            raise SystemExit(f"{method} {path} -> HTTP {error.code}: {detail}")
        except urllib.error.URLError as error:
            raise SystemExit(f"{method} {path} failed: {error.reason}")
        return json.loads(text) if text.strip() else None

    def write(self, method: str, path: str, body: dict | None = None):
        """A write, which a dry run only reports."""
        self.writes += 1
        if self.dry_run:
            print(f"  would {method} {path}")
            return {"created_object_id": -1}
        return self.call(method, path, body)


def day(offset: int) -> str:
    return (_dt.date.today() + _dt.timedelta(days=offset)).isoformat()


def ensure_locations(api: Api) -> dict[str, int]:
    existing = {row["name"]: row for row in api.call("GET", "/objects/locations")}
    ids: dict[str, int] = {}
    for name, parent, freezer in LOCATIONS:
        assert name.startswith(PREFIX)
        if name in existing:
            ids[name] = existing[name]["id"]
            continue
        body = {"name": name, "is_freezer": 1 if freezer else 0}
        if parent:
            body["parent_location_id"] = ids[parent]
        print(f"create location {name}")
        ids[name] = api.write("POST", "/objects/locations", body)["created_object_id"]
    return ids


def ensure_products(api: Api, locations: dict[str, int]) -> dict[str, int]:
    units = {row["name"]: row["id"] for row in api.call("GET", "/objects/quantity_units")}
    existing = {row["name"]: row for row in api.call("GET", "/objects/products")}
    ids: dict[str, int] = {}
    for spec in PRODUCTS:
        name = spec["name"]
        assert name.startswith(PREFIX)
        if name in existing:
            ids[name] = existing[name]["id"]
            continue
        unit = units[spec["unit"]]
        body = {
            "name": name,
            "description": spec.get("details"),
            "location_id": locations[spec["location"]],
            "qu_id_stock": unit,
            "qu_id_purchase": unit,
            "qu_id_consume": unit,
            "qu_id_price": unit,
            "min_stock_amount": spec.get("min", 0),
            "default_best_before_days": 0,
            "due_type": spec.get("due_type", 1),
        }
        if "parent" in spec:
            body["parent_product_id"] = ids[spec["parent"]]
        print(f"create product {name[:40]}")
        ids[name] = api.write("POST", "/objects/products", body)["created_object_id"]
    return ids


def wanted_lots(spec: dict) -> list[tuple]:
    return sorted((amount, day(offset), loc) for amount, offset, _price, loc in spec["lots"])


def current_lots(api: Api, product_id: int, locations: dict[str, int]) -> tuple[list[tuple], bool]:
    by_id = {value: key for key, value in locations.items()}
    entries = api.call("GET", f"/stock/products/{product_id}/entries")
    lots = sorted(
        (e["amount"], e["best_before_date"], by_id.get(e["location_id"], "?")) for e in entries
    )
    opened = any(e.get("open") for e in entries)
    return lots, opened


def restore_stock(api: Api, products: dict[str, int], locations: dict[str, int]) -> None:
    for spec in PRODUCTS:
        name, product_id = spec["name"], products[spec["name"]]
        assert name.startswith(PREFIX)
        lots, opened = current_lots(api, product_id, locations) if product_id > 0 else ([], False)
        if lots == wanted_lots(spec) and not opened:
            print(f"ok      {name[:40]}")
            continue
        if lots:
            print(f"reset   {name[:40]}")
            api.write(
                "POST",
                f"/stock/products/{product_id}/inventory",
                {"new_amount": 0},
            )
        for amount, offset, price, loc in spec["lots"]:
            body = {
                "amount": amount,
                "best_before_date": day(offset),
                "transaction_type": "purchase",
                "location_id": locations[loc],
            }
            if price is not None:
                body["price"] = price
            print(f"stock   {name[:40]}: {amount} due {day(offset)} in {loc}")
            api.write("POST", f"/stock/products/{product_id}/add", body)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--dry-run", action="store_true", help="print the plan and write nothing")
    args = parser.parse_args()

    base = os.environ.get("VICTUAL_DEV_URL")
    key = os.environ.get("VICTUAL_DEV_KEY")
    if not base or not key:
        print("Set VICTUAL_DEV_URL and VICTUAL_DEV_KEY in the environment.", file=sys.stderr)
        return 2

    api = Api(base, key, args.dry_run)
    info = api.call("GET", "/system/info")
    version = (info.get("victual_version") or {}).get("Version", "unknown")
    print(f"Connected to Victual {version}{' (dry run)' if args.dry_run else ''}")

    locations = ensure_locations(api)
    products = ensure_products(api, locations)
    restore_stock(api, products, locations)
    print(f"Done: {api.writes} write(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
