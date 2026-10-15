#!/bin/bash
# Builds Prompt Menu into ~/Applications and adds its item to the Services menu.
# Usage: scripts/install.sh            (scripts/install.sh --uninstall to remove it)
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$HOME/Applications/Prompt Menu.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ "${1:-}" = "--uninstall" ]; then
  [ -d "$APP" ] && "$LSREGISTER" -u "$APP" || true
  rm -rf "$APP"
  /System/Library/CoreServices/pbs -update
  echo "Removed $APP"
  exit 0
fi

scripts/build.sh "$HOME/Applications"
"$LSREGISTER" -f "$APP"
# Re-read every app's Services, so the new item shows without logging out.
/System/Library/CoreServices/pbs -update
echo "Installed $APP"
echo "Highlight text in any app, then right-click → Services → Rewrite as Agent Prompt."
