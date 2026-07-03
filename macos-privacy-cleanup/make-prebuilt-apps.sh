#!/bin/bash
#
# make-prebuilt-apps.sh — assembles two double-clickable macOS app bundles
# WITHOUT needing macOS tools (a .app is just a folder with the right layout,
# so this works anywhere; only build-app.sh's osacompile route needs a Mac).
#
#   Privacy Cleanup Preview.app  → opens Terminal, runs the DRY RUN
#   Privacy Cleanup.app          → opens Terminal, shows plan, asks y/N, deletes
#
# Each app embeds its own copy of privacy-cleanup.sh (Contents/Resources/), so
# the .app is fully self-contained and can live in /Applications on its own.
# Re-run this script after changing privacy-cleanup.sh to refresh the copies.
#
# How the app works at runtime (chosen for a beta OS: fewest moving parts):
#   Contents/MacOS/launcher  — stub the OS executes on double-click; it just
#                              does `open -a Terminal <runner>` and exits.
#                              Using `open` instead of AppleScript avoids the
#                              "wants to control Terminal" Automation prompt.
#   Contents/Resources/run.command — runs the embedded script in that window.
#
set -eu

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="$DIR/privacy-cleanup.sh"
OUT="$DIR/prebuilt-apps"

[ -f "$SCRIPT" ] || { echo "ERROR: $SCRIPT not found" >&2; exit 1; }

# $1=app dir name  $2=bundle id  $3=mode args  $4=window title
build_one() {
  local app="$OUT/$1" bid="$2" args="$3" title="$4"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

  cat >"$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>${1%.app}</string>
	<key>CFBundleIdentifier</key>
	<string>$bid</string>
	<key>CFBundleExecutable</key>
	<string>launcher</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1.0.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
EOF

  # Stub the OS runs on double-click. LSUIElement=true above keeps it out of
  # the Dock; the visible UI is the Terminal window `open` creates.
  cat >"$app/Contents/MacOS/launcher" <<'EOF'
#!/bin/bash
HERE="$(cd "$(dirname "$0")/../Resources" && pwd)"
exec /usr/bin/open -a Terminal "$HERE/run.command"
EOF

  cat >"$app/Contents/Resources/run.command" <<EOF
#!/bin/bash
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]:-\$0}")" && pwd)"
clear
echo "$title"
echo
"\$DIR/privacy-cleanup.sh" $args
status=\$?
echo
echo "Finished (exit \$status). Press Return to close this window."
read -r _
EOF

  cp "$SCRIPT" "$app/Contents/Resources/privacy-cleanup.sh"
  chmod 755 "$app/Contents/MacOS/launcher" \
            "$app/Contents/Resources/run.command" \
            "$app/Contents/Resources/privacy-cleanup.sh"
  echo "built: $app"
}

build_one "Privacy Cleanup Preview.app" "local.privacycleanup.preview" "" \
  "macOS Privacy & Cleanup — PREVIEW (dry run, nothing will be deleted)"
build_one "Privacy Cleanup.app" "local.privacycleanup.apply" "--apply" \
  "macOS Privacy & Cleanup — APPLY (you will be asked y/N before anything is deleted)"

cat >"$OUT/READ ME FIRST.txt" <<'EOF'
Privacy Cleanup — prebuilt apps
===============================

  Privacy Cleanup Preview.app  — dry run: shows what would be deleted, deletes nothing
  Privacy Cleanup.app          — shows the plan, asks y/N in Terminal, then deletes

ONE-TIME SETUP (because these were downloaded, macOS quarantines them):
Open Terminal once and run, adjusting the path to where you put this folder:

    xattr -dr com.apple.quarantine ~/Downloads/prebuilt-apps

After that, double-click the apps like any other app, no Terminal needed.
(Alternative: double-click once, dismiss the warning, then System Settings >
Privacy & Security > "Open Anyway" — you'd have to do it per app, and possibly
again for the inner script, so the xattr line above is the easy way.)

These apps are unsigned (built from the open shell script in the repo, not
notarized with an Apple developer certificate) — that's all the warning means.

Each app embeds its own copy of privacy-cleanup.sh, so you can drag them to
/Applications and delete everything else. A run log is written to
~/.privacy-cleanup/logs/ each time.
EOF

echo "done: $OUT"
