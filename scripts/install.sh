#!/bin/bash
# Builds Prompt Menu into ~/Applications and adds its item to the Services menu.
# Usage: scripts/install.sh            (scripts/install.sh --uninstall to remove it)
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$HOME/Applications/Prompt Menu.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# A running copy keeps answering Services from its old code after the files are replaced, and Settings
# or a dialog it has open would be lost anyway. SIGTERM is a normal quit: it stops any model run too.
stop_running_copy() {
  pkill -f "$APP/Contents/MacOS/PromptMenu" || true
  for _ in 1 2 3 4 5 6; do
    pgrep -f "$APP/Contents/MacOS/PromptMenu" >/dev/null || return 0
    sleep 0.5
  done
  echo "Prompt Menu didn't quit; close it and run this again." >&2
  exit 1
}

if [ "${1:-}" = "--uninstall" ]; then
  stop_running_copy
  [ -d "$APP" ] && "$LSREGISTER" -u "$APP" || true
  rm -rf "$APP"
  /System/Library/CoreServices/pbs -update
  echo "Removed $APP"
  exit 0
fi

stop_running_copy
scripts/build.sh "$HOME/Applications"
"$LSREGISTER" -f "$APP"
# scripts/build.sh build leaves a copy with the same bundle id and version, and macOS can route the
# Services to it. Only the installed copy should answer them.
[ -d "build/Prompt Menu.app" ] && "$LSREGISTER" -u "build/Prompt Menu.app" || true
# Re-read every app's Services, so the new item shows without logging out.
/System/Library/CoreServices/pbs -update
echo "Installed $APP"
echo "Highlight text in any app, then right-click → Services → Rewrite as Agent Prompt."
