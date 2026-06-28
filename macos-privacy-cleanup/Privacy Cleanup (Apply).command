#!/bin/bash
# Double-clickable launcher: APPLY (really delete).
# It still shows the full plan first and then asks for y/N confirmation in this
# window before deleting anything. Answer "y" to proceed, anything else aborts.
#
# This launcher does user-level cleanup only. For system caches (/Library/Caches)
# run the script from Terminal with: sudo ./privacy-cleanup.sh --apply --system

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

clear
echo "macOS Privacy & Cleanup — APPLY"
echo "You will see the full plan, then be asked to confirm before anything is deleted."
echo "Script: $DIR/privacy-cleanup.sh"
echo

"$DIR/privacy-cleanup.sh" --apply "$@"
status=$?

echo
echo "Finished (exit $status)."
echo "Press Return to close this window."
read -r _
