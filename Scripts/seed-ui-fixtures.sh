#!/usr/bin/env bash
# Seeds a small readable household ("ui1-" prefix) on a Victual test instance.
# Usage: VICTUAL_URL=http://host VICTUAL_ADMIN_KEY=... Scripts/seed-ui-fixtures.sh
set -euo pipefail
: "${VICTUAL_URL:?}" "${VICTUAL_ADMIN_KEY:?}"
H=(-H "VICTUAL-API-KEY: $VICTUAL_ADMIN_KEY" -H "Content-Type: application/json")
post() { curl -sf "${H[@]}" -X POST "$VICTUAL_URL$1" -d "$2"; }
id() { python3 -c 'import sys,json;print(json.load(sys.stdin)["created_object_id"])'; }
PANTRY=$(post /api/objects/locations '{"name":"ui1-Pantry"}' | id)
FRIDGE=$(post /api/objects/locations '{"name":"ui1-Fridge"}' | id)
mk() { post /api/objects/products "{\"name\":\"$1\",\"location_id\":$2,\"qu_id_purchase\":2,\"qu_id_stock\":2,\"qu_id_consume\":2,\"qu_id_price\":2,\"min_stock_amount\":$3}" | id; }
RICE=$(mk ui1-Rice "$PANTRY" 0); MILK=$(mk ui1-Milk "$FRIDGE" 0)
PASTA=$(mk ui1-Pasta "$PANTRY" 10); EGGS=$(mk ui1-Eggs "$FRIDGE" 0)
add() { post "/api/stock/products/$1/add" "{\"amount\":$2,\"transaction_type\":\"purchase\",\"location_id\":$3,\"price\":1.5}" >/dev/null; }
add "$RICE" 5 "$PANTRY"; add "$MILK" 2 "$FRIDGE"; add "$PASTA" 3 "$PANTRY"; add "$EGGS" 12 "$FRIDGE"
echo "seeded: pantry=$PANTRY fridge=$FRIDGE rice=$RICE milk=$MILK pasta=$PASTA eggs=$EGGS"
