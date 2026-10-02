# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Overview

Memmon is a small macOS background app that tracks window positions across external monitor changes and restores them when displays/spaces change. It is implemented as a single Swift source file compiled into a minimal app bundle with no external dependencies beyond macOS frameworks.

Key files:
- Makefile: builds a universal (x86_64 + arm64) Memmon.app bundle and signs it.
- src/main.swift: main application logic, including lifecycle handling, window/space tracking, and menu bar integration.
- src/Info.plist: app metadata (bundle identifier, version, background-only settings) used both by the system and the release packaging.
- src/AppIcon.icns: app icon referenced from Info.plist.

You will need macOS 10.10+ and Xcode command line tools (for swiftc, xcrun, codesign, spctl).

Accessibility permission is required for Memmon to be able to move windows; without it, the core functionality will be ineffective even if the process runs.

## Common commands

All commands are intended to be run from the repository root unless noted otherwise.

### Build the Memmon.app bundle

- Build (optimized, default):
  - make
- Build explicitly in debug configuration (no optimizations, with debug info):
  - make CONFIG=debug

This produces Memmon.app in the repository root, with the executable at Memmon.app/Contents/MacOS/Memmon.

### Codesigning and verification

The Makefile attempts to sign the app with an "Apple Development" identity if one is available in your keychain, otherwise it uses ad-hoc signing. After building, the Makefile also runs basic codesign validation commands.

You normally do not need to run codesign manually; rerunning make will rebuild and re-sign.

### Run the self-test

- Check the frame-to-window pairing logic (no Accessibility permission needed, moves no windows):
  - make test

The tests live in runSelfTest() in src/main.swift and run when the binary is started with --self-test.

### Clean build artifacts

- Remove the built app and intermediate binaries:
  - make clean

### Create a release archive

- Package the current Memmon.app into a versioned tarball:
  - make release

The release target reads CFBundleShortVersionString from src/Info.plist and creates Memmon_v<version>.tar.gz alongside Memmon.app. Remember to update the version in src/Info.plist before cutting a new release.

### Run without an app bundle

For quick local iteration you can run the program directly without building Memmon.app:

- From the repo root:
  - swift src/main.swift
- Alternatively, from within src/:
  - swift main.swift

You can also mark src/main.swift as executable and run it as a script if desired.

When running this way, you still need to grant Accessibility privileges to the resulting process for window movement to work.

### Xcode-based development

If you prefer Xcode, you can:
- Create a new macOS command-line or app project.
- Replace the template main.swift with the contents of src/main.swift.
- Bring over Info.plist settings and AppIcon.icns as needed.

The Makefile-based build remains the source of truth for how the standalone Memmon.app is produced and signed.

## High-level architecture

All runtime behavior lives in src/main.swift and is organized into three main areas: the NSApplication delegate, status bar icon drawing, and the main entry point.

### Application delegate and window/space state

The AppDelegate class implements NSApplicationDelegate and is responsible for:
- Managing a status item (menu bar icon and menu).
- Tracking the current number of screens (NSScreen.screens.count).
- Capturing and restoring window positions across monitor and space changes.

Key type aliases:
- AppPID: process identifier of an owning app (for window grouping).
- WinNum: window number (kCGWindowNumber / NSWindow.windowNumber).
- WinPos: tuple of (WinNum, CGRect) representing a specific window and its bounds.
- WinConf: mapping from AppPID to ordered lists of WinPos.
- SpaceId: identifier used to distinguish virtual desktops/spaces.

Internal state:
- numScreens: current count of attached screens.
- state: dictionary keyed by display signature (one "UUID:x,y-WxH" line per display), mapping to a WinConf snapshot. This lets Memmon maintain separate window layouts for different monitor setups. Frames are in global coordinates, so a layout fits only the arrangement in its key. macOS keeps a separate arrangement for every set of connected displays, so the same monitor has a different origin depending on what else is plugged in.
- stateSavedAt: when each layout was last saved from real window positions.
- Borrowing a layout: when the current signature has no layout, restoreLayoutNow borrows one from a signature whose displays correspond one-to-one (bestLayoutSource / mapDisplays: same UUID first, then same size taken left to right; most displays in common wins, then most recently saved). translateLayout moves each frame by the offset between its saved display's origin and the corresponding current display's origin, and the result is stored under the current signature.
- spacesAll: ordered list of synthetic window identifiers used to track known spaces.
- spacesVisited: set of window numbers representing spaces that have been visited (activated) since the last configuration change.
- spacesNeedRestore: set of spaces that should have their windows restored the next time they become active.

Lifecycle hooks:
- applicationDidFinishLaunching:
  - Prompts for Accessibility permissions using AXIsProcessTrustedWithOptions.
  - Subscribes to sleep and wake notifications (willSleep, didWake, screensDidWake).
  - Starts the 2 s snapshot timer that keeps lastStableState current.
  - Initializes the current space tracking and marks any existing windows as visited.
  - Configures the status bar item and its menu based on a user default named "icon".
- applicationDidChangeScreenParameters:
  - Triggered when displays are attached/detached or their configuration changes.
  - Does not save at this point, because macOS may already have moved windows. If displays were removed, the last 2 s snapshot becomes the layout of the configuration that went away.
  - Updates the screen count and signature, resets visited spaces, sets layoutDirty and schedules a restore (see "What happens on a display change").

State capture and merging:
- getWinIds(allSpaces:): uses NSWindow.windowNumbers to get window numbers across the current space or all spaces.
- getState():
  - Uses CGWindowListCopyWindowInfo to inspect all normal windows (kCGNormalWindowLevel).
  - Filters to windows corresponding to the tracked window numbers.
  - Builds a WinConf mapping from app PID to ordered lists of WinPos, preserving activity order within each app.
- saveState():
  - Marks all known spaces as needing restore.
  - Ensures there is an entry in state for the given display signature.
  - Merges the latest snapshot from getState() into that signature's layout.
  - For the current screen configuration, updates positions for windows in spaces that have been visited, while preserving older positions for unvisited spaces via a dummy placeholder mechanism.

This design ensures:
- Different monitor setups can retain distinct window layouts.
- Unvisited spaces are not aggressively overwritten, reducing the risk of losing a good layout on a space the user has not yet activated.

### Restoring window positions

Restoration is performed via macOS Accessibility APIs (AXUIElement) and is coordinated per space.

- restoreState():
  - Uses currentSpace() to obtain a logical SpaceId for the active space.
  - If that space is in spacesNeedRestore, it removes it from that set and gathers current window numbers for the active space.
  - Marks those windows as visited and, for each app PID, filters its stored window positions to windows that exist in the current space.
  - Calls setWindowSizes for each app to resize and reposition its windows.

- setWindowSizes(pid, sizes):
  - Builds a list of (window number, AXUIElement) pairs for the given process using axWinList.
  - Pairs each stored frame with the AX window that has the same window number (pairSavedFrames). List position is never used: both lists are in z-order, which changes with every click, so pairing by position would give a window another window's frame.
  - Stored frames whose window no longer exists are logged and skipped; live windows with no stored frame are left alone.
  - For each paired window, constructs AXValue instances for position and size and sets kAXPositionAttribute and kAXSizeAttribute.

- axWinList(pid):
  - Creates an AXUIElement for the app and queries kAXWindowsAttribute.
  - Keeps AXWindow elements, resolves non-window elements (for example Finder scroll areas) to their containing window, and drops duplicates.
  - Resolves each element's window number with _AXUIElementGetWindow (private HIServices API); elements without one are dropped.

These functions rely on the system having granted Accessibility permissions to Memmon; without that, AXUIElement calls will silently fail.

### Space tracking strategy

Spaces (virtual desktops) do not have a stable public identifier, so Memmon tracks them indirectly using hidden NSWindow instances:

- currentSpace():
  - Queries the current visible window numbers and checks if any match an existing entry in spacesAll. If so, it treats the earliest match as the canonical identifier for this space.
  - If multiple candidates match (for example when closing a full-screen app causes its tracking window to move spaces), it cleans up duplicates by closing associated NSWindow instances and removing them from spacesAll.
  - If the active space has not been seen before, it creates a new borderless, stationary NSWindow that is kept invisible and non-cycling, stores its windowNumber in spacesAll, and uses that number as the new SpaceId.

SpacesAll, spacesVisited, and spacesNeedRestore work together so that:
- Each logical space is assigned a stable SpaceId for the lifetime of the process.
- Window positions are restored once when entering a space after a monitor configuration change.
- Duplicate identifiers arising from full-screen transitions are cleaned up.

### Status bar icon and menu

The UI for Memmon is intentionally minimal and consists solely of a menu bar item:

- UserDefaults.standard.register(defaults: ["icon": 2]) sets a default icon preference.
- The integer user default "icon" controls behavior:
  - 0: no status item is created (invisible mode).
  - 1: uses a dot-based icon.
  - 2: uses a monitor-with-windows icon (default).

The AppDelegate constructs an NSStatusItem, sets its image according to the selected style, and attaches an NSMenu with:
- A title item showing the current version string.
- Save Current Layout and Restore Saved Layout, which act on the current display signature; a manual restore runs even when layoutDirty is clear.
- An item to hide the status icon (enableInvisbleMode), which drops the reference to the status item.
- A Quit item wired to NSApp.terminate.

Note that hiding the icon and menu makes Memmon difficult to quit without using Activity Monitor or killall; this matches the behavior described in README.md.

### Icon drawing helpers

An extension on NSImage in src/main.swift provides two computed properties:
- statusIconDots
- statusIconMonitor

Each creates a template NSImage and uses Core Graphics drawing commands inside a flipped drawing context to draw simple monochrome icons suitable for the menu bar. Using code-drawn icons keeps the bundle small and avoids additional asset catalogs.

### Main entry point

At the bottom of src/main.swift, the main entry wires everything together:
- Instantiates AppDelegate.
- Assigns it as NSApplication.shared.delegate.
- Calls NSApplication.shared.run() to start the app event loop.

Info.plist configures the process as a background-only UI element (LSBackgroundOnly and LSUIElement set to true), so the app runs without a Dock icon and is primarily interacted with via the status bar (when not in invisible mode).

## Operations and troubleshooting

Start here when Memmon misbehaves. Everything below was established on 2026-10-02 (macOS 26.6.2).

### Where things are

- Source: ~/code/Memmon-Sequoia, a clone of github.com/nickcrabtree/Memmon-Sequoia (public fork of relikd/Memmon), branch main. The former working copy ~/soft/Memmon no longer exists; shell history that mentions it (~/.directory_history/Users/nickc/soft/Memmon/history) refers to this repository.
- Installed app: /Applications/Memmon.app. The build number (CFBundleVersion) is the git commit count at build time, so `git rev-list --count HEAD` tells you whether the installed build matches HEAD. A build made from uncommitted changes carries the count of the commit below it.
- Log: ~/Library/Logs/Memmon/memmon.log (rotated to memmon.log.1 at 5 MiB). Every launch writes a "Logging started" line with version, build, pid and axTrusted.
- Layouts are held in memory only. Restarting Memmon forgets them all; it relearns each arrangement as it sees it.

### Deploy a new build

Commit first, so the build number is right, then:

1. make clean && make
2. make test
3. pgrep -fl Memmon.app, then kill that exact pid
4. mv /Applications/Memmon.app ~/tmp/Memmon.app.build<N> (keeps the old build, with its signature, for rollback)
5. cp -R Memmon.app /Applications/ && open -a Memmon
6. Re-enable Memmon in System Settings > Privacy & Security > Accessibility. The signature is ad hoc, so every build has a new code hash and macOS forgets the grant. If the toggle does not stick: tccutil reset Accessibility de.relikd.Memmon, then relaunch.
7. Check the "Logging started" line shows the new build and axTrusted=true. With axTrusted=false, restores return early and do nothing.

### What happens on a display change

- Every 2 s a timer snapshots all window frames under the current signature (lastStableState).
- Displays removed: the last snapshot becomes the layout of the configuration that just went away ("Preserved last stable snapshot").
- Any change: one restore runs 1.6 s after the last change in a burst. The later retries (8, 20, 40, 70 s) log "Restore skipped ... layout not dirty" because the first attempt clears the layoutDirty flag.
- 75 s after the last change, the current positions are saved as the layout of the current signature ("Deferred auto save after settle").
- Wake from sleep schedules a restore only if the signature differs from the one before sleep.

### Reading the log

- Signatures span several lines, one display per line; continuation lines start with a display UUID. Filter them out with rg -v '^[0-9A-F]{8}-' to get one line per event.
- "Restore attempt (...) hasLayout=true": frames were applied. With "matchSig=", the layout was borrowed and translated.
- "AX window mismatch for pid=N: ax=0 ...": the app exposed no windows to the Accessibility API, so none of its windows were restored. Aquamacs does this consistently.
- "AX window mismatch ... (no AX window for saved winNums=[...])": those saved windows have gone (closed, or not exposed); the rest were restored.
- ps -p <pid> -o comm= names the app behind a pid.

### Display arrangements on Nick's desk

macOS stores one arrangement per set of connected displays, so a monitor's origin depends on what else is connected; it does not drift. As of 2026-10-02 (laptop 37D8832A at 0,0-1920x1243; two 3840x2160 monitors):

| Connected | 4989187D (left) | 94593581 (right) |
|---|---|---|
| laptop + both | -975,-2160 | 2865,-2160 |
| laptop + left | -887,-2160 | |
| laptop + right | | 1920,-2160 |

Plugging and unplugging pass through the two-display sets for a few seconds, because the monitors appear and disappear one at a time. Changing dock or cable can make macOS create new arrangements (2026-09-18: a dozen within an hour while trying docks and cables).

### Known limitations

- A snapshot taken while the Mac is passing through an intermediate display set becomes that set's layout when the next display is removed. A later real session on that set starts from those transit positions.
- Only the first restore after a change does anything, so an app whose windows are not accessible at that moment is not retried.
- Apps that expose no AX windows (Aquamacs) are never restored.
- _AXUIElementGetWindow is private API. If it ever stops resolving window numbers, axWinList returns nothing and every app logs "ax=0".
- "Displays have separate Spaces" is off on this Mac (separateSpaces=false), so restoreLayoutAllAtOnce is the path in use; the per-space path (restoreState) is not exercised here.

### Change history

- Build 17 (2026-01-26, committed 2026-10-02 as cd48917): restore only when the display configuration really changed (layoutDirty); skip apps with no AX windows.
- Build 20 (2026-10-02, 36926dd and 029550b): saved frames are paired with windows by window number, where they were previously paired by list position, which gave windows each other's frames (Terminal windows shrunk to the size of a small one). Borrowed layouts are translated per display, where they were previously applied with another arrangement's coordinates.
- How to investigate a new complaint: get the time of the event, read the log around it, and compare what was restored with what the user saw. A small Swift probe that prints each app's AX windows with their window numbers and frames (AXIsProcessTrusted is inherited from the terminal) settles most questions about what Memmon can see.

## Notes for future changes

- When adding new features or refactoring, keep in mind that all user-visible behavior is currently driven through NSApplicationDelegate and background event handling; there is no separate model or controller layer.
- If you introduce additional source files, update the Makefile target dependencies and swiftc invocation accordingly, since they currently only compile src/main.swift.
- Logic that can be tested without moving windows (pairing, signature parsing, layout translation) lives in free functions at the top of src/main.swift, with its tests in runSelfTest(). Add the failing test there first.
- Before publishing a new release tarball, update CFBundleShortVersionString and CFBundleVersion in src/Info.plist so that the release target names the archive correctly and the menu title version string remains accurate.

## Host environment

- As of 2026-10-02, this repository is being developed on macOS 26.6.2, as reported by sw_vers -productVersion on the current machine (macOS 15.7.2 on 2025-12-28).
- The app’s minimum deployment target remains macOS 10.10, per LSMinimumSystemVersion in src/Info.plist.
