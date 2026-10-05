#!/usr/bin/env bash
#
# Confirms the SDK's public enums are non-exhaustive for host apps.
#
# Builds the DeepIDV and DeepIDVCore modules for the iOS Simulator, then
# type-checks a client file (.github/checks/fixtures/ExhaustiveClient.swift) that
# switches over `DeepIDVError.Kind` without `@unknown default`. The check
# passes only when the compiler rejects that switch in Swift 6 mode.
#
# Usage: .github/checks/check-nonexhaustive.sh [derived-data-path]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$ROOT/.github/checks/fixtures/ExhaustiveClient.swift"
DERIVED_DATA="${1:-$ROOT/.build/check-nonexhaustive}"
EXPECTED="may have additional unknown values"

cd "$ROOT"

echo "Building the DeepIDV modules for the iOS Simulator…"
xcodebuild build \
  -scheme DeepIDV \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES \
  -quiet

PRODUCTS="$DERIVED_DATA/Build/Products/Debug-iphonesimulator"
if [ ! -d "$PRODUCTS/DeepIDV.swiftmodule" ]; then
  echo "error: DeepIDV.swiftmodule was not produced in $PRODUCTS" >&2
  exit 1
fi

echo "Type-checking the exhaustive client switch…"
set +e
OUTPUT="$(xcrun --sdk iphonesimulator swiftc -typecheck \
  -swift-version 6 \
  -target "$(uname -m)-apple-ios15.0-simulator" \
  -I "$PRODUCTS" \
  "$FIXTURE" 2>&1)"
STATUS=$?
set -e

if [ "$STATUS" -eq 0 ]; then
  echo "error: the exhaustive switch compiled — a public enum is missing @nonexhaustive." >&2
  exit 1
fi

if ! printf '%s\n' "$OUTPUT" | grep -q "error:.*$EXPECTED"; then
  echo "error: the client failed to compile for an unexpected reason:" >&2
  printf '%s\n' "$OUTPUT" >&2
  exit 1
fi

echo "OK: a switch without '@unknown default' is rejected outside the package."
