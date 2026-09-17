#!/usr/bin/env bash
# Runs a SwiftPM command and prints only the lines worth reading.
#
# swift-openapi-generator emits ~2.7 MB of Swift, so a raw `swift build` buries
# real diagnostics under generated-code deprecation warnings and multi-kilobyte
# frontend command lines.
set -uo pipefail
cd "$(dirname "$0")/.."
swift "${@:-build}" 2>&1 \
    | grep -vE "Source files for target|^Failed frontend command:|swift-frontend -frontend|builtin-Swift" \
    | grep -vE "^\s*\[0;3[0-9]m" \
    | grep -viE "warning:.*deprecat|DeprecatedDeclaration|^\\s+'.*' was deprecated" \
    | sed -E 's/\x1b\[[0-9;]*m//g'
exit "${PIPESTATUS[0]}"
