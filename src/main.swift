#!/usr/bin/env swift
import Cocoa
import AppKit
import CoreGraphics

typealias AppPID = Int32 // see kCGWindowOwnerPID
typealias WinNum = Int // see kCGWindowNumber (Int32) and NSWindow.windowNumber (Int)
typealias WinPos = (WinNum, CGRect) // win-num, bounds
typealias WinConf = [AppPID: [WinPos]] // app-pid, window-list
// A monitor configuration signature derived from connected display IDs and frames.
typealias DisplaySig = String

typealias SpaceId = WinNum // see NSWindow.windowNumber (Int)

class AppDelegate: NSObject, NSApplicationDelegate {
	private var statusItem: NSStatusItem!
	private var numScreens: Int = NSScreen.screens.count
	private var currentSig: DisplaySig = ""
	private var state: [DisplaySig: WinConf] = [:] // [display-signature: [pid: [windows]]]
	private var spacesAll: [SpaceId] = [] // keep forever (and keep order)
	private var spacesVisited: Set<WinNum> = [] // fill-up on space-switch
	private var spacesNeedRestore: Set<SpaceId> = [] // dropped after restore

	// Debounced restore
	private var restoreDebounce: DispatchWorkItem?
	private let restoreDelay: TimeInterval = 1.6

	// Last stable snapshot (captured periodically) to prevent overwriting good layouts on unplug.
	private var lastStableSig: DisplaySig = ""
	private var lastStableState: WinConf = [:]
	private var snapshotTimer: Timer?

	// Diagnostics
	private let logDF: DateFormatter = {
		let df = DateFormatter()
		df.locale = Locale(identifier: "en_US_POSIX")
		df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
		return df
	}()
	private func log(_ msg: String) {
		let ts = logDF.string(from: Date())
		print("[Memmon] \(ts) \(msg)")
	}

	private var separateSpaces: Bool { NSScreen.screensHaveSeparateSpaces }

	func applicationDidFinishLaunching(_ aNotification: Notification) {
		self.currentSig = self.displaySignature()
		self.lastStableSig = self.currentSig
		log("Launch. screens=\(NSScreen.screens.count) sig=\(self.currentSig) separateSpaces=\(self.separateSpaces)")

		// show Accessibility Permissions popup
		AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() : true] as CFDictionary)

		// Track space changes
		NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.activeSpaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

		// Track sleep / wake
		let wsnc = NSWorkspace.shared.notificationCenter
		wsnc.addObserver(self, selector: #selector(self.willSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
		wsnc.addObserver(self, selector: #selector(self.didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
		wsnc.addObserver(self, selector: #selector(self.screensDidWake(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)

		_ = self.currentSpace() // create space-id win for current space
		self.spacesVisited = Set(self.getWinIds())

		// Periodically capture a stable snapshot (helps preserve layout when displays are unplugged).
		self.snapshotTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
			guard let self else { return }
			let sig = self.displaySignature()
			let snap = self.getState()
			if !snap.isEmpty {
				self.lastStableSig = sig
				self.lastStableState = snap
			}
		}
		if let t = self.snapshotTimer {
			RunLoop.main.add(t, forMode: .common)
		}

		// create status menu icon
		UserDefaults.standard.register(defaults: ["icon": 2])
		let icon = UserDefaults.standard.integer(forKey: "icon")
		if icon == 0 { return }
		self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		if let button = self.statusItem.button {
			switch icon {
			case 1: button.image = NSImage.statusIconDots
			case 2: button.image = NSImage.statusIconMonitor
			default: button.image = NSImage.statusIconMonitor
			}
		}
		let menu = NSMenu(title: "")
		menu.addItem(withTitle: "Memmon (v1.5)", action: nil, keyEquivalent: "")
		let saveItem = menu.addItem(withTitle: "Save Current Layout", action: #selector(self.menuSaveLayout), keyEquivalent: "s")
		saveItem.target = self
		let restoreItem = menu.addItem(withTitle: "Restore Saved Layout", action: #selector(self.menuRestoreLayout), keyEquivalent: "r")
		restoreItem.target = self
		menu.addItem(NSMenuItem.separator())
		let hideItem = menu.addItem(withTitle: "Hide Status Icon", action: #selector(self.enableInvisbleMode), keyEquivalent: "")
		hideItem.target = self
		menu.addItem(withTitle: "Quit", action: #selector(NSApp.terminate), keyEquivalent: "q")
		self.statusItem.menu = menu
	}

	@objc func enableInvisbleMode() {
		self.statusItem = nil
	}

	// MARK: - Menu Actions
	@objc private func menuSaveLayout() {
		let sig = self.displaySignature()
		let snap = self.getState()
		self.state[sig] = snap
		self.currentSig = sig
		self.numScreens = NSScreen.screens.count
		log("Manual save: screens=\(self.numScreens) sig=\(sig) apps=\(snap.count)")
	}

	@objc private func menuRestoreLayout() {
		let sig = self.displaySignature()
		self.currentSig = sig
		self.numScreens = NSScreen.screens.count
		log("Manual restore requested: screens=\(self.numScreens) sig=\(sig) hasLayout=\(self.state[sig] != nil)")
		self.restoreLayoutNow(reason: "manual")
		// Second pass to beat late WindowServer rearrangements.
		DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
			self?.restoreLayoutNow(reason: "manual-second-pass")
		}
	}

	// MARK: - Screen / Sleep Lifecycle
	func applicationDidChangeScreenParameters(_ notification: Notification) {
		let oldCount = self.numScreens
		let oldSig = self.currentSig
		let newCount = NSScreen.screens.count
		let newSig = self.displaySignature()

		log("Screen parameters changed: oldCount=\(oldCount) newCount=\(newCount) oldSig=\(oldSig) newSig=\(newSig)")

		// If displays were removed, macOS may already have collapsed windows; keep last stable snapshot for oldSig.
		if newCount < oldCount {
			if self.lastStableSig == oldSig && !self.lastStableState.isEmpty {
				self.state[oldSig] = self.lastStableState
				log("Preserved last stable snapshot for removed config sig=\(oldSig) apps=\(self.lastStableState.count)")
			} else {
				log("Warning: no last stable snapshot available for oldSig=\(oldSig); not overwriting saved layout")
			}
		} else {
			// For other changes, update the stored layout for the old config conservatively.
			self.saveState(for: oldSig)
		}

		self.numScreens = newCount
		self.currentSig = newSig
		self.spacesVisited.removeAll(keepingCapacity: true)
		self.scheduleRestoreDebounced(reason: "screen-change")
	}

	@objc private func willSleep(_ note: Notification) {
		log("Will sleep: saving current layout")
		self.saveState(for: self.currentSig)
	}

	@objc private func didWake(_ note: Notification) {
		log("Did wake: scheduling restore")
		self.scheduleRestoreDebounced(reason: "didWake")
	}

	@objc private func screensDidWake(_ note: Notification) {
		log("Screens did wake: scheduling restore")
		self.scheduleRestoreDebounced(reason: "screensDidWake")
	}

	private func scheduleRestoreDebounced(reason: String) {
		self.restoreDebounce?.cancel()
		let work = DispatchWorkItem { [weak self] in
			self?.restoreLayoutNow(reason: reason)
		}
		self.restoreDebounce = work
		DispatchQueue.main.asyncAfter(deadline: .now() + self.restoreDelay, execute: work)
	}

	// MARK: - Helpers
	private func displaySignature() -> DisplaySig {
		// Include display ID and frame to distinguish same monitors in different arrangements.
		let parts: [String] = NSScreen.screens.compactMap { s in
			let idNum = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
			let id = idNum?.uint32Value ?? 0
			let f = s.frame
			return String(format: "%08X:%0.0f,%0.0f-%0.0fx%0.0f", id, f.origin.x, f.origin.y, f.size.width, f.size.height)
		}
		return parts.joined(separator: "|")
	}

	private func getWinIds(allSpaces: Bool = false) -> [WinNum] {
		NSWindow.windowNumbers(options: allSpaces ? [.allApplications, .allSpaces] : .allApplications)?.map { $0.intValue } ?? []
	}

	// MARK: - Save State (CGWindow)
	private func saveState(for sig: DisplaySig) {
		// Only update the layout for the specific signature (do NOT update other configs).
		let newState = self.getState()
		self.mergeState(for: sig, newState: newState)
		log("Auto save: sig=\(sig) apps=\(newState.count)")
	}

	private func mergeState(for sig: DisplaySig, newState: WinConf) {
		self.spacesNeedRestore = Set(self.spacesAll)
		if self.state[sig] == nil { self.state[sig] = [:] }
		var tmp_state: WinConf = self.state[sig] ?? [:]
		let dummy: WinPos = (0, CGRect.zero)

		for (n_app, n_windows) in newState {
			if let old_windows = tmp_state[n_app] {
				var win_arr: [WinPos] = []
				for n_win in n_windows {
					// If a space was visited, use the current position, else keep old position if available.
					if self.spacesVisited.contains(n_win.0) {
						win_arr.append(n_win)
					} else {
						let old_win = old_windows.first { $0.0 == n_win.0 }
						win_arr.append(old_win ?? dummy)
					}
				}
				tmp_state[n_app] = win_arr
			} else {
				tmp_state[n_app] = n_windows
			}
		}
		self.state[sig] = tmp_state
	}

	private func getState() -> WinConf {
		let allWinNums = self.getWinIds(allSpaces: true).filter { !self.spacesAll.contains($0) }
		var state: WinConf = [:]
		let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as NSArray? as? [[String: AnyObject]]
		guard let windowList else { return [:] }

		for entry in windowList {
			if entry[kCGWindowLayer as String] as? CGWindowLevel != kCGNormalWindowLevel {
				continue
			}
			guard let winNum = entry[kCGWindowNumber as String] as? WinNum else { continue }
			guard let insIdx = allWinNums.firstIndex(of: winNum) else {
				continue
			}
			guard let pid = entry[kCGWindowOwnerPID as String] as? AppPID else { continue }
			guard let b = entry[kCGWindowBounds as String] as? [String: Int] else { continue }
			let bounds = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)

			if state[pid] == nil {
				state[pid] = [(winNum, bounds)]
			} else {
				// allWinNums is sorted by recent activity, windowList is not. Keep order while appending.
				if let idx = state[pid]!.firstIndex(where: { insIdx < allWinNums.firstIndex(of: $0.0)! }) {
					state[pid]!.insert((winNum, bounds), at: idx)
				} else {
					state[pid]!.append((winNum, bounds))
				}
			}
		}
		return state
	}

	// MARK: - Restore State (AXUIElement)
	private func restoreLayoutNow(reason: String) {
		let sig = self.displaySignature()
		self.currentSig = sig
		let layout = self.state[sig]
		log("Restore attempt (\(reason)): screens=\(NSScreen.screens.count) sig=\(sig) hasLayout=\(layout != nil) separateSpaces=\(self.separateSpaces)")
		guard let layout else { return }

		if !self.separateSpaces {
			self.restoreLayoutAllAtOnce(layout)
		} else {
			self.restoreState(layout)
		}
	}

	private func restoreLayoutAllAtOnce(_ layout: WinConf) {
		let visibleWinNums = self.getWinIds()
		self.spacesVisited.formUnion(visibleWinNums)
		for (pid, bounds) in layout {
			self.setWindowSizes(pid, bounds.filter { visibleWinNums.contains($0.0) })
		}
	}

	private func restoreState(_ layout: WinConf) {
		// Restore only when entering the space after a display change (original behavior).
		if let space = currentSpace(), self.spacesNeedRestore.contains(space) {
			self.spacesNeedRestore.remove(space)
			let spaceWinNums = self.getWinIds()
			self.spacesVisited.formUnion(spaceWinNums)
			for (pid, bounds) in layout {
				self.setWindowSizes(pid, bounds.filter { spaceWinNums.contains($0.0) })
			}
		} else if currentSpace() == nil {
			// Fallback: if space identification is temporarily unavailable, do a best-effort restore.
			log("Space id unavailable; fallback restoreAllAtOnce")
			self.restoreLayoutAllAtOnce(layout)
		}
	}

	private func setWindowSizes(_ pid: pid_t, _ sizes: [WinPos]) {
		guard sizes.count > 0 else { return }
		let win = self.axWinList(pid)

		if win.count != sizes.count {
			log("AX window count mismatch for pid=\(pid): ax=\(win.count) saved=\(sizes.count) (best-effort apply min)")
		}
		let count = min(win.count, sizes.count)
		for i in 0 ..< count {
			var rect = sizes[i].1
			if rect.isEmpty { continue } // filter dummy elements
			let origin = AXValueCreate(AXValueType(rawValue: kAXValueCGPointType)!, &rect.origin)!
			let size = AXValueCreate(AXValueType(rawValue: kAXValueCGSizeType)!, &rect.size)!
			AXUIElementSetAttributeValue(win[i], kAXPositionAttribute as CFString, origin)
			AXUIElementSetAttributeValue(win[i], kAXSizeAttribute as CFString, size)
		}
	}

	private func axWinList(_ pid: pid_t) -> [AXUIElement] {
		let appRef = AXUIElementCreateApplication(pid)
		var value: CFTypeRef?
		AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &value)
		if let windowList = value as? [AXUIElement] {
			var tmp: [AXUIElement] = []
			for win in windowList {
				var role: CFTypeRef?
				AXUIElementCopyAttributeValue(win, kAXRoleAttribute as CFString, &role)
				if role as? String == kAXWindowRole {
					tmp.append(win) // filter e.g. Finder's AXScrollArea
				}
			}
			return tmp
		}
		return []
	}

	// MARK: - Space Management
	@objc func activeSpaceChanged(_ notification: Notification) {
		// Space changes can occur during wake / replug; debounce restores.
		self.scheduleRestoreDebounced(reason: "space-changed")
	}

	private func currentSpace() -> SpaceId? {
		let thisSpace = self.getWinIds()
		var candidates = self.spacesAll.filter { thisSpace.contains($0) }
		if candidates.count > 0 {
			let best = candidates.removeFirst()
			if candidates.count > 0 {
				// if a full-screen app is closed, win moves to current active space -> remove duplicates
				self.spacesAll.removeAll { candidates.contains($0) }
				for oldNum in candidates {
					NSApp.window(withWindowNumber: oldNum)?.close()
				}
			}
			return best
		}
		// create new space-id window (space was not visited yet)
		let win = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
		win.isReleasedWhenClosed = false // win is released either way. But crashes if true.
		guard win.isOnActiveSpace else {
			// dashboard or other full-screen app that prohibits display
			return nil
		}
		win.collectionBehavior = [.ignoresCycle, .stationary]
		win.setIsVisible(true)
		self.spacesAll.append(win.windowNumber)
		return win.windowNumber
	}
}

// MARK: - Status Bar Icon
extension NSImage {
	static var statusIconDots: NSImage {
		let img = NSImage.init(size: .init(width: 20, height: 20), flipped: true) {
			let ctx = NSGraphicsContext.current!.cgContext
			let w = $0.width
			let h = $0.height
			let sw = 0.025 * w // stroke width
			ctx.stroke(CGRect(x: 0.0 * w, y: 0.15 * h, width: 1.0 * w, height: 0.7 * h).insetBy(dx: sw / 2, dy: sw / 2), width: sw)
			ctx.fill(CGRect(x: 0, y: 0.55 * h, width: w, height: sw))
			let circle = CGRect(x: 0, y: 0.25 * h, width: 0.2 * w, height: 0.2 * w)
			ctx.fillEllipse(in: circle.offsetBy(dx: 0.12 * w, dy: 0))
			ctx.fillEllipse(in: circle.offsetBy(dx: 0.4 * w, dy: 0))
			ctx.fillEllipse(in: circle.offsetBy(dx: 0.68 * w, dy: 0))
			return true
		}
		img.isTemplate = true
		return img
	}
	static var statusIconMonitor: NSImage {
		let img = NSImage.init(size: .init(width: 21, height: 14), flipped: true) {
			let ctx = NSGraphicsContext.current!.cgContext
			let w = $0.width
			let h = $0.height
			let ssw = 0.025 * w // small stroke width
			let lsw = 0.05 * w // large stroke width
			// main screen
			ctx.stroke(CGRect(x: 0.1 * w, y: 0.0 * h, width: 0.8 * w, height: 0.8 * h).insetBy(dx: lsw / 2, dy: lsw / 2), width: lsw)
			ctx.clear(CGRect(x: 0.0 * w, y: 0.2 * h, width: 1.0 * w, height: 0.4 * h))
			ctx.fill(CGRect(x: 0.41 * w, y: 0.8 * h, width: 0.18 * w, height: 0.12 * h))
			ctx.fill(CGRect(x: 0.27 * w, y: 0.92 * h, width: 0.46 * w, height: 0.08 * h))
			// three windows
			ctx.stroke(CGRect(x: 0.0 * w, y: 0.28 * h, width: 0.27 * w, height: 0.24 * h).insetBy(dx: ssw / 2, dy: ssw / 2), width: ssw)
			ctx.stroke(CGRect(x: 0.34 * w, y: 0.2 * h, width: 0.32 * w, height: 0.4 * h).insetBy(dx: ssw / 2, dy: ssw / 2), width: ssw)
			ctx.stroke(CGRect(x: 0.73 * w, y: 0.28 * h, width: 0.27 * w, height: 0.24 * h).insetBy(dx: ssw / 2, dy: ssw / 2), width: ssw)
			return true
		}
		img.isTemplate = true
		return img
	}
}

// MARK: - Main Entry
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
// _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
