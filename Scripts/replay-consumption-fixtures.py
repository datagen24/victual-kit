#!/usr/bin/env python3
"""Replay the Victual server's consumption-event fixtures against a live instance.

The server repository ships one JSON file per ADR-0041 acceptance sequence
(`tests/fixtures/consumption-events/NN-slug.json`). The server runs them against a
throwaway PostgreSQL schema. This script runs the same requests over HTTP against a
running instance, building each fixture's world (locations, products, purchases) first
and checking each step's answer and stock.

What this is and is not: it shows that a *deployed* instance, reached the way a client
reaches it, gives the answers the server's own fixtures expect. It is neither the
server's fixture run nor evidence from a device. Apple Health produced none of these
requests.

Configuration is by environment, never by argument, so a key stays out of shell history:

    VICTUAL_DEV_URL   base URL of the instance, e.g. http://host
    VICTUAL_DEV_KEY   API key of the default actor ("alice")
    VICTUAL_DEV_KEY_<NAME>   optional keys for other actors (e.g. _BOB); a fixture that
                      needs an actor with no key is reported BLOCKED, not failed.

Usage:
    Scripts/replay-consumption-fixtures.py FIXTURE_DIR [--only 02,09b] [--report OUT.json]

It WRITES to the instance (locations, products, stock, mappings, events), under names
carrying a per-run prefix and a per-run source_system, so reruns never collide. Point it
at a throwaway instance.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

UNIT_ID = 2  # "Piece", present on a fresh instance; every product uses it.


class Blocked(Exception):
    """The fixture cannot run here (needs an actor with no key)."""


class Client:
    def __init__(self, base: str, keys: dict[str, str]):
        self.base = base.rstrip("/")
        self.keys = keys

    def call(self, actor: str, method: str, path: str, body=None):
        key = self.keys.get(actor)
        if key is None:
            raise Blocked(f"no API key for actor '{actor}' (set VICTUAL_DEV_KEY_{actor.upper()})")
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(self.base + path, data=data, method=method)
        request.add_header("VICTUAL-API-KEY", key)
        request.add_header("Accept", "application/json")
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                status, raw = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, raw = error.code, error.read()
        try:
            parsed = json.loads(raw) if raw else None
        except ValueError:
            parsed = raw.decode("utf-8", "replace")
        return status, parsed


def iso(moment: dt.datetime, offset: dt.timedelta | None) -> str:
    if offset is None:
        return moment.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    zone = dt.timezone(offset)
    text = moment.astimezone(zone).strftime("%Y-%m-%dT%H:%M:%S%z")
    return text[:-2] + ":" + text[-2:]


def parse_offset(text: str | None) -> dt.timedelta | None:
    if not text:
        return None
    sign = 1 if text[0] == "+" else -1
    hours, minutes = text[1:].split(":")
    return sign * dt.timedelta(hours=int(hours), minutes=int(minutes))


def shifted(start: dt.datetime, amount: str) -> dt.datetime:
    match = re.fullmatch(r"([+-])(\d+)([mhd])", amount)
    if not match:
        raise ValueError(f"bad time shift: {amount}")
    n = int(match.group(2)) * (1 if match.group(1) == "+" else -1)
    unit = {"m": "minutes", "h": "hours", "d": "days"}[match.group(3)]
    return start + dt.timedelta(**{unit: n})


class World:
    def __init__(self, start: dt.datetime):
        self.start = start
        self.locations: dict[str, int] = {}
        self.products: dict[str, int] = {}
        self.saved: dict[str, object] = {}

    def lookup(self, token: str):
        kind, _, rest = token.partition(".")
        if token == "unit":
            return UNIT_ID
        if kind == "product":
            return self.products[rest]
        if kind == "location":
            return self.locations[rest]
        if kind == "saved":
            return self.saved[rest]
        if kind in ("user", "username"):
            raise Blocked("fixture refers to another user's id; multi-user fixtures are not replayed")
        raise KeyError(token)

    def resolve_token(self, token: str):
        time_match = re.fullmatch(r"(time|date):([+-]\d+[mhd])(?:@([+-]\d\d:\d\d))?", token)
        if time_match:
            moment = shifted(self.start, time_match.group(2))
            offset = parse_offset(time_match.group(3))
            if time_match.group(1) == "date":
                return moment.astimezone(dt.timezone(offset) if offset else dt.timezone.utc).strftime("%Y-%m-%d")
            return iso(moment, offset)
        return self.lookup(token)

    def substitute(self, value):
        if isinstance(value, str):
            whole = re.fullmatch(r"\{\{([^}]+)\}\}", value)
            if whole and whole.group(1) != "any":
                return self.resolve_token(whole.group(1))
            return re.sub(
                r"\{\{([^}]+)\}\}",
                lambda m: m.group(0) if m.group(1) == "any" else str(self.resolve_token(m.group(1))),
                value,
            )
        if isinstance(value, list):
            return [self.substitute(v) for v in value]
        if isinstance(value, dict):
            return {k: self.substitute(v) for k, v in value.items()}
        return value


def dotted(value, path: str):
    if path == "":
        return value
    for part in path.split("."):
        if isinstance(value, list):
            value = value[int(part)]
        else:
            value = value[part]
    return value


def subset(expected, actual, where="") -> list[str]:
    """Differences, per the fixtures' README: objects match on listed keys, lists element-wise."""
    if expected == "{{any}}":
        return [] if actual is not None else [f"{where or '/'}: expected a value, got none"]
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return [f"{where or '/'}: expected object, got {type(actual).__name__}"]
        problems: list[str] = []
        for key, want in expected.items():
            if key not in actual:
                problems.append(f"{where}/{key}: missing")
            else:
                problems += subset(want, actual[key], f"{where}/{key}")
        return problems
    if isinstance(expected, list):
        if not isinstance(actual, list):
            return [f"{where or '/'}: expected list, got {type(actual).__name__}"]
        if not expected:
            return [] if not actual else [f"{where or '/'}: expected an empty list, got {len(actual)} items"]
        problems = []
        for index, want in enumerate(expected):
            if index >= len(actual):
                problems.append(f"{where}[{index}]: missing")
            else:
                problems += subset(want, actual[index], f"{where}[{index}]")
        return problems
    if isinstance(expected, (int, float)) and not isinstance(expected, bool):
        if isinstance(actual, (int, float)) and not isinstance(actual, bool) and float(expected) == float(actual):
            return []
        return [f"{where or '/'}: expected {expected!r}, got {actual!r}"]
    return [] if expected == actual else [f"{where or '/'}: expected {expected!r}, got {actual!r}"]


def build_world(client: Client, fixture: dict, prefix: str, start: dt.datetime) -> World:
    world = World(start)
    setup = fixture["setup"]
    for name in setup.get("locations", []):
        status, body = client.call("alice", "POST", "/api/objects/locations", {"name": f"{prefix}-{name}"})
        if status != 200:
            raise RuntimeError(f"seed location {name}: {status} {body}")
        world.locations[name] = body["created_object_id"]
    for name, spec in setup.get("products", {}).items():
        status, body = client.call(
            "alice",
            "POST",
            "/api/objects/products",
            {
                "name": f"{prefix}-{name}",
                "location_id": next(iter(world.locations.values()), 2),
                "qu_id_stock": UNIT_ID,
                "qu_id_purchase": UNIT_ID,
                "qu_id_consume": UNIT_ID,
                "qu_id_price": UNIT_ID,
            },
        )
        if status != 200:
            raise RuntimeError(f"seed product {name}: {status} {body}")
        world.products[name] = body["created_object_id"]
        for location, amounts in spec.get("stock", {}).items():
            for amount in amounts if isinstance(amounts, list) else [amounts]:
                status, added = client.call(
                    "alice",
                    "POST",
                    f"/api/stock/products/{world.products[name]}/add",
                    {"amount": amount, "transaction_type": "purchase", "location_id": world.locations[location]},
                )
                if status != 200:
                    raise RuntimeError(f"seed stock {name}@{location}: {status} {added}")
    return world


def read_stock(client: Client, world: World, name: str) -> float:
    key, _, location = name.partition("@")
    product = world.products[key]
    if location:
        status, rows = client.call("alice", "GET", f"/api/stock/products/{product}/locations")
        if status != 200:
            raise RuntimeError(f"read stock locations: {status}")
        wanted = world.locations[location]
        return sum(float(r["amount"]) for r in rows if r["location_id"] == wanted)
    status, body = client.call("alice", "GET", f"/api/stock/products/{product}")
    if status != 200:
        raise RuntimeError(f"read stock: {status}")
    return float(body["stock_amount"])


def run_fixture(client: Client, path: Path, run: str) -> dict:
    number = path.name.split("-")[0]
    source = f"rp{run}f{number}"[:32].lower()
    # Fixtures share ids across files, but the instance is shared: a manual request_id is an
    # idempotency key per user, and the inbox lists every event the user has. Namespace the first
    # here; the second is handled where a list answer is checked.
    text = path.read_text().replace("healthkit", source)
    text = re.sub(r'("request_id"\s*:\s*")([^"]+)(")', lambda m: f"{m.group(1)}{m.group(2)}-{run}{number}{m.group(3)}", text)
    fixture = json.loads(text)
    result = {"file": path.name, "adr": fixture.get("adr_sequence"), "title": fixture["title"], "steps": []}

    users = set(fixture["setup"].get("users", ["alice"])) | {s.get("as", "alice") for s in fixture["steps"]}
    missing = sorted(u for u in users if u not in client.keys)
    if missing:
        result.update(status="BLOCKED", reason=f"no API key for: {', '.join(missing)}")
        return result

    start = dt.datetime.now(dt.timezone.utc)
    world = build_world(client, fixture, f"rp{run}-{number}", start)
    failed = False
    for index, step in enumerate(fixture["steps"], start=1):
        actor = step.get("as", "alice")
        request = world.substitute(step["request"])
        status, body = client.call(actor, request["method"], request["path"], request.get("body"))
        # The event inbox lists everything the user owns on this instance, including earlier
        # fixtures and runs. Keep only this fixture's events so list expectations stay meaningful.
        if request["method"] == "GET" and request["path"].split("?")[0] == "/api/consumption/events" and isinstance(body, list):
            body = [e for e in body if e.get("source_system") == source]
        problems: list[str] = []
        expect = world.substitute(step["expect"])
        if status != expect["status"]:
            problems.append(f"status: expected {expect['status']}, got {status}")
        if "body" in expect:
            problems += subset(expect["body"], body)
        for where, count in expect.get("count", {}).items():
            try:
                got = len(dotted(body, where))
            except (KeyError, IndexError, TypeError, ValueError):
                got = None
            if got != count:
                problems.append(f"count at '{where}': expected {count}, got {got}")
        for name, where in step.get("save", {}).items():
            try:
                world.saved[name] = dotted(body, where)
            except (KeyError, IndexError, TypeError, ValueError):
                problems.append(f"save '{name}': no value at '{where}'")
        stock: dict[str, float] = {}
        for name, want in step.get("stock", {}).items():
            got = read_stock(client, world, name)
            stock[name] = got
            if abs(got - float(want)) > 1e-9:
                problems.append(f"stock {name}: expected {want}, got {got}")
        failed |= bool(problems)
        result["steps"].append(
            {
                "n": index,
                "note": step.get("note", ""),
                "request": f"{request['method']} {request['path']}",
                "http": status,
                "state": body.get("state") if isinstance(body, dict) else None,
                "reason": body.get("reason") if isinstance(body, dict) else None,
                "stock": stock,
                "problems": problems,
            }
        )
    result["status"] = "FAIL" if failed else "PASS"
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("fixtures", type=Path, help="directory with the server's consumption-events fixtures")
    parser.add_argument("--only", help="comma-separated fixture numbers, e.g. 02,09b")
    parser.add_argument("--report", type=Path, help="write the full result as JSON here")
    args = parser.parse_args()

    base = os.environ.get("VICTUAL_DEV_URL")
    default_key = os.environ.get("VICTUAL_DEV_KEY")
    if not base or not default_key:
        print("error: set VICTUAL_DEV_URL and VICTUAL_DEV_KEY", file=sys.stderr)
        return 2
    keys = {"alice": default_key}
    for name, value in os.environ.items():
        if name.startswith("VICTUAL_DEV_KEY_") and value:
            keys[name[len("VICTUAL_DEV_KEY_"):].lower()] = value
    client = Client(base, keys)

    status, info = client.call("alice", "GET", "/api/system/info")
    status_caps, caps = client.call("alice", "GET", "/api/consumption/capabilities")
    if status != 200 or status_caps != 200:
        print(f"error: instance unreachable or key rejected ({status}, {status_caps})", file=sys.stderr)
        return 2
    run = format(int(time.time()) % (36**4), "x")[-4:].rjust(4, "0")

    wanted = set(args.only.split(",")) if args.only else None
    files = sorted(p for p in args.fixtures.glob("[0-9]*.json") if wanted is None or p.name.split("-")[0] in wanted)
    results = []
    for path in files:
        try:
            outcome = run_fixture(client, path, run)
        except Blocked as blocked:
            outcome = {"file": path.name, "status": "BLOCKED", "reason": str(blocked), "steps": []}
        except Exception as error:  # a harness or seed failure is not a server failure
            outcome = {"file": path.name, "status": "ERROR", "reason": f"{type(error).__name__}: {error}", "steps": []}
        results.append(outcome)
        extra = outcome.get("reason", "")
        print(f"{outcome['status']:7} {outcome['file']}  {extra}")
        for step in outcome["steps"]:
            for problem in step["problems"]:
                print(f"          step {step['n']} ({step['note']}): {problem}")

    totals = {s: sum(1 for r in results if r["status"] == s) for s in ("PASS", "FAIL", "BLOCKED", "ERROR")}
    print(f"\nserver {info.get('victual_version', {}).get('Version')} db {info.get('db_version')}; "
          f"contract {caps.get('contract_version')}; run {run}; {totals}")
    if args.report:
        args.report.write_text(json.dumps({"run": run, "server": info, "capabilities": caps, "results": results}, indent=1))
    return 1 if totals["FAIL"] or totals["ERROR"] else 0


if __name__ == "__main__":
    sys.exit(main())
