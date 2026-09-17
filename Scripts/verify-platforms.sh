#!/usr/bin/env bash
# Builds every product for every Apple platform the package claims to support.
#
# `swift build` only ever covers the host, so the platform-conditional code in
# VictualUI is otherwise unverified until someone opens the package in an app.
#
# Usage: Scripts/verify-platforms.sh [scheme]   (default: VictualUI)
set -uo pipefail
cd "$(dirname "$0")/.."

SCHEME="${1:-VictualUI}"
DESTINATIONS=(
    "generic/platform=macOS"
    "generic/platform=iOS"
    "generic/platform=iOS Simulator"
    "generic/platform=tvOS"
    "generic/platform=watchOS"
    "generic/platform=visionOS"
)

# `-skipPackagePluginValidation` is required because VictualAPI runs the
# swift-openapi-generator build plugin; without it xcodebuild refuses to run an
# unvalidated plugin in a non-interactive session.
COMMON=(-scheme "$SCHEME" -skipPackagePluginValidation -skipMacroValidation -quiet)

status=0
for destination in "${DESTINATIONS[@]}"; do
    printf '%-40s' "$destination"
    if output=$(xcodebuild "${COMMON[@]}" -destination "$destination" build 2>&1); then
        echo "ok"
    else
        echo "FAILED"
        echo "$output" | grep -E "error:" | sort -u | sed 's/^/    /' | head -10
        status=1
    fi
done
exit "$status"
