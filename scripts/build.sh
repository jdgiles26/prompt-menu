#!/bin/bash
# Builds "Prompt Menu.app" into the given directory. Adapted from Finder Menu's build script.
# Usage: scripts/build.sh <output-dir>
set -euo pipefail
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
cd "$(dirname "$0")/.."

APP="$OUT/Prompt Menu.app"
TARGET="$(uname -m)-apple-macos13.0"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/App-Info.plist "$APP/Contents/Info.plist"

xcrun swiftc -swift-version 5 -O -sdk "$SDK" -target "$TARGET" \
  -module-name PromptMenu -framework Cocoa \
  Sources/PromptMenu/*.swift Sources/Core/*.swift -o "$APP/Contents/MacOS/PromptMenu"

# Ad-hoc signature ("Sign to Run Locally"). The linker already ad-hoc signs, so hide codesign's notice.
codesign --force -s - "$APP" 2> >(grep -v "replacing existing signature" >&2)
