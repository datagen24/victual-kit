#!/usr/bin/env bash
# Seeds nested product groups ("mac-" prefix) and products in them on a Victual test instance.
# Needs MASTER_DATA_EDIT, so use an administrator's key.
# Usage: VICTUAL_URL=http://host VICTUAL_ADMIN_KEY=... Scripts/seed-product-group-fixtures.sh
set -euo pipefail
: "${VICTUAL_URL:?}" "${VICTUAL_ADMIN_KEY:?}"
H=(-H "VICTUAL-API-KEY: $VICTUAL_ADMIN_KEY" -H "Content-Type: application/json")
post() { curl -sf "${H[@]}" -X POST "$VICTUAL_URL$1" -d "$2"; }
put() { curl -sf "${H[@]}" -X PUT "$VICTUAL_URL$1" -d "$2" >/dev/null; }
get() { curl -sf "${H[@]}" "$VICTUAL_URL$1"; }
id() { python3 -c 'import sys,json;print(json.load(sys.stdin)["created_object_id"])'; }
product_id() { get "/api/objects/products?query%5B%5D=name%3D$1" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])'; }

DAIRY=$(post /api/objects/product_groups '{"name":"mac-Dairy"}' | id)
CHEESE=$(post /api/objects/product_groups "{\"name\":\"mac-Cheese\",\"parent_product_group_id\":$DAIRY}" | id)
HARD=$(post /api/objects/product_groups "{\"name\":\"mac-Hard\",\"parent_product_group_id\":$CHEESE}" | id)
BAKERY=$(post /api/objects/product_groups '{"name":"mac-Bakery"}' | id)

put "/api/objects/products/$(product_id mac-Milk)" "{\"product_group_id\":$DAIRY}"
put "/api/objects/products/$(product_id mac-Butter)" "{\"product_group_id\":$DAIRY}"
put "/api/objects/products/$(product_id mac-Flour)" "{\"product_group_id\":$BAKERY}"
mk() { post /api/objects/products "{\"name\":\"$1\",\"product_group_id\":$2,\"location_id\":$3,\"qu_id_purchase\":2,\"qu_id_stock\":2,\"qu_id_consume\":2,\"qu_id_price\":2}" | id; }
LOC=$(get "/api/objects/products/$(product_id mac-Milk)" | python3 -c 'import sys,json;print(json.load(sys.stdin)["location_id"])')
mk mac-Cheddar "$CHEESE" "$LOC" >/dev/null
mk mac-Parmesan "$HARD" "$LOC" >/dev/null
echo "seeded: dairy=$DAIRY cheese=$CHEESE hard=$HARD bakery=$BAKERY"
