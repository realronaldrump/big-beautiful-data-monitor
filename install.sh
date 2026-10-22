#!/bin/zsh
# Builds Big Beautiful Data Monitor and installs it in /Applications, replacing any older copy.
# Usage: ./install.sh
set -e
cd "$(dirname "$0")"
mkdir -p build

echo "Building…"
if command -v xcodegen >/dev/null; then
  (cd App && xcodegen generate --quiet)
fi
if ! xcodebuild -project "App/Big Beautiful Data Monitor.xcodeproj" -scheme DataMonitor -configuration Release \
     -derivedDataPath build/release build > build/last-build.log 2>&1; then
  grep -E "error:" build/last-build.log | sort -u | head -20
  echo "The build failed, so nothing was installed. Details are in build/last-build.log."
  exit 1
fi

echo "Installing…"
pkill -x "Big Beautiful Data Monitor" 2>/dev/null && sleep 1 || true
rm -rf "/Applications/Big Beautiful Data Monitor.app"
ditto "build/release/Build/Products/Release/Big Beautiful Data Monitor.app" "/Applications/Big Beautiful Data Monitor.app"
open "/Applications/Big Beautiful Data Monitor.app"
echo "Done. Look for the small wave in your menu bar."
