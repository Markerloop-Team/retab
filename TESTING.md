# Testing Retab by hand

Retab has no automated tests yet: almost everything it does goes through the window server and other
apps' accessibility, which a test runner cannot stand in for. CI builds the app and checks that it
never uses Screen Recording. Everything else is this list.

Run it on a release candidate, on as many different Macs as you can. Mark each line with the date,
the Mac and macOS version, and ✅ / ❌ / — (not tried). Two helpers make it easier:

- `Retab.app/Contents/MacOS/Retab --show` puts the running Retab's panel up for two seconds, without the keyboard.
- `Retab.app/Contents/MacOS/Retab --dump` writes what Retab sees to `~/Library/Logs/Retab-diagnostics.txt` (window titles inside — delete it after).
- What Retab did is in `~/Library/Logs/Retab.log`, without window titles.

## The shortcut

| # | Check | How |
|---|---|---|
| 1 | Command-Tab opens Retab's panel; a quick tap switches to the previous app without the panel | press and hold / tap |
| 2 | Shift-Tab, the arrow keys, Escape and a mouse click work in the panel | |
| 3 | The system's own switcher is back after Quit Retab, after `kill`, and after Force Quit | `hk`-style check of symbolic hot key 1, or just press Command-Tab |
| 4 | A shortcut changed in System Settings → Keyboard → Shortcuts is the one Retab takes | change it, restart Retab |
| 5 | Command-Space and other shortcuts with Command still work while Retab runs | |
| 6 | With AltTab (or another switcher) running, Retab still takes Command-Tab | |

## Windows

| # | Check | How |
|---|---|---|
| 7 | Windows on other desktops and in full screen are in the panel, also on the first press after Retab starts | restart Retab while in a full-screen app, press at once |
| 8 | Minimized windows and hidden apps are in the panel and say so in the subtitle | |
| 9 | Closing a full-screen window does not make the panel disappear afterwards | |
| 10 | Many apps: the row shrinks and wraps; many windows of one app: still one icon | 30+ apps, 40 windows |
| 11 | Two displays: the panel opens on the display with the pointer | |
| 11a | Drag a file from Finder, press Command-Tab, drop it on an app's icon: it opens there; drop a link on a Chrome profile's icon: it opens in that profile; let go of Command over an icon mid-drag: Retab switches and the drag goes on | |

## Chrome profiles

| # | Check | How |
|---|---|---|
| 12 | Each profile is its own icon, with the account's picture and the profile's colour | 3+ profiles, windows on different desktops |
| 13 | A window with no site open (only the new tab page) still gets its profile | |
| 14 | Renaming a profile or changing its colour shows within a minute | |
| 15 | Chrome in another language | |

## Install

| # | Check | How |
|---|---|---|
| 16 | A fresh clone builds with only the Command Line Tools, and the app runs | `git clone`, `./build.sh` |
| 17 | Without `tools/make_cert.sh` the build is signed ad hoc and works; Accessibility must be granted again after each rebuild | |
| 18 | macOS 14 and macOS 15 | |

## Results

### 25 Nov 2026 — MacBook (Apple silicon), macOS 26.6, one display, Chrome in English

| # | Result | Notes |
|---|---|---|
| 1 | ✅ | by the owner |
| 2 | — | |
| 3 | ✅ | Quit and `kill`: the app gives it back. `kill -9`: the watcher gave it back within a second |
| 4 | — | not tried: it changes the owner's own shortcut |
| 5 | ✅ | Command-Space, by the owner |
| 6 | ✅ | AltTab on its default Option-Tab: Retab took Command-Tab as usual. If the system ever refuses Command-Tab, Retab falls back to Option-Tab — the same as AltTab's |
| 7 | ✅ | after the fix of 25 Nov: windows of apps still running are found in about a millisecond after a restart; after Chrome itself restarts, the first search takes up to 3 s |
| 8 | ✅ | a minimized window and a hidden app's windows are listed as such |
| 9 | ✅ | by the owner, after the fix of 25 Nov |
| 10 | ✅ | 40 icons wrap into two rows. Listing with 30 extra apps running: 75 ms. Once, under that load, the panel's log said "visible, not on screen"; not seen again |
| 11 | — | one display only |
| 12 | ✅ | by the owner: Fun, Personal, markerloop.com |
| 13 | ✅ | by the owner |
| 14 | — | |
| 15 | — | |
| 16 | ✅ | clone from GitHub, `./build.sh` with no certificate: builds, signed ad hoc, icon and version in the bundle |
| 17 | ✅ (build) | the app itself not run from that build: it would have replaced the owner's permission |
| 18 | — | |
