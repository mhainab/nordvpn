#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
clear
echo "macOS Privacy & Cleanup — PREVIEW (dry run, nothing will be deleted)"
echo
"$DIR/privacy-cleanup.sh" 
status=$?
echo
echo "Finished (exit $status). Press Return to close this window."
read -r _
