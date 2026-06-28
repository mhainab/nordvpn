#!/bin/bash
#
# build-app.sh — OPTIONAL. Builds a double-clickable "Privacy Cleanup.app"
# (a tiny AppleScript app) that opens Terminal and runs the cleanup script.
# This is the no-Automator way to get a real .app in your Dock/Applications.
#
# Must be run ON macOS (it uses osacompile, which ships with macOS).
#
# Usage:
#   ./build-app.sh             # builds an app that runs the SAFE PREVIEW
#   ./build-app.sh --apply     # builds an app that runs APPLY (asks y/N first)
#
set -u

if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: build-app.sh must run on macOS (needs osacompile)." >&2
  exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="$DIR/privacy-cleanup.sh"

if [ "${1:-}" = "--apply" ]; then
  MODE_ARGS="--apply"
  APP_NAME="Privacy Cleanup (Apply).app"
else
  MODE_ARGS=""
  APP_NAME="Privacy Cleanup.app"
fi

APP_PATH="$DIR/$APP_NAME"
rm -rf "$APP_PATH"

# Escape embedded paths for AppleScript string literals.
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
SCRIPT_ESC="$(esc "$SCRIPT")"

# The app opens Terminal and runs the script; Terminal stays open so you can
# read the plan and (in apply mode) answer the y/N prompt.
read -r -d '' APPLESCRIPT <<EOF
on run
	set theCmd to quoted form of "$SCRIPT_ESC"
	tell application "Terminal"
		activate
		do script (theCmd & " $MODE_ARGS")
	end tell
end run
EOF

osacompile -o "$APP_PATH" -e "$APPLESCRIPT"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "osacompile failed (exit $rc)." >&2
  exit "$rc"
fi

echo "Built: $APP_PATH"
echo "Double-click it (or drag it to /Applications or your Dock) to launch."
echo "Note: the first launch may need a right-click > Open to clear Gatekeeper,"
echo "and macOS may ask to allow it to control Terminal (System Settings > Privacy)."
