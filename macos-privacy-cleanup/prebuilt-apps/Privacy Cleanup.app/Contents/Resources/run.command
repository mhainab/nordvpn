#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
clear
echo "macOS Privacy & Cleanup — APPLY (you will be asked y/N before anything is deleted)"
echo
"$DIR/privacy-cleanup.sh" --apply
status=$?
echo
echo "Finished (exit $status). Press Return to close this window."
read -r _
