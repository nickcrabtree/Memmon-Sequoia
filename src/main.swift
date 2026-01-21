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

@available(macOS 10.12, *)
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
	// Screen-change sequencing and settle handling
	private var screenChangeSeq: Int = 0
	private var lastScreenChangeAt: Date = Date.distantPast
	private let settleRestoreDelays: [TimeInterval] = [1.6, 8.0, 20.0, 40.0, 70.0]
	private let settleDeferredSaveDelay: TimeInterval = 75.0

	// Display settle / wallpaper readiness probing (for diagnosing how long externals take to fully come back)
	private var externalsDetectedAt: Date? = nil
	private var wallpaperProbeSeq: Int = 0
	private var lastWallpaperWindowCount: Int = -1
	private let wallpaperProbeInterval: TimeInterval = 2.0
	private let wallpaperProbeTimeout: TimeInterval = 120.0
	// Last stable snapshot (captured periodically) to prevent overwriting good layouts on unplug.
	private var lastStableSig: DisplaySig = ""
	private var lastStableState: WinConf = [:]
	private var snapshotTimer: Timer?

	// Diagnostics
	// Always-on file logging (so logs exist even when launched as a Login Item / from Finder)
	private var logFileURL: URL?
	private var logFH: FileHandle?
	private let logQueue = DispatchQueue(label: "de.relikd.Memmon.log", qos: .utility)
	private let maxLogBytes: Int64 = 5 * 1024 * 1024 // 5 MiB

	private let logDF: DateFormatter = {
		let df = DateFormatter()
		df.locale = Locale(identifier: "en_US_POSIX")
		df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
		return df
	}()
	private func log(_ msg: String) {
		let ts = logDF.string(from: Date())
		let line = "[Memmon] \(ts) \(msg)"
		// Keep stdout for interactive debugging
		print(line)
		// And always append to our known log file
		appendLogLine(line)
	}

	/// Initialize logging to a stable per-user location.
	/// Location: ~/Library/Logs/Memmon/memmon.log
	private func setupLogging() {
		let fm = FileManager.default
		guard let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else {
			// If we cannot resolve the Library directory, we still have stdout logging.
			return
		}
		let dir = lib.appendingPathComponent("Logs", isDirectory: true)
			.appendingPathComponent("Memmon", isDirectory: true)
		let file = dir.appendingPathComponent("memmon.log", isDirectory: false)
		do {
			try fm.createDirectory(at: dir, withIntermediateDirectories: true)
			if !fm.fileExists(atPath: file.path) {
				fm.createFile(atPath: file.path, contents: nil)
			}
			self.logFileURL = file
			self.logFH = try FileHandle(forWritingTo: file)
			// Use legacy API so we compile with -target macos10.10
			self.logFH?.seekToEndOfFile()
			// Write a startup marker without calling log() (avoid recursion while setting up)
			let ts = logDF.string(from: Date())
			let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
			let b = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
			let pid = getpid()
			let ax = AXIsProcessTrusted()
			let sig = self.displaySignature()
			self.appendLogLine("[Memmon] \(ts) Logging started at \(file.path) v=\(v)\(b.isEmpty ? "" : "(\(b))") pid=\(pid) axTrusted=\(ax) screens=\(NSScreen.screens.count) separateSpaces=\(self.separateSpaces) sig=\(sig)")
		} catch {
			// Fall back silently to stdout.
			self.logFileURL = nil
			self.logFH = nil
		}
	}

	private func rotateIfNeeded() {
		guard let url = self.logFileURL else { return }
		let fm = FileManager.default
		guard let attrs = try? fm.attributesOfItem(atPath: url.path),
			  let size = attrs[.size] as? NSNumber else { return }
		let bytes = size.int64Value
		guard bytes > self.maxLogBytes else { return }
		// Close existing handle before rotating
		if let fh = self.logFH {
			fh.closeFile()
		}
		self.logFH = nil
		let rotated = url.deletingLastPathComponent().appendingPathComponent("memmon.log.1")
		_ = try? fm.removeItem(at: rotated)
		_ = try? fm.moveItem(at: url, to: rotated)
		fm.createFile(atPath: url.path, contents: nil)
		self.logFH = try? FileHandle(forWritingTo: url)
		// Use legacy API so we compile with -target macos10.10
		self.logFH?.seekToEndOfFile()
	}

	private func appendLogLine(_ line: String) {
		guard let data = (line + "\n").data(using: .utf8) else { return }
		logQueue.async { [weak self] in
			guard let self else { return }
			self.rotateIfNeeded()
			guard let fh = self.logFH else { return }
			fh.write(data)
		}
	}

	private var separateSpaces: Bool { NSScreen.screensHaveSeparateSpaces }

	func applicationDidFinishLaunching(_ aNotification: Notification) {
		// Ensure file logging exists even when launched from Finder / at login.
		self.setupLogging()
		self.currentSig = self.displaySignature()
		self.lastStableSig = self.currentSig
		log("Launch. screens=\(NSScreen.screens.count) sig=\(self.currentSig) separateSpaces=\(self.separateSpaces)")

		// show Accessibility Permissions popup
		AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() : true] as CFDictionary)


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
		let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
let b = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
let title = "Memmon v\(v)" + (b == "?" || b.isEmpty ? "" : " (\(b))")
menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
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
		// Diagnostics: if displays were added, record when externals were detected and probe for wallpaper readiness
		if newCount > oldCount {
			self.externalsDetectedAt = Date()
			log("Externals detected: oldCount=\(oldCount) newCount=\(newCount)")
			self.startWallpaperProbe(reason: "screen-added")
		}


		log("Screen parameters changed: oldCount=\(oldCount) newCount=\(newCount) oldSig=\(oldSig) newSig=\(newSig)")

			// If the computed signature does not reflect the observed screen count, emit diagnostic details.
			let sigDisplays = newSig.split(separator: "\n".first!).count
			if sigDisplays != newCount {
				log("Warning: signature display count mismatch: screens=\(newCount) sigDisplays=\(sigDisplays) \(self.displayDebugSummary())")
			}


		// If displays were removed, macOS may already have collapsed windows; keep last stable snapshot for oldSig.
		if newCount < oldCount {
			if self.lastStableSig == oldSig && !self.lastStableState.isEmpty {
				self.state[oldSig] = self.lastStableState
				log("Preserved last stable snapshot for removed config sig=\(oldSig) apps=\(self.lastStableState.count)")
			} else {
				log("Warning: no last stable snapshot available for oldSig=\(oldSig); not overwriting saved layout")
			}
		} else {
			// During attach/rearrange (especially after wake), WindowServer may shuffle windows and screen UUIDs.
			// Avoid overwriting a good multi-monitor layout with a transient 'all windows on laptop' state.
			log("Skipping immediate auto save during display transition (will do deferred save after settle)")
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
		// Diagnostics: wallpaper may take a while to appear after wake; probe readiness.
		if NSScreen.screens.count > 1 {
			self.externalsDetectedAt = Date()
			self.startWallpaperProbe(reason: "screensDidWake")
		}
		self.scheduleRestoreDebounced(reason: "screensDidWake")
	}

	private func scheduleRestoreDebounced(reason: String) {
		// Each screen-change increments a sequence so stale retries do nothing.
		self.restoreDebounce?.cancel()
		self.screenChangeSeq += 1
		let seq = self.screenChangeSeq
		self.lastScreenChangeAt = Date()
		for (idx, delay) in self.settleRestoreDelays.enumerated() {
			DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
				guard let self else { return }
				guard self.screenChangeSeq == seq else { return }
				self.restoreLayoutNow(reason: idx == 0 ? reason : "\(reason)-retry\(idx)")
			}
		}
		// After displays settle, do a deferred save so the new signature gains a layout,
		// but only if no newer screen change occurred.
		DispatchQueue.main.asyncAfter(deadline: .now() + self.settleDeferredSaveDelay) { [weak self] in
			guard let self else { return }
			guard self.screenChangeSeq == seq else { return }
			let sig = self.displaySignature()
			self.saveState(for: sig)
			self.log("Deferred auto save after settle: sig=\(sig)")
		}
	}

	// MARK: - Helpers

	private func cgActiveDisplays() -> [(id: CGDirectDisplayID, uuid: String, bounds: CGRect)] {
		let max: UInt32 = 16
		var ids = [CGDirectDisplayID](repeating: 0, count: Int(max))
		var count: UInt32 = 0
		let err = CGGetActiveDisplayList(max, &ids, &count)
		guard err == .success else { return [] }
		let active = ids.prefix(Int(count))
		var out: [(id: CGDirectDisplayID, uuid: String, bounds: CGRect)] = []
		out.reserveCapacity(active.count)
		for id in active {
			var key = String(format: "%08X", id)
			if let cfUUID = CGDisplayCreateUUIDFromDisplayID(id) {
				key = (CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) as String)
			}
			let b = CGDisplayBounds(id) // global pixel coordinates
			out.append((id: id, uuid: key, bounds: b))
		}
		// Deterministic ordering across re-enumerations.
		out.sort {
			if $0.uuid != $1.uuid { return $0.uuid < $1.uuid }
			if $0.bounds.origin.x != $1.bounds.origin.x { return $0.bounds.origin.x < $1.bounds.origin.x }
			if $0.bounds.origin.y != $1.bounds.origin.y { return $0.bounds.origin.y < $1.bounds.origin.y }
			if $0.bounds.size.width != $1.bounds.size.width { return $0.bounds.size.width < $1.bounds.size.width }
			return $0.bounds.size.height < $1.bounds.size.height
		}
		return out
	}

	private func screenDisplays() -> [(id: CGDirectDisplayID, uuid: String, bounds: CGRect)] {
		var out: [(id: CGDirectDisplayID, uuid: String, bounds: CGRect)] = []
		out.reserveCapacity(NSScreen.screens.count)
		for s in NSScreen.screens {
			guard let idNum = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
			let id = CGDirectDisplayID(idNum.uint32Value)
			var key = String(format: "%08X", id)
			if let cfUUID = CGDisplayCreateUUIDFromDisplayID(id) {
				key = (CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) as String)
			}
			let b = CGDisplayBounds(id) // global pixel coordinates
			out.append((id: id, uuid: key, bounds: b))
		}
		out.sort {
			if $0.uuid != $1.uuid { return $0.uuid < $1.uuid }
			if $0.bounds.origin.x != $1.bounds.origin.x { return $0.bounds.origin.x < $1.bounds.origin.x }
			if $0.bounds.origin.y != $1.bounds.origin.y { return $0.bounds.origin.y < $1.bounds.origin.y }
			if $0.bounds.size.width != $1.bounds.size.width { return $0.bounds.size.width < $1.bounds.size.width }
			return $0.bounds.size.height < $1.bounds.size.height
		}
		return out
	}

	private func displayDebugSummary() -> String {
		let nsParts: [String] = NSScreen.screens.enumerated().map { (idx, s) in
			let idNum = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
			let id = idNum?.uint32Value ?? 0
			let f = s.frame
			let scale = s.backingScaleFactor
			return String(format: "ns[%d] id=%08X frame=%.0f,%.0f-%.0fx%.0f scale=%.2f", idx, id, f.origin.x, f.origin.y, f.size.width, f.size.height, scale)
		}
		let cg = self.cgActiveDisplays()
		let cgParts: [String] = cg.map { d in
			let b = d.bounds
			return String(format: "cg id=%08X uuid=%@ bounds=%.0f,%.0f-%.0fx%.0f", d.id, d.uuid, b.origin.x, b.origin.y, b.size.width, b.size.height)
		}
		return "nsCount=\(NSScreen.screens.count) cgCount=\(cg.count) ns={\(nsParts.joined(separator: " | "))} cg={\(cgParts.joined(separator: " | "))}"
	}

	private func displaySignature() -> DisplaySig {
		// Prefer NSScreen-derived display IDs (usually matches Spaces/display arrangement), using CG bounds.
		let sd = self.screenDisplays()
		if !sd.isEmpty {
			let parts: [String] = sd.map { d in
				let b = d.bounds
				return String(format: "%@:%.0f,%.0f-%.0fx%.0f", d.uuid, b.origin.x, b.origin.y, b.size.width, b.size.height)
			}
			return parts.joined(separator: "\n")
		}
		// If NSScreen-derived IDs are temporarily unavailable, fall back to CoreGraphics active list.
		let cg = self.cgActiveDisplays()
		if !cg.isEmpty {
			let parts: [String] = cg.map { d in
				let b = d.bounds
				return String(format: "%@:%.0f,%.0f-%.0fx%.0f", d.uuid, b.origin.x, b.origin.y, b.size.width, b.size.height)
			}
			return parts.joined(separator: "\n")
		}
	// Fallback (should be rare): derive from NSScreen.
		let parts: [String] = NSScreen.screens.compactMap { s in
			let idNum = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
			let id = idNum?.uint32Value ?? 0
			var key = String(format: "%08X", id)
			if let cfUUID = CGDisplayCreateUUIDFromDisplayID(id) {
				key = (CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) as String)
			}
			let f = s.frame
			return String(format: "%@:%.0f,%.0f-%.0fx%.0f", key, f.origin.x, f.origin.y, f.size.width, f.size.height)
		}
		return parts.joined(separator: "\n")
	}

	private func getWinIds(allSpaces: Bool = false) -> [WinNum] {
		NSWindow.windowNumbers(options: allSpaces ? [.allApplications, .allSpaces] : .allApplications)?.map { $0.intValue } ?? []
	}

	// Try to find a previously saved layout even if the display IDs/signature changed (e.g., unplug/replug).
	// We match by multiset of screen resolutions (WxH) to handle dock/display-ID churn.
	private func sigSizes(_ sig: DisplaySig) -> [String] {
		let lines = sig.split(separator: "\n")
		var out: [String] = []
		out.reserveCapacity(lines.count)
		for l in lines {
			if let dash = l.lastIndex(of: "-") {
				let size = l[l.index(after: dash)...]
				out.append(String(size))
			}
		}
		return out.sorted()
	}

	private func bestMatchingSignature(for sig: DisplaySig) -> DisplaySig? {
		let target = sigSizes(sig)
		guard !target.isEmpty else { return nil }
		for k in self.state.keys {
			if sigSizes(k) == target { return k }
		}
		return nil
	}

	// MARK: - Wallpaper/desktop readiness diagnostics
	// Heuristic: count visible "Desktop Picture" windows owned by Dock (and/or WallpaperAgent).
	// This helps estimate when the desktop background has been restored on external displays.
	private func desktopPictureWindowCount() -> Int {
		let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as NSArray? as? [[String: AnyObject]]
		guard let windowList else { return 0 }
		var count = 0
		for entry in windowList {
			let owner = (entry[kCGWindowOwnerName as String] as? String) ?? ""
			let name = (entry[kCGWindowName as String] as? String) ?? ""
			// On most macOS versions, the desktop wallpaper windows are named "Desktop Picture" and owned by Dock.
			if owner == "Dock" && name == "Desktop Picture" {
				count += 1
				continue
			}
			// Fallback for variants (some systems report WallpaperAgent-owned entries).
			if owner.contains("Wallpaper") && name.contains("Desktop") {
				count += 1
			}
		}
		return count
	}

	private func startWallpaperProbe(reason: String) {
		self.wallpaperProbeSeq += 1
		let seq = self.wallpaperProbeSeq
		let screens = NSScreen.screens.count
		self.lastWallpaperWindowCount = -1
		let start = Date()
		let startMsg = self.externalsDetectedAt != nil ? "externalsDetectedAt=\(self.logDF.string(from: self.externalsDetectedAt!))" : "externalsDetectedAt=nil"
		log("Wallpaper probe started (\(reason)): screens=\(screens) \(startMsg)")
		func tick(_ elapsed: TimeInterval) {
			guard self.wallpaperProbeSeq == seq else { return }
			let c = self.desktopPictureWindowCount()
			if c != self.lastWallpaperWindowCount {
				self.lastWallpaperWindowCount = c
				log("Wallpaper probe: elapsed=\(String(format: "%.1f", elapsed))s desktopPictureWindows=\(c) screens=\(NSScreen.screens.count)")
			}
			if c >= NSScreen.screens.count {
				let doneAt = Date()
				let dt = doneAt.timeIntervalSince(start)
				if let extAt = self.externalsDetectedAt {
					let extDt = doneAt.timeIntervalSince(extAt)
					log("Wallpaper ready: dtSinceProbeStart=\(String(format: "%.1f", dt))s dtSinceExternalsDetected=\(String(format: "%.1f", extDt))s")
				} else {
					log("Wallpaper ready: dtSinceProbeStart=\(String(format: "%.1f", dt))s (externalsDetectedAt unknown)")
				}
				return
			}
			if elapsed >= self.wallpaperProbeTimeout {
				log("Wallpaper probe timeout after \(String(format: "%.1f", elapsed))s; desktopPictureWindows=\(c) screens=\(NSScreen.screens.count)")
				return
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + self.wallpaperProbeInterval) { [weak self] in
				guard self != nil else { return }
				tick(Date().timeIntervalSince(start))
			}
		}
		tick(0)
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

		let sigDisplays = sig.split(separator: "\n".first!).count
		let screenCount = NSScreen.screens.count
		if sigDisplays != screenCount {
			log("Warning: signature display count mismatch at restore: screens=\(screenCount) sigDisplays=\(sigDisplays) \(self.displayDebugSummary())")
			return
		}

		let axTrusted = AXIsProcessTrusted()
		var layout = self.state[sig]
		var usedSig = sig
		if layout == nil, let match = self.bestMatchingSignature(for: sig), let l = self.state[match] {
			layout = l
			usedSig = match
			self.state[sig] = l
			log("No exact layout for sig; using best-match layout from sig=\(match)")
		}
		log("Restore attempt (\(reason)): screens=\(NSScreen.screens.count) sig=\(sig) hasLayout=\(layout != nil) axTrusted=\(axTrusted) separateSpaces=\(self.separateSpaces)" + (usedSig == sig ? "" : " matchSig=\(usedSig)"))
		guard let layout else { return }
		if !axTrusted {
			log("Warning: Accessibility not trusted; window moves will fail. Re-enable Memmon in System Settings > Privacy & Security > Accessibility.")
		}
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
		guard let windowList = value as? [AXUIElement] else { return [] }
		var tmp: [AXUIElement] = []
		// Some apps (notably Finder) can expose non-window elements (e.g., AXScrollArea) in the windows list.
		// If we encounter a scroll area, resolve its containing AXWindow via kAXWindowAttribute.
		func appendUnique(_ el: AXUIElement) {
			if !tmp.contains(where: { $0 as CFTypeRef === el as CFTypeRef }) {
				tmp.append(el)
			}
		}
		for el in windowList {
			var roleRef: CFTypeRef?
			AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
			let role = roleRef as? String
			if role == kAXWindowRole {
				appendUnique(el)
				continue
			}
			if role == kAXScrollAreaRole {
				var winRef: CFTypeRef?
				AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &winRef)
				if let winRef = winRef, CFGetTypeID(winRef) == AXUIElementGetTypeID() {
					let winEl = winRef as! AXUIElement
					appendUnique(winEl)
				}
			}
		}
		return tmp
	}

	// MARK: - Space Management

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
	func applicationWillTerminate(_ notification: Notification) {
		// Close file handle cleanly.
		logQueue.sync {
			if let fh = self.logFH {
			fh.closeFile()
		}
			self.logFH = nil
		}
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
if #available(macOS 10.12, *) {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
} else {
    // Fallback for macOS versions earlier than 10.12
    print("AppDelegate is not available on macOS versions earlier than 10.12")
    // Implement alternative entry point or fatal error
    fatalError("Unsupported macOS version")
}
// _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
