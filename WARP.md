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
- state: dictionary keyed by numScreens, mapping to a WinConf snapshot. This lets Memmon maintain separate window layouts for different monitor setups.
- spacesAll: ordered list of synthetic window identifiers used to track known spaces.
- spacesVisited: set of window numbers representing spaces that have been visited (activated) since the last configuration change.
- spacesNeedRestore: set of spaces that should have their windows restored the next time they become active.

Lifecycle hooks:
- applicationDidFinishLaunching:
  - Prompts for Accessibility permissions using AXIsProcessTrustedWithOptions.
  - Subscribes to NSWorkspace.activeSpaceDidChangeNotification to react to space switches.
  - Initializes the current space tracking and marks any existing windows as visited.
  - Configures the status bar item and its menu based on a user default named "icon".
- applicationDidChangeScreenParameters:
  - Triggered when displays are attached/detached or their configuration changes.
  - Saves the current window state, updates the screen count, resets visited spaces, and then attempts a restore.

State capture and merging:
- getWinIds(allSpaces:): uses NSWindow.windowNumbers to get window numbers across the current space or all spaces.
- getState():
  - Uses CGWindowListCopyWindowInfo to inspect all normal windows (kCGNormalWindowLevel).
  - Filters to windows corresponding to the tracked window numbers.
  - Builds a WinConf mapping from app PID to ordered lists of WinPos, preserving activity order within each app.
- saveState():
  - Marks all known spaces as needing restore.
  - Ensures there is an entry in state for the current screen count.
  - Merges the latest snapshot from getState() into the per-screen-count dictionary.
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

## Notes for future changes

- When adding new features or refactoring, keep in mind that all user-visible behavior is currently driven through NSApplicationDelegate and background event handling; there is no separate model or controller layer.
- If you introduce additional source files, update the Makefile target dependencies and swiftc invocation accordingly, since they currently only compile src/main.swift.
- Before publishing a new release tarball, update CFBundleShortVersionString and CFBundleVersion in src/Info.plist so that the release target names the archive correctly and the menu title version string remains accurate.

## Host environment

- As of 2025-12-28, this repository is being developed on macOS 15.7.2, as reported by sw_vers -productVersion on the current machine.
- The app’s minimum deployment target remains macOS 10.10, per LSMinimumSystemVersion in src/Info.plist.
