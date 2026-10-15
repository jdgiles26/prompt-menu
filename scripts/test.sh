#!/bin/bash
# Builds and runs the tests in Tests/ against Sources/Core.
# Usage: scripts/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Only Sources/Core: Sources/PromptMenu starts the app, and Tests/main.swift is the entry point here.
shopt -s nullglob
xcrun swiftc -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macos13.0" \
  -module-name PromptMenuTests -framework Cocoa \
  Tests/*.swift Sources/Core/*.swift \
  -o "$WORK/tests"
"$WORK/tests"
