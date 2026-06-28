# macOS Privacy & Cleanup Tool

A one-click, **safe-by-default** privacy and cleanup tool for your own Mac.
It clears locally stored junk and privacy-sensitive data (browser
caches/cookies/history/local storage/sessions, user caches, logs, temp files,
Quick Look thumbnails, `.DS_Store`, recent-items lists, the clipboard) and
flushes the DNS cache.

Built and tuned for a personal machine: **14" MacBook Pro (Apple M5, 24 GB),
macOS 26.6 beta**. It's a plain `bash` script (works with the `/bin/bash` that
ships with macOS) plus double-clickable launchers, so you never have to open
Terminal manually.

> **It is a DRY RUN by default.** It shows exactly what it *would* delete and
> roughly how much space that frees, and changes nothing until you explicitly
> ask it to with `--apply` (which then asks for a y/N confirmation) or `--yes`.

---

## Files

| File | What it is |
|---|---|
| `privacy-cleanup.sh` | The tool. Run it directly or via the launchers. |
| `Privacy Cleanup (Preview).command` | Double-click → safe preview (dry run). |
| `Privacy Cleanup (Apply).command` | Double-click → shows the plan, asks y/N, then deletes. |
| `build-app.sh` | Optional: builds a real `Privacy Cleanup.app` (AppleScript wrapper). |

## Quick start

1. Download/clone this folder to your Mac (e.g. `~/Tools/macos-privacy-cleanup`).
2. Make things runnable once (Finder strips the executable bit on downloads):
   ```bash
   cd ~/Tools/macos-privacy-cleanup
   chmod +x privacy-cleanup.sh build-app.sh "Privacy Cleanup (Preview).command" "Privacy Cleanup (Apply).command"
   ```
3. **Double-click `Privacy Cleanup (Preview).command`** to see what it would do.
   - First time: macOS Gatekeeper may block it. Right-click → **Open**, then
     **Open** again. (Or run from Terminal, which sidesteps the prompt.)
4. When you're happy, **double-click `Privacy Cleanup (Apply).command`** and
   answer `y` at the confirmation prompt.

## Command-line usage

```bash
./privacy-cleanup.sh                       # safe preview (dry run), deletes nothing
./privacy-cleanup.sh --apply               # preview, then ask y/N before deleting
./privacy-cleanup.sh --yes                 # delete user-level data, no prompt
./privacy-cleanup.sh --yes --trash         # also empty the Trash
sudo ./privacy-cleanup.sh --apply --system # also clear /Library/Caches (needs root)
./privacy-cleanup.sh --help                # full option list
```

### Modes
- `--apply` — really delete; shows the plan, then prompts y/N.
- `-y, --yes` — really delete without prompting (implies `--apply`; for scripts/cron).
- `-n, --dry-run` — force the default dry run.

### Scope toggles
Everything **user-level** is on by default. Extra scope is opt-in:
- `--system` — also clear `/Library/Caches` (root/sudo required).
- `--trash` — also empty the Trash.
- `--downloads-history` — also clear download-history metadata
  (the LSQuarantine "downloaded from the internet" DB + Safari's `Downloads.plist`).
- `--no-browsers`, `--no-caches`, `--no-logs`, `--no-temp`, `--no-quicklook`,
  `--no-dsstore`, `--no-recent`, `--no-clipboard`, `--no-dns` — skip a category.

### Other
- `--log-dir DIR` — where to write the run log (default `~/.privacy-cleanup/logs`).
- `--allow-non-macos` — permit a *dry run* on a non-Mac host, for inspection.

## What gets cleared

| Category | Default | Notes |
|---|---|---|
| **Browsers** (Safari, Chrome, Firefox, Brave — whichever are installed) | ✅ | Caches, cookies, history, local/session storage, sessions. The browser is **quit first**. **Bookmarks, saved passwords, autofill and preferences are NOT touched.** |
| **User caches** `~/Library/Caches` | ✅ | Contents cleared; the folder remains. |
| **User logs** `~/Library/Logs` | ✅ | Contents cleared. |
| **Temp files** | ✅ | Your per-user temp dir under `/var/folders` (via `getconf DARWIN_USER_TEMP_DIR`), plus **only your own** items in `/tmp`. |
| **Quick Look thumbnails** | ✅ | Reset with the supported `qlmanage -r cache`. |
| **`.DS_Store`** | ✅ | Removed under `$HOME` only (won't cross onto other/network volumes). |
| **Recent-items lists** | ✅ | Shared File List (Recent Items / apps / servers). Apps rebuild these as you use them. |
| **Clipboard** | ✅ | Cleared via `pbcopy`. |
| **DNS cache** | ✅ | `dscacheutil -flushcache` + `killall -HUP mDNSResponder` (needs root; the script elevates only this step if needed). |
| **System caches** `/Library/Caches` | ⛔ flag | `--system` + sudo. `/System/Library/Caches` (SIP-protected) is never touched. |
| **Trash** | ⛔ flag | `--trash`. |
| **Download-history metadata** | ⛔ flag | `--downloads-history`. |

### Firefox history caveat
Firefox stores **history and bookmarks together** in `places.sqlite`. There is
no safe way to wipe only history with plain file operations without taking your
bookmarks with it, so the script **leaves `places.sqlite` alone**. To clear
Firefox history properly use **Firefox → Settings → Privacy & Security → Clear
Data / History**, or set it to clear history on exit.

## Safety model

- **Dry run by default**; deletion needs `--apply` (with y/N) or `--yes`.
- **User-level by default.** System paths require `--system` + sudo.
- **Surgical browser targeting** — only cache/cookie/history/storage files, never
  bookmarks, passwords, autofill, extensions or preferences.
- **Quits apps first** so it never corrupts a live database.
- **Resilient** — missing paths are skipped; a permission error or in-use file is
  logged and the run continues instead of aborting.
- **Timestamped log** of everything it touched, written to
  `~/.privacy-cleanup/logs/cleanup-YYYYMMDD-HHMMSS.log` (deliberately *outside*
  `~/Library/Logs` so it isn't deleted mid-run).

### A note on running on a beta OS (macOS 26.6)
Apple shifts data-store locations between releases. The script **probes every
path for existence before using it**, so anything renamed/moved is simply
skipped rather than guessed at. Items most likely to move on a beta are flagged
with `VERSION-SENSITIVE` comments in the source (Safari storage locations, the
Quick Look cache path, and the DNS-flush commands). Start with the **preview**
after each OS update and skim the plan before applying.

## Optional: make it a real app

**Easiest (this repo):**
```bash
./build-app.sh            # builds "Privacy Cleanup.app" (runs the preview)
./build-app.sh --apply    # builds "Privacy Cleanup (Apply).app"
```
Then drag the `.app` to `/Applications` or your Dock. First launch may need a
right-click → **Open**, and macOS will ask to let it control Terminal
(System Settings → Privacy & Security → Automation).

**Or with Automator:**
1. Open **Automator** → **New** → **Application**.
2. Add the **Run Shell Script** action.
3. Set *Shell* to `/bin/bash` and paste (adjust the path):
   ```bash
   "$HOME/Tools/macos-privacy-cleanup/privacy-cleanup.sh" --apply
   ```
4. Save as an app. (Automator's "Run Shell Script" has no terminal window, so
   the y/N prompt won't appear — use `--yes` for a true no-interaction app, or
   prefer the `.command` launcher / `build-app.sh` which keep a Terminal open.)

---

## Honest scope: what this tool does and does NOT do

You said you care about **fingerprinting and tracking**, not just disk hygiene.
Here's the straight answer.

### ✅ What it genuinely covers
- **Local data cleanup / "forget me on this machine."** Caches, cookies,
  history, local/session storage, logs, temp files, thumbnails, `.DS_Store`,
  recent items, clipboard, DNS cache. Good for reclaiming space and wiping
  *locally stored* traces of what you did.
- **Resetting stored cookies and site storage**, which clears *existing*
  cookie-based tracking state and logs you out of sites. Combined with a DNS
  flush, it's a solid periodic "reset."

### ⚠️ What it only partly helps with
- **Cookie/tracking-state tracking.** Deleting cookies removes *current* tracking
  identifiers, but they're **recreated the next time you browse** unless you
  also block them at the source. This tool is a reset button, not a shield.
- **Download/quarantine provenance** is only cleared with `--downloads-history`.

### ❌ What it fundamentally CANNOT do
Cleaning local files does nothing about how you look to **remote servers** while
you browse. In particular it cannot stop:

- **Browser fingerprinting.** Sites identify you from your *configuration*, not
  stored files: User-Agent, screen/canvas/WebGL/audio signatures, installed
  fonts, timezone, language, hardware concurrency, etc. Wiping caches doesn't
  change any of that — your fingerprint is the same after cleanup.
- **IP-address tracking.** Your IP is visible to every site and your ISP
  regardless of how clean your disk is.
- **Network-level / DNS tracking.** Flushing the DNS *cache* clears local
  lookups; it does not stop your DNS resolver (often your ISP) from seeing and
  logging the domains you visit.
- **Server-side / account-based tracking.** Anything tied to a logged-in account
  (Google, Meta, etc.) or to first-party server logs is untouchable from your
  Mac.
- **Supercookies / ETag / TLS-session resumption tracking** and similar
  stateful-but-not-cookie mechanisms are largely out of scope.

### 🧰 What you'd actually need for fingerprinting/tracking defense
Use the tool below **in addition to** this cleaner, not instead of it:

| Goal | Use |
|---|---|
| Reduce fingerprinting | A browser built for it: **Tor Browser** (best, standardizes your fingerprint), or **Brave** (fingerprint randomization + Shields), or **Firefox** with `privacy.resistFingerprinting` / Arkenfox user.js. Safari's built-in protections help but are weaker here. |
| Block trackers/ads at the source | A content blocker / **uBlock Origin** (Firefox/Brave/Chrome), or Safari content-blocker extensions; Brave Shields. |
| Hide DNS lookups | **Encrypted DNS** (DoH/DoT) to a privacy resolver (Quad9, Cloudflare, NextDNS), or **DNS filtering** (NextDNS, Pi-hole) to block tracker domains network-wide. |
| Hide your IP | A reputable **VPN** (e.g. NordVPN) for IP/ISP-level privacy, or **Tor** for stronger anonymity (slower). |
| Strongest anonymity | **Tor Browser** end-to-end; avoid logging into personal accounts. |
| Auto-forget per session | Browser "clear on exit" + container/profile isolation, so tracking state never accumulates between sessions. |

**Bottom line:** this script is an excellent *local hygiene + reset* tool and
covers your "clear locally stored data" goals well. For *fingerprinting and
tracking resistance you need browser-level defenses (privacy browser + content
blocker), encrypted/filtered DNS, and a VPN or Tor* — those operate on the live
network traffic and browser configuration that a disk cleaner can't reach.
