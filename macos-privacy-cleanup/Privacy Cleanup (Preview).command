#!/bin/bash
# Double-clickable launcher: SAFE PREVIEW (dry run).
# Shows exactly what would be deleted and how much space would be freed.
# Deletes nothing. Use the "Apply" launcher (or run with --apply) to delete.

# Resolve the directory this .command lives in, even if double-clicked.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

clear
echo "macOS Privacy & Cleanup — PREVIEW (dry run, nothing will be deleted)"
echo "Script: $DIR/privacy-cleanup.sh"
echo

"$DIR/privacy-cleanup.sh" "$@"
status=$?

echo
echo "Preview finished (exit $status). This was a dry run — nothing was deleted."
echo "Press Return to close this window."
read -r _
