#!/bin/bash
#
# privacy-cleanup.sh — one-click macOS privacy & cleanup tool
# ---------------------------------------------------------------------------
# Clears locally stored junk and privacy-sensitive data (browser caches/
# cookies/history/local-storage/sessions, user caches, logs, temp files,
# Quick Look thumbnails, .DS_Store, recent-items lists, clipboard) and flushes
# the DNS cache.
#
# SAFETY MODEL
#   * Runs as a DRY RUN by default: it prints exactly what would be removed and
#     roughly how much space would be reclaimed, and deletes nothing.
#   * Real deletion requires --apply (interactive y/N confirmation) or
#     --yes (non-interactive, implies --apply).
#   * Stays strictly user-level by default. System paths (/Library/Caches) are
#     only touched when you pass --system (and require root/sudo).
#   * Browser data targeting is surgical: caches/cookies/history/local storage/
#     sessions only. Bookmarks, saved passwords, autofill and preferences are
#     left alone.
#   * Quits any app whose data is being cleared before clearing it.
#   * Writes a timestamped log of everything it touches.
#   * Resilient: missing paths are skipped, per-item failures are logged and the
#     run continues.
#
# BETA-OS NOTE (macOS 26.x)
#   Apple moves data-store locations between releases. Every path below is
#   probed for existence before use, so unknown/renamed paths are simply
#   skipped rather than guessed at. Items that are especially likely to shift on
#   a beta OS are marked with a "VERSION-SENSITIVE" comment.
#
# Tested against the layout of macOS 12–15; written defensively for 26.x.
# Bash 3.2 compatible (the /bin/bash that ships with macOS).
# ---------------------------------------------------------------------------

# Intentionally NOT using `set -e`: we want to push through per-item failures.
set -u

VERSION="1.0.0"
SELF_NAME="$(basename "$0")"

# ----------------------------- defaults ------------------------------------
DRY_RUN=1          # 1 = dry run (default), 0 = really delete
ASSUME_YES=0       # 1 = skip the y/N prompt
DO_SYSTEM=0        # 1 = include /Library/Caches (needs root)
DO_TRASH=0         # 1 = empty Trash
DO_DLHIST=0        # 1 = clear download-history metadata
DO_BROWSERS=1
DO_CACHES=1
DO_LOGS=1
DO_TEMP=1
DO_QUICKLOOK=1
DO_DSSTORE=1
DO_RECENT=1
DO_CLIPBOARD=1
DO_DNS=1
ALLOW_NON_MACOS=0  # let the dry run be inspected on non-macOS hosts

LOG_DIR="${HOME}/.privacy-cleanup/logs"   # deliberately OUTSIDE ~/Library/Logs
LOG_FILE=""
ERR_SINK="/dev/null"   # where stderr from rm/find goes (set once log file exists)

# ----------------------------- counters ------------------------------------
TOTAL_KB=0
ITEMS=0
ACTIONS=0
FAILED=0

PHASE="scan"        # "scan" or "delete"
VERB="would remove"

# ----------------------------- usage ---------------------------------------
usage() {
  cat <<EOF
$SELF_NAME v$VERSION — macOS privacy & cleanup tool

USAGE
  $SELF_NAME [options]

By default this is a DRY RUN. It shows what would be deleted and how much space
would be freed, and changes nothing. Use --apply (or --yes) to delete.

MODES
  --apply                Actually delete. Shows the plan, then prompts y/N.
  -y, --yes              Actually delete without prompting (implies --apply).
  -n, --dry-run          Force dry run (default).

SCOPE TOGGLES (everything user-level is on by default)
  --system               Also clear /Library/Caches. Requires root/sudo.
  --trash                Also empty the Trash.
  --downloads-history    Also clear download-history metadata
                         (LSQuarantine DB + Safari Downloads.plist).
  --no-browsers          Skip browser data.
  --no-caches            Skip ~/Library/Caches.
  --no-logs              Skip ~/Library/Logs.
  --no-temp              Skip temp files (/tmp + per-user /var/folders temp).
  --no-quicklook         Skip Quick Look thumbnail cache.
  --no-dsstore           Skip .DS_Store removal.
  --no-recent            Skip recent-items lists.
  --no-clipboard         Skip clearing the clipboard.
  --no-dns               Skip flushing the DNS cache.

OTHER
  --log-dir DIR          Where to write the run log (default: $LOG_DIR).
  --allow-non-macos      Permit a dry run on a non-macOS host (for inspection).
  -h, --help             Show this help.
  --version              Print version.

EXAMPLES
  $SELF_NAME                         # safe preview, deletes nothing
  $SELF_NAME --apply                 # preview, then ask before deleting
  $SELF_NAME --yes --trash           # delete user-level data + empty Trash
  sudo $SELF_NAME --apply --system   # also clear /Library/Caches
EOF
}

# ----------------------------- arg parsing ---------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)             DRY_RUN=0 ;;
    -y|--yes)            DRY_RUN=0; ASSUME_YES=1 ;;
    -n|--dry-run)        DRY_RUN=1 ;;
    --system)            DO_SYSTEM=1 ;;
    --trash)             DO_TRASH=1 ;;
    --downloads-history) DO_DLHIST=1 ;;
    --no-browsers)       DO_BROWSERS=0 ;;
    --no-caches)         DO_CACHES=0 ;;
    --no-logs)           DO_LOGS=0 ;;
    --no-temp)           DO_TEMP=0 ;;
    --no-quicklook)      DO_QUICKLOOK=0 ;;
    --no-dsstore)        DO_DSSTORE=0 ;;
    --no-recent)         DO_RECENT=0 ;;
    --no-clipboard)      DO_CLIPBOARD=0 ;;
    --no-dns)            DO_DNS=0 ;;
    --allow-non-macos)   ALLOW_NON_MACOS=1 ;;
    --log-dir)           shift; LOG_DIR="${1:-$LOG_DIR}" ;;
    -h|--help)           usage; exit 0 ;;
    --version)           echo "$SELF_NAME $VERSION"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; echo "Try '$SELF_NAME --help'." >&2; exit 2 ;;
  esac
  shift
done

# ----------------------------- helpers -------------------------------------

# Append to the log file (once it exists) and echo to the terminal.
log() {
  if [ -n "$LOG_FILE" ]; then
    printf '%s\n' "$*" >>"$LOG_FILE" 2>/dev/null
  fi
  printf '%s\n' "$*"
}

# KB -> human readable.
human() {
  awk -v k="${1:-0}" 'BEGIN{
    split("KB MB GB TB PB", u, " ");
    i=1; v=k+0;
    while (v>=1024 && i<5){ v=v/1024; i++ }
    printf "%.1f %s", v, u[i]
  }'
}

# Disk usage of a path in KB (0 if unreadable/missing).
du_kb() {
  local kb
  kb="$(du -sk "$1" 2>/dev/null | awk 'NR==1{print $1}')"
  case "$kb" in ''|*[!0-9]*) echo 0 ;; *) echo "$kb" ;; esac
}

# Run a command as root when needed (no-op prefix if already root).
priv() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

# Does a directory contain at least one entry (including dotfiles)?
dir_has_children() {
  local d="$1" files
  [ -d "$d" ] || return 1
  local had=1
  shopt -s nullglob dotglob 2>/dev/null
  for files in "$d"/*; do
    had=0
    break
  done
  shopt -u nullglob dotglob 2>/dev/null
  return $had
}

# Low-level delete with error tolerance.
#   $1 = path, $2 = mode (tree|contents), $3 = use-priv (1/0)
do_delete() {
  local p="$1" mode="$2" usepriv="${3:-0}" child rc kids
  if [ "$mode" = "contents" ]; then
    shopt -s nullglob dotglob 2>/dev/null
    kids=("$p"/*)
    shopt -u nullglob dotglob 2>/dev/null
    for child in "${kids[@]}"; do
      if [ "$usepriv" = "1" ]; then
        priv rm -rf -- "$child" 2>>"$ERR_SINK"
      else
        rm -rf -- "$child" 2>>"$ERR_SINK"
      fi
      rc=$?
      if [ "$rc" -ne 0 ]; then
        FAILED=$((FAILED + 1))
        log "      ! could not remove: $child (continuing)"
      fi
    done
  else
    if [ "$usepriv" = "1" ]; then
      priv rm -rf -- "$p" 2>>"$ERR_SINK"
    else
      rm -rf -- "$p" 2>>"$ERR_SINK"
    fi
    rc=$?
    if [ "$rc" -ne 0 ]; then
      FAILED=$((FAILED + 1))
      log "      ! could not remove: $p (continuing)"
    fi
  fi
}

# Record (and, in delete phase, remove) a target.
#   $1 = path
#   $2 = mode: "tree" (remove the item) or "contents" (empty a directory)
#   $3 = human description
#   $4 = optional: "priv" to delete with elevated privileges
note_target() {
  local p="$1" mode="$2" desc="$3" usepriv=0
  [ "${4:-}" = "priv" ] && usepriv=1

  if [ "$mode" = "contents" ]; then
    dir_has_children "$p" || return 0
  else
    [ -e "$p" ] || return 0
  fi

  local kb
  kb="$(du_kb "$p")"
  TOTAL_KB=$((TOTAL_KB + kb))
  ITEMS=$((ITEMS + 1))

  log "  [$VERB] $desc"
  log "      path : $p"
  log "      size : $(human "$kb")"

  if [ "$PHASE" = "delete" ]; then
    do_delete "$p" "$mode" "$usepriv"
  fi
}

# Record a non-path action (clipboard, DNS, qlmanage...).
note_action() {
  ACTIONS=$((ACTIONS + 1))
  log "  [$VERB] $1"
}

# Quit a running app gracefully, then force it if still alive.
# Only ever called in the delete phase.
quit_app() {
  local appname="$1" proc="$2"
  if ! pgrep -x "$proc" >/dev/null 2>&1 && ! pgrep -f "$proc" >/dev/null 2>&1; then
    return 0
  fi
  log "      quitting $appname ..."
  osascript -e "tell application \"$appname\" to quit" >/dev/null 2>&1
  local i=0
  while [ "$i" -lt 10 ]; do
    pgrep -x "$proc" >/dev/null 2>&1 || pgrep -f "$proc" >/dev/null 2>&1 || break
    sleep 0.5
    i=$((i + 1))
  done
  if pgrep -x "$proc" >/dev/null 2>&1 || pgrep -f "$proc" >/dev/null 2>&1; then
    log "      $appname still running; forcing quit"
    pkill -x "$proc" >/dev/null 2>&1
    pkill -f "$proc" >/dev/null 2>&1
    sleep 1
  fi
}

# ----------------------------- categories ----------------------------------

cat_safari() {
  # VERSION-SENSITIVE: classic Safari keeps data in ~/Library/Safari, cookies in
  # ~/Library/Cookies and ~/Library/HTTPStorages, web storage in ~/Library/WebKit.
  # A future release could sandbox it under ~/Library/Containers/com.apple.Safari;
  # that path is probed too. Bookmarks (~/Library/Safari/Bookmarks.plist) and
  # iCloud tabs are deliberately NOT touched.
  local S="${HOME}/Library/Safari"
  [ "$PHASE" = "delete" ] && quit_app "Safari" "Safari"

  log "Safari:"
  note_target "${S}/History.db"            tree "Safari history"
  note_target "${S}/History.db-wal"        tree "Safari history (wal)"
  note_target "${S}/History.db-shm"        tree "Safari history (shm)"
  note_target "${S}/History.db-lock"       tree "Safari history (lock)"
  note_target "${S}/LastSession.plist"     tree "Safari last session"
  note_target "${S}/RecentlyClosedTabs.plist" tree "Safari recently closed tabs"
  note_target "${S}/LocalStorage"          contents "Safari local storage"
  note_target "${S}/Databases"             contents "Safari web databases"
  note_target "${HOME}/Library/WebKit/com.apple.Safari" contents "Safari WebKit storage"
  note_target "${HOME}/Library/HTTPStorages/com.apple.Safari" tree "Safari HTTP storage"
  note_target "${HOME}/Library/HTTPStorages/com.apple.Safari.binarycookies" tree "Safari cookies (HTTPStorages)"
  note_target "${HOME}/Library/Cookies/Cookies.binarycookies" tree "Shared cookie store (Safari)"
  note_target "${HOME}/Library/Saved Application State/com.apple.Safari.savedState" contents "Safari saved window state"
  # Sandboxed-Safari fallback (only if present).
  note_target "${HOME}/Library/Containers/com.apple.Safari/Data/Library/Caches" contents "Safari (containerized) caches"
}

# Shared logic for Chromium-family browsers (Chrome, Brave).
# Clears cache/cookies/history/local+session storage WITHOUT touching
# Bookmarks, "Login Data" (passwords), "Web Data" (autofill) or Preferences.
clean_chromium_profile() {
  local prof="$1" label="$2"
  note_target "${prof}/History"                  tree "$label history"
  note_target "${prof}/History-journal"          tree "$label history (journal)"
  note_target "${prof}/Visited Links"            tree "$label visited links"
  note_target "${prof}/Top Sites"                tree "$label top sites"
  note_target "${prof}/Top Sites-journal"        tree "$label top sites (journal)"
  note_target "${prof}/Network Action Predictor" tree "$label network predictor"
  note_target "${prof}/Cookies"                  tree "$label cookies"
  note_target "${prof}/Cookies-journal"          tree "$label cookies (journal)"
  note_target "${prof}/Network/Cookies"          tree "$label cookies (network)"
  note_target "${prof}/Network/Cookies-journal"  tree "$label cookies (network journal)"
  note_target "${prof}/Cache"                    contents "$label cache"
  note_target "${prof}/Code Cache"               contents "$label code cache"
  note_target "${prof}/GPUCache"                 contents "$label GPU cache"
  note_target "${prof}/Service Worker"           contents "$label service workers"
  note_target "${prof}/IndexedDB"                contents "$label IndexedDB"
  note_target "${prof}/Local Storage"            contents "$label local storage"
  note_target "${prof}/Session Storage"          contents "$label session storage"
  note_target "${prof}/Sessions"                 contents "$label sessions"
  note_target "${prof}/File System"              contents "$label file system storage"
  note_target "${prof}/Platform Notifications"   contents "$label notifications"
  note_target "${prof}/Current Session"          tree "$label current session"
  note_target "${prof}/Current Tabs"             tree "$label current tabs"
  note_target "${prof}/Last Session"             tree "$label last session"
  note_target "${prof}/Last Tabs"                tree "$label last tabs"
}

cat_chromium_browser() {
  # $1 = app name, $2 = process name, $3 = base "Application Support" dir, $4 = label
  local appname="$1" proc="$2" base="$3" label="$4" prof profiles
  [ -d "$base" ] || return 0
  [ "$PHASE" = "delete" ] && quit_app "$appname" "$proc"

  log "${label}:"
  # Profiles: Default, "Profile N", Guest Profile, System Profile.
  shopt -s nullglob 2>/dev/null
  profiles=("$base"/Default "$base"/Profile\ * "$base"/Guest\ Profile)
  shopt -u nullglob 2>/dev/null
  for prof in "${profiles[@]}"; do
    [ -d "$prof" ] || continue
    clean_chromium_profile "$prof" "$label ($(basename "$prof"))"
  done
  # Shared (non-bookmark) state.
  note_target "${base}/Crashpad"          contents "$label crash reports"
  note_target "${base}/component_crx_cache" contents "$label component cache"
  note_target "${HOME}/Library/Saved Application State/${5:-}" contents "$label saved window state"
}

cat_chrome() {
  cat_chromium_browser "Google Chrome" "Google Chrome" \
    "${HOME}/Library/Application Support/Google/Chrome" "Chrome" \
    "com.google.Chrome.savedState"
}

cat_brave() {
  cat_chromium_browser "Brave Browser" "Brave Browser" \
    "${HOME}/Library/Application Support/BraveSoftware/Brave-Browser" "Brave" \
    "com.brave.Browser.savedState"
}

cat_firefox() {
  # CONSERVATIVE: Firefox stores history AND bookmarks together in places.sqlite.
  # There is no safe way to wipe only history with plain file ops without taking
  # bookmarks with it, so places.sqlite is intentionally left alone. Cookies,
  # web/session storage, sessions and cache ARE cleared. See README for how to
  # clear Firefox history properly (Settings > Privacy, or about:support).
  local base="${HOME}/Library/Application Support/Firefox/Profiles" prof profiles
  [ -d "$base" ] || return 0
  [ "$PHASE" = "delete" ] && quit_app "Firefox" "firefox"

  log "Firefox:"
  shopt -s nullglob 2>/dev/null
  profiles=("$base"/*)
  shopt -u nullglob 2>/dev/null
  for prof in "${profiles[@]}"; do
    [ -d "$prof" ] || continue
    local label="Firefox ($(basename "$prof"))"
    note_target "${prof}/cookies.sqlite"          tree "$label cookies"
    note_target "${prof}/cookies.sqlite-wal"      tree "$label cookies (wal)"
    note_target "${prof}/cookies.sqlite-shm"      tree "$label cookies (shm)"
    note_target "${prof}/webappsstore.sqlite"     tree "$label local storage"
    note_target "${prof}/sessionstore.jsonlz4"    tree "$label session"
    note_target "${prof}/sessionstore-backups"    contents "$label session backups"
    note_target "${prof}/storage/default"         contents "$label site storage (IndexedDB/LS)"
    note_target "${prof}/storage/temporary"       contents "$label temporary storage"
    note_target "${prof}/cache2"                  contents "$label cache"
    note_target "${prof}/startupCache"            contents "$label startup cache"
    note_target "${prof}/thumbnails"              contents "$label thumbnails"
    log "      note: $label history/bookmarks (places.sqlite) left intact on purpose"
  done
  note_target "${HOME}/Library/Saved Application State/org.mozilla.firefox.savedState" contents "Firefox saved window state"
}

cat_browsers() {
  log ""
  log "== Browsers =="
  local any=0
  if [ -d "${HOME}/Library/Safari" ] || [ -e "/Applications/Safari.app" ]; then
    cat_safari; any=1
  fi
  if [ -d "${HOME}/Library/Application Support/Google/Chrome" ] || [ -e "/Applications/Google Chrome.app" ]; then
    cat_chrome; any=1
  fi
  if [ -d "${HOME}/Library/Application Support/BraveSoftware/Brave-Browser" ] || [ -e "/Applications/Brave Browser.app" ]; then
    cat_brave; any=1
  fi
  if [ -d "${HOME}/Library/Application Support/Firefox" ] || [ -e "/Applications/Firefox.app" ]; then
    cat_firefox; any=1
  fi
  [ "$any" -eq 0 ] && log "  (no supported browsers detected)"
}

cat_user_caches() {
  log ""
  log "== User caches (~/Library/Caches) =="
  note_target "${HOME}/Library/Caches" contents "User application caches"
}

cat_system_caches() {
  log ""
  log "== System caches (/Library/Caches) [--system] =="
  if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    log "  (will use sudo for deletion; you may be prompted for a password)"
  fi
  # NOTE: /System/Library/Caches is SIP-protected and intentionally NOT touched.
  note_target "/Library/Caches" contents "System application caches" priv
}

cat_logs() {
  log ""
  log "== Logs (~/Library/Logs) =="
  note_target "${HOME}/Library/Logs" contents "User logs"
  if [ "$DO_SYSTEM" -eq 1 ]; then
    # Conservative: only /Library/Logs. /private/var/log and the unified-log
    # store (/var/db/diagnostics) are system-managed and left alone.
    note_target "/Library/Logs" contents "System logs (/Library/Logs)" priv
  fi
}

cat_temp() {
  log ""
  log "== Temp files =="
  # Per-user temp dir under /var/folders (everything here is owned by you).
  local utmp
  utmp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"
  if [ -n "$utmp" ] && [ -d "$utmp" ]; then
    note_target "$utmp" contents "Per-user temp dir ($utmp)"
  fi

  # /tmp (a.k.a. /private/tmp) is shared. To avoid disrupting other users or
  # the system, we only consider entries OWNED BY YOU, and never the dir itself.
  if [ -d "/tmp" ]; then
    local me item kb owned_kb=0 owned_n=0 kids
    me="$(id -un)"
    shopt -s nullglob dotglob 2>/dev/null
    kids=(/tmp/*)
    shopt -u nullglob dotglob 2>/dev/null
    for item in "${kids[@]}"; do
      # Skip if not owned by current user.
      if [ "$(/usr/bin/stat -f '%Su' "$item" 2>/dev/null)" != "$me" ]; then
        continue
      fi
      kb="$(du_kb "$item")"
      owned_kb=$((owned_kb + kb))
      owned_n=$((owned_n + 1))
      TOTAL_KB=$((TOTAL_KB + kb))
      ITEMS=$((ITEMS + 1))
      log "  [$VERB] /tmp item (yours): $(basename "$item")"
      log "      path : $item"
      log "      size : $(human "$kb")"
      if [ "$PHASE" = "delete" ]; then
        do_delete "$item" tree 0
      fi
    done
    [ "$owned_n" -eq 0 ] && log "  (no user-owned items in /tmp)"
  fi
}

cat_quicklook() {
  log ""
  log "== Quick Look thumbnail cache =="
  # VERSION-SENSITIVE: the cache lives under the per-user DARWIN_USER_CACHE_DIR
  # and its exact name has changed across releases. We report a size estimate
  # and prefer the supported reset command `qlmanage -r cache`.
  local ucache qldir
  ucache="$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null)"
  if [ -n "$ucache" ]; then
    for qldir in \
      "${ucache}com.apple.QuickLook.thumbnailcache" \
      "${ucache}/com.apple.QuickLook.thumbnailcache"; do
      if [ -d "$qldir" ]; then
        local kb; kb="$(du_kb "$qldir")"
        TOTAL_KB=$((TOTAL_KB + kb)); ITEMS=$((ITEMS + 1))
        log "  [$VERB] Quick Look thumbnail cache"
        log "      path : $qldir"
        log "      size : $(human "$kb")"
        break
      fi
    done
  fi
  if [ "$PHASE" = "delete" ]; then
    if command -v qlmanage >/dev/null 2>&1; then
      log "      running: qlmanage -r cache"
      qlmanage -r cache >/dev/null 2>&1
    fi
  else
    note_action "reset Quick Look cache (qlmanage -r cache)"
  fi
}

cat_dsstore() {
  log ""
  log "== .DS_Store files (under \$HOME) =="
  # Scoped to $HOME so we never traverse network/other volumes. Only your files.
  local count size_kb
  count="$(find "$HOME" -xdev -type f -name '.DS_Store' 2>/dev/null | wc -l | tr -d ' ')"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "$count" -eq 0 ]; then
    log "  (none found)"
    return 0
  fi
  # Rough size estimate.
  size_kb="$(find "$HOME" -xdev -type f -name '.DS_Store' -print0 2>/dev/null \
    | xargs -0 du -k 2>/dev/null | awk '{s+=$1} END{print s+0}')"
  case "$size_kb" in ''|*[!0-9]*) size_kb=0 ;; esac
  TOTAL_KB=$((TOTAL_KB + size_kb)); ITEMS=$((ITEMS + 1))
  log "  [$VERB] $count .DS_Store file(s)"
  log "      size : $(human "$size_kb")"
  if [ "$PHASE" = "delete" ]; then
    find "$HOME" -xdev -type f -name '.DS_Store' -delete 2>>"$ERR_SINK" \
      || { FAILED=$((FAILED + 1)); log "      ! some .DS_Store files could not be removed"; }
  fi
}

cat_recent() {
  log ""
  log "== Recent-items lists =="
  # The Shared File List backs "Recent Items", recent apps, recent servers, and
  # per-app recent documents. Apps repopulate these as you use them.
  note_target "${HOME}/Library/Application Support/com.apple.sharedfilelist" contents "Recent items (Shared File List)"
  note_target "${HOME}/Library/Recent Servers.sfl3" tree "Recent servers"
}

cat_clipboard() {
  log ""
  log "== Clipboard =="
  if [ "$PHASE" = "delete" ]; then
    if command -v pbcopy >/dev/null 2>&1; then
      : | pbcopy >/dev/null 2>&1
      log "  [removing] clipboard contents cleared"
    fi
  else
    note_action "clear clipboard contents (pbcopy)"
  fi
}

cat_dns() {
  log ""
  log "== DNS cache =="
  # VERSION-SENSITIVE: the flush incantation has changed over the years. The
  # modern (10.11+) form is the two commands below. They require root.
  if [ "$PHASE" = "delete" ]; then
    log "  flushing DNS cache (dscacheutil + mDNSResponder) ..."
    priv dscacheutil -flushcache >/dev/null 2>&1
    priv killall -HUP mDNSResponder >/dev/null 2>&1
    log "  [done] DNS cache flushed"
  else
    note_action "flush DNS cache (dscacheutil -flushcache; killall -HUP mDNSResponder)"
  fi
}

cat_trash() {
  log ""
  log "== Trash [--trash] =="
  note_target "${HOME}/.Trash" contents "Trash"
}

cat_download_history() {
  log ""
  log "== Download-history metadata [--downloads-history] =="
  # The LSQuarantine DB records "downloaded from the internet" provenance.
  note_target "${HOME}/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2" tree "Quarantine events (download provenance)"
  note_target "${HOME}/Library/Safari/Downloads.plist" tree "Safari download list"
}

# ----------------------------- driver --------------------------------------
run_phase() {
  PHASE="$1"
  if [ "$PHASE" = "scan" ]; then VERB="would remove"; else VERB="removing"; fi
  TOTAL_KB=0; ITEMS=0; ACTIONS=0; FAILED=0

  [ "$DO_BROWSERS"  -eq 1 ] && cat_browsers
  [ "$DO_CACHES"    -eq 1 ] && cat_user_caches
  [ "$DO_SYSTEM"    -eq 1 ] && cat_system_caches
  [ "$DO_LOGS"      -eq 1 ] && cat_logs
  [ "$DO_TEMP"      -eq 1 ] && cat_temp
  [ "$DO_QUICKLOOK" -eq 1 ] && cat_quicklook
  [ "$DO_DSSTORE"   -eq 1 ] && cat_dsstore
  [ "$DO_RECENT"    -eq 1 ] && cat_recent
  [ "$DO_CLIPBOARD" -eq 1 ] && cat_clipboard
  [ "$DO_DNS"       -eq 1 ] && cat_dns
  [ "$DO_TRASH"     -eq 1 ] && cat_trash
  [ "$DO_DLHIST"    -eq 1 ] && cat_download_history
}

# ----------------------------- preflight -----------------------------------
OS="$(uname -s 2>/dev/null)"
if [ "$OS" != "Darwin" ]; then
  if [ "$ALLOW_NON_MACOS" -eq 1 ] && [ "$DRY_RUN" -eq 1 ]; then
    echo "WARNING: not running on macOS ($OS). Continuing dry run for inspection;" >&2
    echo "         most paths will be absent and skipped." >&2
  else
    echo "ERROR: this tool only runs on macOS (detected: ${OS:-unknown})." >&2
    echo "       Use --allow-non-macos with a dry run to inspect it elsewhere." >&2
    exit 1
  fi
fi

if [ "$DO_SYSTEM" -eq 1 ] && [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: --system needs root and sudo is unavailable. Re-run with sudo." >&2
    exit 1
  fi
fi

# Set up logging.
mkdir -p "$LOG_DIR" 2>/dev/null
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/cleanup-${TS}.log"
: >"$LOG_FILE" 2>/dev/null || LOG_FILE=""
ERR_SINK="${LOG_FILE:-/dev/null}"

log "============================================================"
log " macOS Privacy & Cleanup — $SELF_NAME v$VERSION"
log " date     : $(date)"
if command -v sw_vers >/dev/null 2>&1; then
  log " macOS    : $(sw_vers -productVersion 2>/dev/null) (build $(sw_vers -buildVersion 2>/dev/null))"
fi
log " user     : $(id -un) (uid $(id -u))"
log " mode     : $([ "$DRY_RUN" -eq 1 ] && echo 'DRY RUN (no changes)' || echo 'APPLY (will delete)')"
log " system   : $([ "$DO_SYSTEM" -eq 1 ] && echo on || echo off)   trash: $([ "$DO_TRASH" -eq 1 ] && echo on || echo off)   downloads-history: $([ "$DO_DLHIST" -eq 1 ] && echo on || echo off)"
log " log file : ${LOG_FILE:-<none>}"
log "============================================================"

# ----------------------------- scan pass -----------------------------------
log ""
log "################  PLAN (nothing deleted yet)  ################"
run_phase scan

PLAN_KB="$TOTAL_KB"; PLAN_ITEMS="$ITEMS"; PLAN_ACTIONS="$ACTIONS"
log ""
log "------------------------------------------------------------"
log "Plan summary: ${PLAN_ITEMS} item group(s), ~$(human "$PLAN_KB") reclaimable, ${PLAN_ACTIONS} action(s)."
log "------------------------------------------------------------"

if [ "$DRY_RUN" -eq 1 ]; then
  log ""
  log "DRY RUN complete — nothing was deleted."
  log "Re-run with --apply (asks for confirmation) or --yes (no prompt) to delete."
  log "Log: ${LOG_FILE:-<none>}"
  exit 0
fi

# ----------------------------- confirm -------------------------------------
if [ "$ASSUME_YES" -ne 1 ]; then
  log ""
  printf 'Proceed and DELETE the items above? [y/N] '
  ans=""
  # Prefer the controlling terminal (so the prompt works when launched from a
  # double-clicked .command); fall back to stdin. The group redirect keeps a
  # missing /dev/tty from leaking a shell error message.
  if ! { read -r ans </dev/tty; } 2>/dev/null; then
    read -r ans 2>/dev/null || ans=""
  fi
  case "$ans" in
    y|Y|yes|YES|Yes) ;;
    *) log "Aborted by user. Nothing deleted."; log "Log: ${LOG_FILE:-<none>}"; exit 0 ;;
  esac
fi

# ----------------------------- delete pass ---------------------------------
log ""
log "################  APPLYING  ################"
run_phase delete

log ""
log "------------------------------------------------------------"
log "Done. Processed ${ITEMS} item group(s), reclaimed ~$(human "$TOTAL_KB"), ${ACTIONS} action(s)."
if [ "$FAILED" -gt 0 ]; then
  log "Note: ${FAILED} item(s) could not be removed (permissions or in use). See log."
fi
log "Log: ${LOG_FILE:-<none>}"
log "------------------------------------------------------------"
exit 0
