// MousePilot: scrolling the mouse wheel over a browser's tab strip switches tabs
// (wheel up = previous tab, wheel down = next tab), like Chrome on Linux — also in
// browser windows that are not focused or not in front. Other scrolls pass through.
//
// Browsers come from ~/.config/mousepilot/browsers (created on first launch with every
// installed known browser), one per line:  <bundle-id> [height-pt | top-pt bottom-pt]
// The tab strip is the band from top to bottom (default 0..40) below the window's top
// edge; a single number is its height. Edits apply immediately.
//
// How a tab switch is delivered:
//  - the focused window of the frontmost browser gets Ctrl+Tab / Ctrl+Shift+Tab;
//  - any other window (a background browser, or another window of the frontmost one)
//    is switched with Apple Events — "active tab index" (Chromium browsers) or
//    "current tab" (Safari) of the scripting window whose bounds match — which never
//    brings the window forward. That needs the Automation permission for each
//    browser, asked on first use; without it such scrolls pass through untouched.
//
// Performance: the event taps run on their own thread and are enabled only while they can
// matter (see updateTapState). The scroll callback hit-tests against a cached window list,
// refreshed by Accessibility notifications from the browsers' windows, by app / Space
// / display changes, synchronously before acting on a stale hit, and in the
// background after a stale miss over a browser window.
//
// Mouse gestures in the style of Whale (right-button strokes over a browser window) are in
// Gestures.swift.
//
// Settings (defaults domain com.pms.mousepilot): "paused", "wrapAround" (default on: past the
// last tab comes the first; off: stop at either end), "reverseDirection" (wheel up = next
// tab), "mouseGestures", "gestureStroke", "gestureTitle" (default on), "debug" (logs every
// scroll and gesture to ~/Library/Logs/mousepilot.log), "stripHeight" (default 40), "launchAtLogin",
// "appPath" (where it last ran).
// Command line: --version, --login-item-status, --unregister-login-item, --write-default-config.
//
// Built as MousePilot.app by scripts/build.sh. Needs Accessibility permission.

import AppKit
import ApplicationServices
import CoreGraphics
import CoreServices
import ServiceManagement

let appVersion = "1.0.0"   // also the DMG / release version (scripts/build.sh reads this line)
let defaults = UserDefaults.standard
let defaultHeight = CGFloat(defaults.object(forKey: "stripHeight") as? Double ?? 40)
let debug = defaults.bool(forKey: "debug")
let logPath = NSString(string: "~/Library/Logs/mousepilot.log").expandingTildeInPath
#if SELFTEST
let configDir = NSTemporaryDirectory() + "mousepilot-selftest-config-\(getpid())"   // never the user's files
#else
let configDir = NSString(string: "~/.config/mousepilot").expandingTildeInPath
#endif
let configPath = configDir + "/browsers"

// MARK: - Logging

let logQueue = DispatchQueue(label: "MousePilot.log")

func log(_ message: String) {
    #if !SELFTEST   // self-tests exercise failure paths; the user's log stays out of it
    let line = "[\(Date())] \(message)\n"
    logQueue.async {
        if let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(toFile: logPath, atomically: false, encoding: .utf8)
        }
    }
    #endif
}

// MARK: - Shared state
//
// The event tap thread reads the state; the main thread and the Apple Event queue
// write it. Every access goes through the lock and copies what it needs.

final class Locked<Value> {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    @discardableResult
    func update<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

enum ScriptKind { case chromium, safari, none }
enum Permission { case unknown, granted, denied }
struct Band: Equatable { var top: CGFloat; var bottom: CGFloat }
struct Browser { let bundleID: String; let band: Band; let kind: ScriptKind }
struct WindowInfo { let id: CGWindowID; let pid: pid_t; let layer: Int; let bounds: CGRect }
struct FocusedWindow { let frame: CGRect?; let id: CGWindowID? }
/// A browser's ordinary windows according to Accessibility (subrole AXStandardWindow):
/// their CGWindowIDs, or frames when IDs are unavailable. Popups, bubbles, the omnibox
/// dropdown and full-screen helper windows are not standard windows.
struct StandardWindows { let ids: Set<CGWindowID>; let frames: [CGRect] }

struct State {
    var paused = defaults.bool(forKey: "paused")
    var tapOn = false                             // the scroll tap's current enabled state
    var buttonTapOn = false                       // the right-button tap's
    var wrap = defaults.object(forKey: "wrapAround") as? Bool ?? true   // past the last tab → first
    var reverse = defaults.bool(forKey: "reverseDirection")             // wheel up = next tab
    var gestures = defaults.object(forKey: "mouseGestures") as? Bool ?? true
    var gestureStroke = defaults.object(forKey: "gestureStroke") as? Bool ?? true   // draw the trail
    var gestureTitle = defaults.object(forKey: "gestureTitle") as? Bool ?? true     // show the action's name
    var browsers: [pid_t: Browser] = [:]          // running, enabled browsers
    var frontPID: pid_t = 0
    var focused: [pid_t: FocusedWindow] = [:]     // each browser's focused window
    var standard: [pid_t: StandardWindows] = [:]  // each browser's ordinary windows
    var visible: [pid_t: Set<CGWindowID>] = [:]   // each browser's on-screen window-sized windows
    var permission: [String: Permission] = [:]    // Automation permission by bundle ID
    var windows: [WindowInfo] = []                // on-screen windows, front to back
    var covers: [WindowInfo] = []                 // screen-sized windows above the normal level (see coveredInFront)
    var windowsTime: TimeInterval = -1
    var displays: [CGRect] = []
}

let state = Locked(State())
var tap: CFMachPort?         // scrolls
var buttonTap: CFMachPort?   // right-button presses and releases (gestures)
var dragTap: CFMachPort?     // right-button drags: on only while a gesture is under way
var dragTapOn = false        // event tap thread only
var tapRunLoop: CFRunLoop?   // the event tap thread's (scripts/check.sh's gesture demo runs events there)

func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

// MARK: - Config

struct KnownBrowser { let name: String; let id: String; let band: String }
let knownBrowsers = [
    KnownBrowser(name: "Brave", id: "com.brave.Browser", band: ""),
    KnownBrowser(name: "웨일", id: "com.naver.Whale", band: ""),
    KnownBrowser(name: "Chrome", id: "com.google.Chrome", band: ""),
    KnownBrowser(name: "Safari", id: "com.apple.Safari", band: " 50 88"),
    KnownBrowser(name: "Edge", id: "com.microsoft.edgemac", band: ""),
    KnownBrowser(name: "Firefox", id: "org.mozilla.firefox", band: ""),
    KnownBrowser(name: "Arc", id: "company.thebrowser.Browser", band: ""),
    KnownBrowser(name: "Vivaldi", id: "com.vivaldi.Vivaldi", band: ""),
    KnownBrowser(name: "Opera", id: "com.operasoftware.Opera", band: ""),
]

let defaultConfigLines: [String] =
    ["# MousePilot: 적용할 브라우저 (한 줄에 하나)",
     "# <번들 ID> [탭바 높이 pt | 탭바 시작 pt 탭바 끝 pt]  — 창 맨 위에서 잰 탭바 영역, 기본 0 40"]
    + knownBrowsers
        .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
        .map { $0.id + $0.band }

// MARK: - Command line
//
// After the declarations the options use: top-level globals here are set in order, so an
// option run earlier would read them uninitialised (--write-default-config crashed so).

let arguments = Set(CommandLine.arguments.dropFirst())
let options = ["--version", "--login-item-status", "--unregister-login-item", "--write-default-config"]
if let unknown = arguments.first(where: { $0.hasPrefix("--") && !options.contains($0) }) {
    // Never fall through to starting the app on an option it does not know.
    FileHandle.standardError.write(Data("mousepilot: unknown option \(unknown); options: \(options.joined(separator: " "))\n".utf8))
    exit(2)
}
if arguments.contains("--version") {
    print(appVersion)
    exit(0)
}
if arguments.contains("--login-item-status") {
    switch SMAppService.mainApp.status {
    case .enabled: print("enabled")
    case .requiresApproval: print("requires approval")
    case .notRegistered: print("not registered")
    case .notFound: print("not found")
    @unknown default: print("unknown")
    }
    exit(0)
}
if arguments.contains("--write-default-config") {
    ensureConfigFile()
    exit(0)
}
if arguments.contains("--unregister-login-item") {
    do {
        try SMAppService.mainApp.unregister()
        print("login item unregistered")
    } catch {
        print("login item: \(error.localizedDescription)")
    }
    exit(0)
}

/// The lines of a config text; CRLF, LF and a byte-order mark are all accepted.
func configLines(_ text: String) -> [String] {
    text.replacingOccurrences(of: "\u{FEFF}", with: "")
        .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        .map(String.init)
}

/// The fields of one config line: the comment is dropped, any whitespace separates.
func configFields(_ line: String) -> [String] {
    let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    return content.split(whereSeparator: { $0.isWhitespace }).map(String.init)
}

/// The file a config path stands for. Dotfiles managers keep config files as symlinks: those
/// are followed (through a chain, relative ones too) to their target, which need not exist
/// yet, so that writes go there and the link stays.
func configTarget(_ path: String) -> String {
    var p = path
    for _ in 0..<16 {   // a loop of links ends here
        guard let next = try? FileManager.default.destinationOfSymbolicLink(atPath: p) else { break }
        p = next.hasPrefix("/") ? next : ((p as NSString).deletingLastPathComponent as NSString).appendingPathComponent(next)
    }
    // Not standardized: for a target not there yet that would drop "..", taken textually,
    // against folders that are themselves links. The kernel resolves it right when writing.
    return p
}

/// Writes a config file (to its target, atomically); logs and returns false when it
/// cannot (a read-only target, a missing folder).
@discardableResult
func writeConfig(_ text: String, to path: String) -> Bool {
    let target = configTarget(path)
    do {
        try text.write(toFile: target, atomically: true, encoding: .utf8)
        return true
    } catch {
        log("cannot write \(target): \(error.localizedDescription)")
        return false
    }
}

/// What a config file is now, from one stat that follows a symlink (its target's edits
/// count, and a link pointed elsewhere too); nil when there is no file.
struct FileStamp: Equatable { let device: Int32, inode: UInt64, seconds: Int, nanoseconds: Int, size: Int64 }

func fileStamp(_ path: String) -> FileStamp? {
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    return FileStamp(device: st.st_dev, inode: st.st_ino, seconds: st.st_mtimespec.tv_sec,
                     nanoseconds: st.st_mtimespec.tv_nsec, size: st.st_size)
}

/// Opens a config file in the default text editor — not by the type its permissions
/// suggest, which for an executable file is Terminal, running it.
func openInTextEditor(_ path: String) {
    let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText)
        ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: editor,
                            configuration: NSWorkspace.OpenConfiguration())
}

/// Enabled browsers by lowercased bundle ID.
/// The config text in whatever encoding it was saved in; nil if missing or unreadable.
func configText() -> String? {
    var encoding = String.Encoding.utf8
    return try? String(contentsOfFile: configPath, usedEncoding: &encoding)
}

func readConfig() -> [String: Band] {
    parseConfig(configText() ?? defaultConfigLines.joined(separator: "\n"))
}

func parseConfig(_ text: String) -> [String: Band] {
    var browsers: [String: Band] = [:]
    for line in configLines(text) {
        let fields = configFields(line)
        guard let id = fields.first else { continue }
        let numbers = fields.dropFirst().compactMap { Double($0) }.map { CGFloat($0) }
        var band = Band(top: 0, bottom: defaultHeight)
        if numbers.count >= 2, numbers[0] >= 0, numbers[1] > numbers[0] {
            band = Band(top: numbers[0], bottom: numbers[1])
        } else if numbers.count == 1, numbers[0] > 0 {
            band = Band(top: 0, bottom: numbers[0])
        }
        browsers[id.lowercased()] = band
    }
    return browsers
}

func ensureConfigFile() {
    guard !FileManager.default.fileExists(atPath: configPath) else { return }   // follows a link
    try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
    writeConfig(defaultConfigLines.joined(separator: "\n") + "\n", to: configPath)
}

/// Adds or removes one browser line in the config file, keeping all other lines.
func setBrowser(_ b: KnownBrowser, enabled: Bool) {
    ensureConfigFile()
    guard let text = configText() else {
        log("cannot read \(configPath); not changing it")
        NSSound.beep()
        return
    }
    var lines = linesRemoving(b.id, from: configLines(text))
    if enabled { lines.append(b.id + b.band) }
    if !writeConfig(lines.joined(separator: "\n") + "\n", to: configPath) { NSSound.beep() }
    reloadBrowsers()
}

/// The config lines without `id`'s line (any case), trailing blank lines dropped.
func linesRemoving(_ id: String, from lines: [String]) -> [String] {
    var lines = lines.filter { configFields($0).first?.lowercased() != id.lowercased() }
    while lines.last?.isEmpty == true { lines.removeLast() }
    return lines
}

var configWatcher: DispatchSourceFileSystemObject?

/// Editors and mousepilotctl replace the file, which changes the directory. If the
/// directory itself is renamed or deleted the watch follows the new one when it appears
/// (app activations re-read the config meanwhile).
func watchConfig(attempt: Int = 0) {
    configWatcher?.cancel()
    configWatcher = nil
    let fd = open(configDir, O_EVTONLY)
    guard fd >= 0 else {
        if attempt < 12 { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { watchConfig(attempt: attempt + 1) } }
        return
    }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                           queue: .main)
    source.setEventHandler {
        let gone = !source.data.isDisjoint(with: [.rename, .delete])
        reloadBrowsers()
        refreshGestureMap()
        GestureSettings.refresh()   // the gestures file saved while the window is open
        if gone { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { watchConfig() } }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    configWatcher = source
}

// MARK: - Browsers

var scriptKinds: [String: ScriptKind] = [:]

/// Chromium browsers share one scripting dictionary with a writable "active tab index";
/// Safari has "current tab". Other browsers cannot switch tabs of a background window.
func scriptKind(of app: NSRunningApplication) -> ScriptKind {
    let id = app.bundleIdentifier ?? ""
    if let kind = scriptKinds[id] { return kind }
    var kind = ScriptKind.none
    if id == "com.apple.Safari" {
        kind = .safari
    } else if let url = app.bundleURL,
              let name = Bundle(url: url)?.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String,
              let sdef = try? String(contentsOf: url.appendingPathComponent("Contents/Resources/\(name)"),
                                     encoding: .utf8),
              sdef.contains("code=\"acTI\"") {
        kind = .chromium
    }
    scriptKinds[id] = kind
    return kind
}

/// Re-reads the config and the running apps; observes newly found browsers.
func reloadBrowsers() {
    configStamp = configModified()
    let config = readConfig()
    var running: [pid_t: Browser] = [:]
    for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
        guard let id = app.bundleIdentifier, let band = config[id.lowercased()] else { continue }
        running[app.processIdentifier] = Browser(bundleID: id, band: band, kind: scriptKind(of: app))
    }
    let old = state.update { s -> [pid_t: Browser] in
        let old = s.browsers
        s.browsers = running
        s.focused = s.focused.filter { running[$0.key] != nil }
        s.standard = s.standard.filter { running[$0.key] != nil }
        s.visible = s.visible.filter { running[$0.key] != nil }
        return old
    }
    for pid in old.keys where running[pid] == nil { stopObserving(pid) }
    if tap != nil {
        for (pid, browser) in running where axObservers[pid] == nil {
            observeWindows(of: pid)
            refreshAX(pid)
            if old[pid] == nil, browser.kind != .none { switcher.checkPermission(pid: pid, bundleID: browser.bundleID) }
        }
        refreshWindows()
    }
    updateTapState()
}

// MARK: - Window cache

let verifyHitAfter: TimeInterval = 0.15   // a hit on an older cache is re-checked first
let refreshMissAfter: TimeInterval = 0.5  // a miss over a browser window on an older cache refreshes it

func refreshDisplays() {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    let displays = ids.prefix(Int(n)).map { CGDisplayBounds($0) }
    state.update { $0.displays = displays }
}

/// One WindowServer round trip (~2 ms on a 5K display). Safe on any thread.
func refreshWindows() {
    let displays = state.get().displays
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    let overlay = overlayWindowIDs.get()   // the gesture trail and title: click-through
    var covers: [WindowInfo] = []
    let windows: [WindowInfo] = list.compactMap { w in
        guard let id = w[kCGWindowNumber as String] as? CGWindowID, !overlay.contains(id),
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: b) else { return nil }
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let alpha = w[kCGWindowAlpha as String] as? Double
        guard keepWindow(layer: layer, alpha: alpha, bounds: rect, displays: displays) else {
            if alpha != 0 && layer > 0 { covers.append(WindowInfo(id: id, pid: pid, layer: layer, bounds: rect)) }
            return nil
        }
        return WindowInfo(id: id, pid: pid, layer: layer, bounds: rect)
    }
    // Accessibility reports only the windows on the current Spaces, so a browser's list of
    // ordinary windows must be re-read whenever the set of its windows on screen changes
    // (a window opened, closed, came from another Space, Stage Manager, …). Popups and
    // tooltips are too small to count.
    let changed = state.update { s -> [pid_t] in
        var visible: [pid_t: Set<CGWindowID>] = [:]
        for w in windows where w.layer == 0 && w.bounds.height > 120 && w.bounds.width >= 200 && s.browsers[w.pid] != nil {
            visible[w.pid, default: []].insert(w.id)
        }
        let changed = Set(visible.keys).union(s.visible.keys).filter { visible[$0] != s.visible[$0] }
        s.windows = windows
        s.covers = covers
        s.windowsTime = uptime()
        s.visible = visible
        return Array(changed)
    }
    if !changed.isEmpty {
        DispatchQueue.main.async {
            for pid in changed { scheduleAXRefresh(pid) }
        }
        // A window just created may reach the Accessibility list a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            for pid in changed { scheduleAXRefresh(pid) }
        }
    }
    updateTapState()
}

/// Transparent windows, and screen-sized windows above the normal level (Notification
/// Center's invisible click-through layer, display dimmers), never block the cursor —
/// except the frontmost app's (see coveredInFront).
func keepWindow(layer: Int, alpha: Double?, bounds: CGRect, displays: [CGRect]) -> Bool {
    if alpha == 0 { return false }
    return layer == 0 || !displays.contains(where: { bounds.contains($0) })
}

/// A screen-sized window above the normal level of the app in front — a game or a drawing
/// overlay in a full screen of its own, on the current Space — takes the clicks and
/// scrolls over it, though the browser windows behind it still count as on screen.
/// Other processes' screen-sized layers (Notification Center's, dimmers) let them through.
func coveredInFront(_ p: CGPoint, _ s: State, except pid: pid_t) -> Bool {
    s.covers.contains { $0.layer > 0 && $0.pid == s.frontPID && $0.pid != pid && $0.bounds.contains(p) }   // never one below
}

/// With "Displays have separate Spaces" a window shows only on the display holding its
/// centre; the part reaching onto another display is not there.
func shownOnDisplay(_ w: WindowInfo, at p: CGPoint, _ s: State) -> Bool {
    guard let display = s.displays.first(where: { $0.contains(p) }) else { return false }
    let centre = CGPoint(x: w.bounds.midX, y: w.bounds.midY)
    return display.contains(centre) || !s.displays.contains { $0 != display && $0.contains(centre) }
}

var refreshScheduled = false
/// Refreshes shortly, once, however many notifications arrive meanwhile (a window drag
/// fires dozens per second). Main thread only.
func scheduleRefresh() {
    guard !refreshScheduled else { return }
    refreshScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        refreshScheduled = false
        if !state.get().browsers.isEmpty { refreshWindows() }
    }
}

// MARK: - Accessibility: window changes and focused windows

var axObservers: [pid_t: AXObserver] = [:]
let windowNotifications = [
    kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
    kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
    kAXUIElementDestroyedNotification, kAXApplicationHiddenNotification, kAXApplicationShownNotification,
]

let axCallback: AXObserverCallback = { _, element, notification, _ in
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let name = notification as String
    if debug { log("ax \(name) pid \(pid)") }
    scheduleRefresh()
    // Moving or resizing (dozens of notifications a second while dragging) changes only
    // geometry, which the window cache covers; window IDs stay the same.
    guard pid != 0, name != kAXWindowMovedNotification, name != kAXWindowResizedNotification else { return }
    let focusOnly = name == kAXFocusedWindowChangedNotification || name == kAXMainWindowChangedNotification
    scheduleAXRefresh(pid, windowList: !focusOnly)
}

func observeWindows(of pid: pid_t, attempt: Int = 0) {
    guard axObservers[pid] == nil else { return }
    var created: AXObserver?
    guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created else { return }
    let app = AXUIElementCreateApplication(pid)
    let added = windowNotifications.filter {
        AXObserverAddNotification(observer, app, $0 as CFString, nil) == .success
    }.count
    guard added > 0 else {
        // A browser that is still launching answers nothing yet; try again shortly.
        if attempt < 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if state.get().browsers[pid] != nil { observeWindows(of: pid, attempt: attempt + 1) }
            }
        } else {
            log("could not observe windows of pid \(pid)")
        }
        return
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    axObservers[pid] = observer
}

func stopObserving(_ pid: pid_t) {
    guard let observer = axObservers.removeValue(forKey: pid) else { return }
    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    var position: CFTypeRef?, size: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
          let position, let size else { return nil }
    var origin = CGPoint.zero, extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
          AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
    return CGRect(origin: origin, size: extent)
}

/// The CGWindowID behind an AX window. _AXUIElementGetWindow is private but has been
/// in HIServices for many releases (window managers rely on it); it is looked up at run
/// time so its absence only disables this refinement.
typealias AXGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
let axGetWindow: AXGetWindow? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(symbol, to: AXGetWindow.self)
}()

func axWindowID(_ element: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    guard let axGetWindow, axGetWindow(element, &id) == .success, id != 0 else { return nil }
    return id
}

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
}

/// Re-reads a browser's focused window and (unless `windowList` is false) its list of
/// ordinary windows. Main thread.
func refreshAX(_ pid: pid_t, windowList: Bool = true) {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    var focused = FocusedWindow(frame: nil, id: nil)
    if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success, let value {
        let element = value as! AXUIElement
        focused = FocusedWindow(frame: axFrame(element), id: axWindowID(element))
    }
    var standard: StandardWindows?
    value = nil
    if !windowList {
        standard = state.get().standard[pid]
    } else if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
       let windows = value as? [AXUIElement] {
        let ordinary = windows.filter { axString($0, kAXSubroleAttribute) == kAXStandardWindowSubrole }
        standard = StandardWindows(ids: Set(ordinary.compactMap(axWindowID)), frames: ordinary.compactMap(axFrame))
    }
    if debug {
        log("pid \(pid): focused \(focused.frame.map { "\($0)" } ?? "none") id \(focused.id.map(String.init) ?? "none"); "
            + "standard windows \(standard.map { "\($0.ids.sorted())" } ?? "unknown")")
    }
    state.update {
        $0.focused[pid] = focused
        $0.standard[pid] = standard
    }
}

/// Title of the browser's on-screen window `id` (or, failing that, of its only window
/// with this frame), used to tell apart scripting windows with identical bounds — e.g.
/// two full-screen windows of one browser on different Spaces of the same display.
func axTitle(pid: pid_t, windowID: CGWindowID, frame: CGRect) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString,
                                        &value) == .success, let windows = value as? [AXUIElement] else { return nil }
    if let window = windows.first(where: { axWindowID($0) == windowID }) {
        return axString(window, kAXTitleAttribute)
    }
    let sameFrame = windows.filter { axFrame($0).map { sameFrame($0, frame) } ?? false }
    return sameFrame.count == 1 ? axString(sameFrame[0], kAXTitleAttribute) : nil
}

var axRefreshScheduled: [pid_t: Bool] = [:]   // pid → also re-read the window list
func scheduleAXRefresh(_ pid: pid_t, windowList: Bool = true) {
    if let pending = axRefreshScheduled[pid] {
        if windowList && !pending { axRefreshScheduled[pid] = true }
        return
    }
    axRefreshScheduled[pid] = windowList
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        let windowList = axRefreshScheduled.removeValue(forKey: pid) ?? true
        if state.get().browsers[pid] != nil { refreshAX(pid, windowList: windowList) }
    }
}

// MARK: - Hit test

struct Hit {
    let pid: pid_t
    let window: CGRect        // the browser window's frame, as scripting and AX report it
    let windowID: CGWindowID  // its CGWindowID
    let frontmostOwn: Bool    // the browser's frontmost main window (fallback for "focused")
}

/// A browser window proper. Accessibility says which windows are ordinary ones; until
/// it has answered, a tall window not lying inside another of the browser's windows
/// counts (popups, bubbles and the omnibox dropdown lie inside their window).
func isMainWindow(_ w: WindowInfo, among own: [WindowInfo], standard: StandardWindows?) -> Bool {
    if let standard, !standard.ids.isEmpty { return standard.ids.contains(w.id) }
    if let standard, !standard.frames.isEmpty { return standard.frames.contains { sameFrame($0, w.bounds) } }
    return w.bounds.height > 120 && w.bounds.width >= 200
        && !own.contains { o in o.bounds != w.bounds && o.bounds.contains(w.bounds) && o.bounds.height > 120 }
}

/// A browser's level-0 windows, and those of them that are browser windows proper.
func browserWindows(_ pid: pid_t, _ s: State) -> (own: [WindowInfo], mains: [WindowInfo]) {
    let own = s.windows.filter { $0.pid == pid && $0.layer == 0 }
    // The list of ordinary windows is re-read whenever the browser's on-screen windows
    // change (see refreshWindows). If none of them is in it — between a change and the
    // re-read, or for a browser that reports no standard windows — judge by geometry.
    let standard = s.standard[pid]
    let trusted: Bool
    if let standard, !standard.ids.isEmpty {
        trusted = own.contains { standard.ids.contains($0.id) }
    } else if let standard, !standard.frames.isEmpty {
        trusted = own.contains { w in standard.frames.contains { sameFrame($0, w.bounds) } }
    } else {
        trusted = false
    }
    return (own, own.filter { isMainWindow($0, among: own, standard: trusted ? standard : nil) })
}

func sameSpan(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= 2 && abs(a.width - b.width) <= 2
}

/// In full screen a browser keeps its top chrome (tab strip, toolbar) in short windows of
/// its own at the top of the display — just below the menu bar while that is revealed —
/// as wide as the browser window (the display, or one Split View tile). Brave and Chrome
/// put the strip (40 pt) and the toolbar (74 pt) in separate windows, Whale both in one
/// (72 pt), Safari its toolbar and tab bar in one (90 pt). The tab-strip band is measured
/// from the top of that chrome. Toolbars slid off screen (y < 0) and taller helper windows
/// (Brave's 143 pt hover area, 150 pt backdrop) are not chrome.
func isChromeWindow(_ w: WindowInfo, on display: CGRect, mains: [WindowInfo]) -> Bool {
    let offset = w.bounds.minY - display.minY
    return w.layer == 0 && offset >= 0 && offset <= 60 && w.bounds.height >= 20 && w.bounds.height <= 120
        && !mains.contains { $0.id == w.id }
        && mains.contains { sameSpan($0.bounds, w.bounds) && $0.bounds.intersects(display) }
}

/// The topmost window under `p` must be an ordinary (level 0) window of an enabled
/// browser — menus, tooltips and other apps' windows block it — and `p` must be in
/// its tab strip.
func hitTest(_ p: CGPoint, _ s: State) -> Hit? {
    guard let top = s.windows.first(where: { $0.bounds.contains(p) }), top.layer == 0,
          let browser = s.browsers[top.pid], !coveredInFront(p, s, except: top.pid) else { return nil }
    let band = browser.band
    let (own, mains) = browserWindows(top.pid, s)
    guard let display = s.displays.first(where: { $0.contains(p) }) else { return nil }
    let chrome = own.filter { display.contains($0.bounds.origin) && isChromeWindow($0, on: display, mains: mains) }
    if chrome.contains(where: { $0.id == top.id }) {
        let chromeTop = chrome.filter { sameSpan($0.bounds, top.bounds) }.map(\.bounds.minY).min() ?? top.bounds.minY
        let offset = p.y - chromeTop
        guard offset >= band.top, offset < band.bottom else { return nil }
        // The browser window is the tall window of the same width (Brave: below the chrome,
        // (0,114,2560,1326); Safari, Whale: the whole display); scripting and AX report it.
        let window = mains.filter { sameSpan($0.bounds, top.bounds) }.max { $0.bounds.height < $1.bounds.height }
        return Hit(pid: top.pid, window: window?.bounds ?? display, windowID: window?.id ?? top.id,
                   frontmostOwn: own.first?.id == top.id)
    }
    guard mains.contains(where: { $0.id == top.id }) else { return nil }
    // In full screen the strip is in the chrome windows (above); a window covering its
    // whole display (toolbar hidden, a video in full screen) or one with chrome windows has
    // no strip of its own, so the band would only fall on the page.
    if sameFrame(top.bounds, display) { return nil }
    if chrome.contains(where: { sameSpan($0.bounds, top.bounds) }) { return nil }
    guard shownOnDisplay(top, at: p, s) else { return nil }
    let offset = p.y - top.bounds.minY
    guard offset >= band.top, offset < band.bottom else { return nil }
    return Hit(pid: top.pid, window: top.bounds, windowID: top.id, frontmostOwn: mains.first?.id == top.id)
}

func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
        && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
}

// MARK: - Apple Events (tab switching without focusing the window)

enum AppleEvent {
    struct Failure: Error { let code: Int; let message: String }

    static func code(_ s: String) -> FourCharCode { s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) } }
    static let application = NSAppleEventDescriptor.null()

    static func specifier(want: String, from container: NSAppleEventDescriptor, form: String,
                          data: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
        record.setDescriptor(container, forKeyword: code("from"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        record.setDescriptor(data, forKeyword: code("seld"))
        return record.coerce(toDescriptorType: code("obj ")) ?? record
    }

    static func property(_ name: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: "prop", from: container, form: "prop", data: NSAppleEventDescriptor(typeCode: code(name)))
    }

    static func element(_ cls: String, _ index: Int, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: cls, from: container, form: "indx", data: NSAppleEventDescriptor(int32: Int32(index)))
    }

    static func every(_ cls: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        var all = code("all ")
        let ordinal = NSAppleEventDescriptor(descriptorType: code("abso"), bytes: &all, length: 4)!
        return specifier(want: cls, from: container, form: "indx", data: ordinal)
    }

    static func send(_ eventClass: String, _ eventID: String, to target: NSAppleEventDescriptor,
                     _ params: [String: NSAppleEventDescriptor], timeout: TimeInterval = 1) throws -> NSAppleEventDescriptor? {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: code(eventClass), eventID: code(eventID), targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        for (key, value) in params { event.setParam(value, forKeyword: code(key)) }
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
        } catch let error as NSError {
            throw Failure(code: error.code, message: error.localizedDescription)
        }
        if let number = reply.paramDescriptor(forKeyword: code("errn")), number.int32Value != 0 {
            throw Failure(code: Int(number.int32Value),
                          message: reply.paramDescriptor(forKeyword: code("errs"))?.stringValue ?? "")
        }
        return reply.paramDescriptor(forKeyword: code("----"))
    }

    static func get(_ spec: NSAppleEventDescriptor, from target: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
        try send("core", "getd", to: target, ["----": spec])
    }

    static func set(_ spec: NSAppleEventDescriptor, to value: NSAppleEventDescriptor,
                    in target: NSAppleEventDescriptor) throws {
        _ = try send("core", "setd", to: target, ["----": spec, "data": value])
    }

    static func count(_ cls: String, in container: NSAppleEventDescriptor, of target: NSAppleEventDescriptor) throws -> Int {
        Int(try send("core", "cnte", to: target, ["----": container, "kocl": NSAppleEventDescriptor(typeCode: code(cls))])?
            .int32Value ?? 0)
    }

    static func items(_ list: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard list.numberOfItems > 0 else { return [] }
        return (1...list.numberOfItems).compactMap { list.atIndex($0) }
    }

    /// A "bounds" value: a list {left, top, right, bottom} or a QuickDraw rectangle.
    static func rect(_ d: NSAppleEventDescriptor) -> CGRect? {
        if d.descriptorType == code("list") {
            let v = items(d).map { CGFloat($0.int32Value) }
            guard v.count == 4 else { return nil }
            return CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1])
        }
        if d.descriptorType == code("qdrt"), d.data.count >= 8 {
            let v = d.data.withUnsafeBytes { raw in (0..<4).map { CGFloat(raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) } }
            return CGRect(x: v[1], y: v[0], width: v[3] - v[1], height: v[2] - v[0])   // top, left, bottom, right
        }
        if let list = d.coerce(toDescriptorType: code("list")), list.descriptorType == code("list") { return rect(list) }
        return nil
    }
}

final class TabSwitcher {
    struct Key: Hashable {
        let pid: pid_t, bundleID: String, kind: ScriptKind, windowID: CGWindowID
        let x: Int, y: Int, width: Int, height: Int
        var window: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    private let queue = DispatchQueue(label: "MousePilot.appleevents", qos: .userInitiated)
    private let pending = Locked<[Key: Int]>([:])

    /// Called on the event tap thread; scrolls arriving while a switch is in flight are
    /// added up and applied together.
    func enqueue(pid: pid_t, browser: Browser, window: CGRect, windowID: CGWindowID, steps: Int) {
        let key = Key(pid: pid, bundleID: browser.bundleID, kind: browser.kind, windowID: windowID,
                      x: Int(window.minX.rounded()), y: Int(window.minY.rounded()),
                      width: Int(window.width.rounded()), height: Int(window.height.rounded()))
        let start = pending.update { p -> Bool in
            let idle = p.isEmpty
            p[key, default: 0] += steps
            return idle
        }
        if start { queue.async { self.drain() } }
    }

    private let lastRecheck = Locked<[String: TimeInterval]>([:])

    /// The user may have allowed Automation in System Settings meanwhile; look again at
    /// most every 5 s (event tap thread).
    func recheckDenied(pid: pid_t, bundleID: String) {
        let now = uptime()
        let due = lastRecheck.update { r -> Bool in
            guard now - (r[bundleID] ?? -10) >= 5 else { return false }
            r[bundleID] = now
            return true
        }
        if due { checkPermission(pid: pid, bundleID: bundleID) }
    }

    func checkPermission(pid: pid_t, bundleID: String) {
        queue.async {
            let status = self.permissionStatus(pid: pid, ask: false)
            if status != -1744 { self.record(status, for: bundleID) }   // -1744: not asked yet
        }
    }

    private func drain() {
        while true {
            let batch = pending.update { p -> [Key: Int] in
                defer { p = [:] }
                return p
            }
            if batch.isEmpty { return }
            for (key, steps) in batch where steps != 0 { perform(key, steps: steps) }
        }
    }

    private func permissionStatus(pid: pid_t, ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(AppleEvent.code("core")),
                                                     AEEventID(AppleEvent.code("getd")), ask)
    }

    private func record(_ status: OSStatus, for bundleID: String) {
        let permission: Permission = status == noErr ? .granted : status == -1743 ? .denied : .unknown
        state.update { $0.permission[bundleID] = permission }
    }

    /// Scrolls made while the permission dialog was up are dropped.
    private func permitted(_ key: Key) -> Bool {
        permitted(pid: key.pid, bundleID: key.bundleID) {
            self.pending.update { $0 = $0.filter { $0.key.bundleID != key.bundleID } }
        }
    }

    /// Asks for the Automation permission the first time (blocking the calling queue until
    /// the user answers; `asked` runs after the dialog).
    func permitted(pid: pid_t, bundleID: String, asked: () -> Void = {}) -> Bool {
        var status = permissionStatus(pid: pid, ask: false)
        if status == -1744 {
            log("asking for Automation permission for \(bundleID)")
            status = permissionStatus(pid: pid, ask: true)
            asked()
        }
        record(status, for: bundleID)
        if status != noErr { log("Automation permission for \(bundleID): \(status)") }
        return status == noErr
    }

    private func perform(_ key: Key, steps: Int) {
        guard key.kind != .none, permitted(key) else { return }
        let target = NSAppleEventDescriptor(processIdentifier: key.pid)
        let app = AppleEvent.application
        do {
            guard let i = try scriptingWindow(target, pid: key.pid, bundleID: key.bundleID, window: key.window,
                                              windowID: key.windowID) else { return }
            let window = AppleEvent.element("cwin", i, of: app)
            switch key.kind {
            case .chromium:
                let index = AppleEvent.property("acTI", of: window)
                let current = Int(try AppleEvent.get(index, from: target)?.int32Value ?? 0)
                let count = try AppleEvent.count("CrTb", in: window, of: target)
                guard count > 1, current > 0 else { return }
                let next = wrapped(current, steps, count)
                guard next != current else { return }
                try AppleEvent.set(index, to: NSAppleEventDescriptor(int32: Int32(next)), in: target)
            case .safari:
                let tab = AppleEvent.property("cTab", of: window)
                let current = Int(try AppleEvent.get(AppleEvent.property("pidx", of: tab), from: target)?.int32Value ?? 0)
                let count = try AppleEvent.count("bTab", in: window, of: target)
                guard count > 1, current > 0 else { return }
                let next = wrapped(current, steps, count)
                guard next != current else { return }
                try AppleEvent.set(tab, to: AppleEvent.element("bTab", next, of: window), in: target)
            case .none:
                return
            }
            if debug { log("switched \(key.bundleID) window \(i) by \(steps)") }
        } catch let failure as AppleEvent.Failure {
            if failure.code == -1743 { record(-1743, for: key.bundleID) }
            log("apple event to \(key.bundleID) failed: \(failure.code) \(failure.message)")
        } catch {
            log("apple event to \(key.bundleID) failed: \(error)")
        }
    }

    private func wrapped(_ current: Int, _ steps: Int, _ count: Int) -> Int {
        nextTab(current, steps, count, wrap: state.get().wrap)
    }
}

/// The number (1-based) of the browser's scripting window with these bounds; if several
/// share them (full-screen windows on different Spaces of one display), the one on
/// screen, by its title.
func scriptingWindow(_ target: NSAppleEventDescriptor, pid: pid_t, bundleID: String, window: CGRect,
                     windowID: CGWindowID) throws -> Int? {
    let app = AppleEvent.application
    guard let list = try AppleEvent.get(AppleEvent.property("pbnd", of: AppleEvent.every("cwin", of: app)),
                                        from: target) else { return nil }
    let frames = AppleEvent.items(list).map(AppleEvent.rect)
    let matches = frames.indices.filter { frames[$0].map { sameFrame($0, window) } ?? false }
    guard var i = matches.first else {
        log("no scripting window of \(bundleID) matches \(window): \(frames)")
        return nil
    }
    if matches.count > 1 {
        let title = axTitle(pid: pid, windowID: windowID, frame: window)
        if let title,
           let names = try AppleEvent.get(AppleEvent.property("pnam", of: AppleEvent.every("cwin", of: app)),
                                          from: target) {
            let list = AppleEvent.items(names).map { $0.stringValue ?? "" }
            if let j = matches.first(where: { $0 < list.count && list[$0] == title }) { i = j }
        }
        if debug { log("windows \(matches.map { $0 + 1 }) share bounds; title \(title ?? "?") -> window \(i + 1)") }
    }
    return i + 1
}

/// Tab `current` moved by `steps` (1-based): wrapping around like Ctrl+Tab, or stopping
/// at the first / last tab.
func nextTab(_ current: Int, _ steps: Int, _ count: Int, wrap: Bool) -> Int {
    wrap ? ((current - 1 + steps) % count + count) % count + 1 : min(max(current + steps, 1), count)
}

let switcher = TabSwitcher()

// MARK: - Scroll handling (event tap thread)

func sendKeys(to pid: pid_t, steps: Int) {
    let source = CGEventSource(stateID: .hidSystemState)
    let flags: CGEventFlags = steps > 0 ? .maskControl : [.maskControl, .maskShift]
    for _ in 0..<abs(steps) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: 48 /* Tab */, keyDown: down) else { continue }
            e.flags = flags
            e.postToPid(pid)
        }
    }
}

var lastLayoutLog: TimeInterval = 0   // debug: last full layout written to the log
var accumulated: CGFloat = 0         // continuous (trackpad / free-spin) scrolling
var lastContinuous: TimeInterval = 0
var lastTarget: pid_t = 0

/// Tabs to move for this scroll: positive = right (wheel down, or up when `reverse`),
/// negative = left.
func scrollSteps(_ event: CGEvent, reverse: Bool = false) -> Int {
    let steps = physicalSteps(event)
    return reverse ? -steps : steps
}

func physicalSteps(_ event: CGEvent) -> Int {
    // Physical direction regardless of the "natural scrolling" setting.
    let sign: CGFloat = (NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false) ? -1 : 1
    if event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 {
        let dy = CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * sign
        let dx = CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * sign
        let delta = abs(dy) >= abs(dx) ? dy : dx   // up/left > 0, down/right < 0
        return delta < 0 ? 1 : delta > 0 ? -1 : 0
    }
    if event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { return 0 }   // coasting after the lift
    let now = uptime()
    if event.getIntegerValueField(.scrollWheelEventScrollPhase) == 1 /* began */ || now - lastContinuous > 0.3 {
        accumulated = 0
    }
    lastContinuous = now
    let dy = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)) * sign
    let dx = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)) * sign
    accumulated += abs(dy) >= abs(dx) ? dy : dx
    var steps = 0
    while accumulated >= 30 { steps -= 1; accumulated -= 30 }   // one tab per ~3 lines
    while accumulated <= -30 { steps += 1; accumulated += 30 }
    return steps
}

enum Route { case keys, appleEvents, pass, passAndRecheck }

/// How to switch tabs for a hit: keys to the focused window of the frontmost browser,
/// Apple Events to any other window. Ctrl+Tab always wraps around, so with wrapping off
/// scriptable browsers get Apple Events (which can stop at the ends) unless that
/// permission was denied. Without scripting, only the focused window is reachable.
func route(_ hit: Hit, _ browser: Browser, _ s: State) -> Route {
    let focusedWindow = isFocusedWindow(hit, s)
    let scriptable = browser.kind != .none && s.permission[browser.bundleID] != .denied
    if focusedWindow { return s.wrap || !scriptable ? .keys : .appleEvents }
    if scriptable { return .appleEvents }
    return browser.kind == .none ? .pass : .passAndRecheck
}

/// Whether the hit window is the focused window of the frontmost browser (the one that
/// receives keys).
func isFocusedWindow(_ hit: Hit, _ s: State) -> Bool {
    guard hit.pid == s.frontPID else { return false }
    if let f = s.focused[hit.pid], f.id != nil || f.frame != nil {
        return f.id == hit.windowID || (f.frame.map { sameFrame($0, hit.window) } ?? false)
    }
    return hit.frontmostOwn
}

/// Returns true when the scroll was used to switch tabs (and must be swallowed).
func handleScroll(_ event: CGEvent) -> Bool {
    var s = state.get()
    guard !s.paused, !s.browsers.isEmpty else { return false }
    let p = event.location
    let age = uptime() - s.windowsTime
    var hit = hitTest(p, s)
    if hit != nil && age > verifyHitAfter {
        // About to act on possibly outdated geometry: confirm first (~2 ms).
        refreshWindows()
        s = state.get()
        hit = hitTest(p, s)
    } else if hit == nil && age > refreshMissAfter
                && s.windows.contains(where: { w in
                    s.browsers[w.pid] != nil && w.bounds.contains(p) && p.y - w.bounds.minY < 200
                }) {
        // Near the top of a browser window — where a strip may have appeared or been
        // uncovered since the cache was taken: let this scroll through and fix the cache
        // for the next one. (Scrolling further down a page never refreshes.)
        DispatchQueue.main.async {
            if uptime() - state.get().windowsTime > refreshMissAfter { refreshWindows() }
        }
    }
    if debug {
        log("scroll at \(p) cache \(Int(age * 1000))ms -> \(hit.map { "pid \($0.pid) window \($0.window) id \($0.windowID)" } ?? "none")")
        if hit == nil, let display = s.displays.first(where: { $0.contains(p) }), p.y - display.minY < 160 {
            // Near the top but no hit: record what is under the cursor for calibration.
            let under = s.windows.filter { $0.bounds.contains(p) }.prefix(4)
                .map { "id \($0.id) pid \($0.pid) layer \($0.layer) \($0.bounds)" }
            log("  under cursor: \(under.joined(separator: " | "))")
            // The whole window layout of the browser there (once every 2 s), to calibrate
            // layouts such as full screen.
            if let pid = s.windows.first(where: { $0.bounds.contains(p) && s.browsers[$0.pid] != nil })?.pid,
               uptime() - lastLayoutLog > 2 {
                lastLayoutLog = uptime()
                let own = s.windows.filter { $0.pid == pid }.map { "id \($0.id) L\($0.layer) \($0.bounds)" }
                log("  layout of pid \(pid): \(own.joined(separator: " | ")); standard \(s.standard[pid]?.ids.sorted() ?? []); "
                    + "focused \(s.focused[pid]?.id.map(String.init) ?? "?")")
            }
        }
    }
    guard let hit, let browser = s.browsers[hit.pid] else { return false }

    let how = route(hit, browser, s)
    if how == .pass || how == .passAndRecheck {
        if how == .passAndRecheck { switcher.recheckDenied(pid: hit.pid, bundleID: browser.bundleID) }
        return false   // cannot reach that window without focusing it: leave the scroll alone
    }
    if hit.pid != lastTarget {
        accumulated = 0
        lastTarget = hit.pid
    }
    let steps = scrollSteps(event, reverse: s.reverse)
    if steps != 0 {
        if how == .keys {
            sendKeys(to: hit.pid, steps: steps)
        } else {
            switcher.enqueue(pid: hit.pid, browser: browser, window: hit.window, windowID: hit.windowID, steps: steps)
        }
    }
    return true
}

/// Which tap a callback serves (its userInfo).
enum TapKind: Int { case scroll = 1, buttons, drags }

let callback: CGEventTapCallBack = { _, type, event, info in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        tapDisabled(TapKind(rawValue: Int(bitPattern: info)), timeout: type == .tapDisabledByTimeout)
        return Unmanaged.passUnretained(event)
    case .scrollWheel:
        return handleScroll(event) ? nil : Unmanaged.passUnretained(event)
    case .rightMouseDown, .rightMouseDragged, .rightMouseUp:
        if gestureDemoRunning { return Unmanaged.passUnretained(event) }   // check.sh's demo has the gesture
        return handleRightMouse(type, event) ? nil : Unmanaged.passUnretained(event)
    default:
        return Unmanaged.passUnretained(event)
    }
}

/// A tap went off: by our own tapEnable(false) (reported as "by user input"), or by the
/// system after a slow reply. Only ever turn a tap back on here: re-applying "off" would
/// post this event again and spin (an early preview did that, at ~37,000 round trips a
/// second). Event tap thread.
func tapDisabled(_ kind: TapKind?, timeout: Bool) {
    func reenable(_ t: CFMachPort?) {
        guard let t else { return }
        if timeout { log("event tap timed out; re-enabling") }
        CGEvent.tapEnable(tap: t, enable: true)
    }
    let s = state.get()
    switch kind {
    case .scroll:
        if s.tapOn { reenable(tap) }
    case .buttons:
        if activeGesture != nil, tapOffEndsGesture(stillOn: s.buttonTapOn,
                                                   buttonHeld: CGEventSource.buttonState(.combinedSessionState, button: .right)) {
            activeGesture = nil
            endDrawing()
            setDragTap(false)
        }
        if s.buttonTapOn { reenable(buttonTap) }
    case .drags:
        if dragTapOn { reenable(dragTap) }   // a timeout in the middle of a gesture
    case nil:
        break
    }
}

/// A gesture under way would miss its button-up while the right-button tap is off: it ends,
/// unless the tap is only coming straight back after a timeout with the button still held.
func tapOffEndsGesture(stillOn: Bool, buttonHeld: Bool) -> Bool { !stillOn || !buttonHeld }

/// The drag tap follows the gesture: right drags anywhere else never reach MousePilot.
/// Event tap thread.
func setDragTap(_ on: Bool) {
    guard on != dragTapOn else { return }
    dragTapOn = on
    if let dragTap { CGEvent.tapEnable(tap: dragTap, enable: on) }
}

/// Which taps should be on. A disabled tap is skipped by the system entirely, so each is
/// on only while it can matter, and neither while MousePilot is paused: scrolls while some
/// window of an enabled browser is on screen, right-button presses while gestures are on
/// and a window of a browser taking them (not one with gestures of its own) is.
func wantedTaps(_ s: State) -> (scroll: Bool, buttons: Bool) {
    guard !s.paused else { return (false, false) }
    let scroll = s.windows.contains { $0.layer == 0 && s.browsers[$0.pid] != nil }
    let buttons = s.gestures && s.windows.contains { w in
        w.layer == 0 && s.browsers[w.pid].map { !hasOwnGestures($0.bundleID) } == true }
    return (scroll, buttons)
}

/// Turns the scroll and right-button taps on or off as wantedTaps says. Any thread.
func updateTapState() {
    guard let tap, let buttonTap else { return }
    let (want, scrollChanged, buttonsChanged) = state.update { s -> ((scroll: Bool, buttons: Bool), Bool, Bool) in
        let want = wantedTaps(s)
        defer { (s.tapOn, s.buttonTapOn) = want }
        return (want, want.scroll != s.tapOn, want.buttons != s.buttonTapOn)
    }
    if scrollChanged { CGEvent.tapEnable(tap: tap, enable: want.scroll) }
    if buttonsChanged { CGEvent.tapEnable(tap: buttonTap, enable: want.buttons) }
    if debug, scrollChanged || buttonsChanged {
        log("event taps: scroll \(want.scroll ? "on" : "off"), right button \(want.buttons ? "on" : "off")")
    }
}

/// Creates the taps and runs them on their own thread, so main-thread work (menus,
/// Accessibility calls) never delays scrolling.
func installTap() -> Bool {
    func create(_ types: [CGEventType], _ kind: TapKind) -> CFMachPort? {
        let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                  eventsOfInterest: types.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue },
                                  callback: callback, userInfo: UnsafeMutableRawPointer(bitPattern: kind.rawValue))
        if let t { CGEvent.tapEnable(tap: t, enable: false) }   // a new tap starts enabled
        return t
    }
    let made = [create([.scrollWheel], .scroll), create([.rightMouseDown, .rightMouseUp], .buttons),
                create([.rightMouseDragged], .drags)]
    guard let scroll = made[0], let buttons = made[1], let drags = made[2] else {
        made.forEach { $0.map(CFMachPortInvalidate) }
        return false
    }
    (tap, buttonTap, dragTap) = (scroll, buttons, drags)
    state.update { s in (s.tapOn, s.buttonTapOn) = (false, false) }
    let sources = [scroll, buttons, drags].map { CFMachPortCreateRunLoopSource(nil, $0, 0) }
    let thread = Thread {
        tapRunLoop = CFRunLoopGetCurrent()
        for source in sources { CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes) }
        CFRunLoopRun()
    }
    thread.name = "MousePilot event tap"
    thread.qualityOfService = .userInteractive
    thread.start()
    log("event tap installed (version \(appVersion))")
    reloadBrowsers()
    menuController.updateIcon()
    return true
}

// MARK: - Launch at login

func isInstalled() -> Bool {
    let path = Bundle.main.bundlePath
    return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
}

/// Registers the login item once, on the first launch from an Applications folder (never
/// from a disk image or Downloads). After that the user decides — in the menu or in
/// System Settings; removing it there is respected and remembered.
func syncLoginItem() {
    let service = SMAppService.mainApp
    if defaults.object(forKey: "launchAtLogin") == nil, defaults.bool(forKey: "loginItemInitialized") {
        // Preview builds registered once and left the choice to the menu toggle: keep it.
        defaults.set(service.status == .enabled, forKey: "launchAtLogin")
    }
    guard isInstalled() else { return }
    // Where this copy ran last: a login item made for another path (the app moved or
    // renamed) is not one the user removed.
    let path = Bundle.main.bundlePath, lastPath = defaults.string(forKey: "appPath")
    defaults.set(path, forKey: "appPath")
    if defaults.object(forKey: "launchAtLogin") == nil {
        do {
            try service.register()
            defaults.set(true, forKey: "launchAtLogin")
        } catch {
            log("login item: \(error.localizedDescription)")
        }
    } else if defaults.bool(forKey: "launchAtLogin"), service.status == .notRegistered || service.status == .notFound {
        if lastPath != path {
            do { try service.register() } catch { log("login item at the new path: \(error.localizedDescription)") }
        } else {
            defaults.set(false, forKey: "launchAtLogin")   // removed in System Settings
        }
    }
}

// MARK: - Menu bar

final class MenuController: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()

    override init() {
        super.init()
        menu.delegate = self
        item.menu = menu
        updateIcon()
    }

    func updateIcon() {
        let image = NSImage(systemSymbolName: "arrow.left.arrow.right.square",
                            accessibilityDescription: "MousePilot")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.appearsDisabled = state.get().paused || tap == nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = state.get()
        let status = tap == nil ? "손쉬운 사용 권한 필요" : s.paused ? "일시정지됨" : "켜짐"
        menu.addItem(withTitle: "MousePilot \(appVersion): \(status)", action: nil, keyEquivalent: "")
        if tap == nil {
            add("손쉬운 사용 설정 열기…", #selector(openAccessibility))
        }
        menu.addItem(.separator())
        add(s.paused ? "다시 켜기" : "일시정지", #selector(togglePause))
        let wrap = NSMenuItem(title: "순환 (마지막 탭 → 첫 탭)", action: #selector(toggleWrap), keyEquivalent: "")
        wrap.target = self
        wrap.state = s.wrap ? .on : .off
        wrap.toolTip = "끄면 양 끝 탭에서 멈춥니다. 이때는 포커스된 창도 자동화 권한으로 탭을 바꿉니다 (Firefox·Arc는 항상 순환)."
        menu.addItem(wrap)
        let reverse = NSMenuItem(title: "휠 방향 반대로 (위 = 오른쪽 탭)", action: #selector(toggleReverse), keyEquivalent: "")
        reverse.target = self
        reverse.state = s.reverse ? .on : .off
        menu.addItem(reverse)

        let gestureMenu = NSMenu()
        for (i, (title, on)) in [("사용하기", s.gestures), ("제스처 선 그리기", s.gestureStroke),
                                 ("제스처 타이틀 보기", s.gestureTitle)].enumerated() {
            let mi = NSMenuItem(title: title, action: #selector(toggleGestureSetting(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.state = on ? .on : .off
            gestureMenu.addItem(mi)
        }
        gestureMenu.addItem(.separator())
        let settings = NSMenuItem(title: "제스처 설정…", action: #selector(openGestureSettings), keyEquivalent: "")
        settings.target = self
        gestureMenu.addItem(settings)
        let gestures = NSMenuItem(title: "마우스 제스처", action: nil, keyEquivalent: "")
        gestures.toolTip = "브라우저 창 위에서 오른쪽 버튼을 누른 채 그으면 동작합니다."
        gestures.submenu = gestureMenu
        menu.addItem(gestures)

        let sub = NSMenu()
        let enabled = readConfig()
        let denied = Set(s.browsers.values.filter { s.permission[$0.bundleID] == .denied }.map(\.bundleID))
        for (i, b) in knownBrowsers.enumerated()
        where enabled[b.id.lowercased()] != nil || NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.id) != nil {
            let title = denied.contains(b.id) ? "\(b.name) — 뒤쪽 창 권한 없음" : b.name
            let mi = NSMenuItem(title: title, action: #selector(toggleBrowser(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.state = enabled[b.id.lowercased()] != nil ? .on : .off
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        let edit = NSMenuItem(title: "설정 파일 열기…", action: #selector(openConfig), keyEquivalent: "")
        edit.target = self
        sub.addItem(edit)
        if !denied.isEmpty {
            let automation = NSMenuItem(title: "자동화 권한 설정 열기…", action: #selector(openAutomation),
                                        keyEquivalent: "")
            automation.target = self
            sub.addItem(automation)
        }
        let browsers = NSMenuItem(title: "적용 브라우저", action: nil, keyEquivalent: "")
        browsers.submenu = sub
        menu.addItem(browsers)

        menu.addItem(.separator())
        let login = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval:
            login.title = "로그인 시 자동 실행 (시스템 설정에서 승인 필요)…"
            login.state = .mixed
        default: login.state = .off
        }
        menu.addItem(login)
        add("로그 폴더 열기…", #selector(openLogs))
        menu.addItem(.separator())
        add("MousePilot 종료", #selector(quit))
    }

    private func add(_ title: String, _ action: Selector) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        menu.addItem(mi)
    }

    @objc func togglePause() {
        let paused = state.update { s -> Bool in
            s.paused.toggle()
            return s.paused
        }
        defaults.set(paused, forKey: "paused")
        updateTapState()
        updateIcon()
    }

    @objc func toggleReverse() {
        let reverse = state.update { s -> Bool in
            s.reverse.toggle()
            return s.reverse
        }
        defaults.set(reverse, forKey: "reverseDirection")
    }

    @objc func toggleWrap() {
        let wrap = state.update { s -> Bool in
            s.wrap.toggle()
            return s.wrap
        }
        defaults.set(wrap, forKey: "wrapAround")
    }

    @objc func toggleGestureSetting(_ sender: NSMenuItem) {
        guard let setting = GestureSetting(rawValue: sender.tag) else { return }
        setGestureSetting(setting, sender.state == .off)
    }

    @objc func openGestureSettings() {
        GestureSettings.show()
    }

    @objc func toggleBrowser(_ sender: NSMenuItem) {
        setBrowser(knownBrowsers[sender.tag], enabled: sender.state == .off)
    }

    @objc func openConfig() {
        ensureConfigFile()
        openInTextEditor(configPath)
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func openAutomation() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    @objc func toggleLogin() {
        let service = SMAppService.mainApp
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        let enable = service.status != .enabled
        defaults.set(enable, forKey: "launchAtLogin")
        do {
            if enable { try service.register() } else { try service.unregister() }
        } catch {
            log("login item: \(error.localizedDescription)")
        }
    }

    @objc func openLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: logPath)])
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

}

// MARK: - Startup

#if SELFTEST
exit(runSelfTests() == 0 ? 0 : 1)   // scripts/check.sh builds this with Tests/SelfTests.swift
#endif
#if OVERLAYTEST
runOverlayTest()                     // scripts/check.sh builds this with Tests/OverlayTest.swift
#endif

// One instance only: two would each switch tabs on the same scroll.
let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.pms.mousepilot")
    .filter { $0.processIdentifier != getpid() }
if let other = others.first {
    log("another MousePilot is already running (pid \(other.processIdentifier)); exiting")
    logQueue.sync {}   // flush before exiting
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// An accessory app shows no menu bar, but the shortcuts of its main menu work while it is
// active: ⌘W closes the gesture settings window.
app.mainMenu = {
    let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu()
    submenu.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    item.submenu = submenu
    menu.addItem(item)
    return menu
}()
// Accessibility calls go to other apps' main threads; never wait long on a busy one.
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
ensureConfigFile()
refreshDisplays()
state.update { $0.frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }
let menuController = MenuController()
syncLoginItem()
watchConfig()
refreshGestureMap()

let workspace = NSWorkspace.shared.notificationCenter
var configStamp = configModified()
/// The config file's stamp (one stat), to notice edits made in place, which the directory
/// watch does not see, and edits to a symlink's target.
func configModified() -> FileStamp? { fileStamp(configPath) }

var lastOtherFrontPID = state.get().frontPID   // main thread: the last app other than MousePilot in front
workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
    let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? 0
    state.update { $0.frontPID = pid }
    if pid != getpid() { lastOtherFrontPID = pid }
    refreshGestureMap()   // an edit in place, made in the app the user comes from
    let stamp = configModified()
    if stamp != configStamp {
        configStamp = stamp
        reloadBrowsers()
    } else if !state.get().browsers.isEmpty {
        scheduleRefresh()   // window order changed
    }
    if let browser = state.get().browsers[pid] {
        scheduleAXRefresh(pid, windowList: false)
        if browser.kind != .none, state.get().permission[browser.bundleID] == .denied {
            switcher.checkPermission(pid: pid, bundleID: browser.bundleID)   // re-enabled in System Settings?
        }
    }
}
for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
    workspace.addObserver(forName: name, object: nil, queue: .main) { _ in reloadBrowsers() }
}
/// Re-reads every browser's windows from Accessibility (its list covers only the
/// current Spaces) and the window cache.
func refreshAllWindows() {
    scheduleRefresh()
    for pid in state.get().browsers.keys { scheduleAXRefresh(pid) }
}

workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
    refreshAllWindows()
}
workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
    refreshDisplays()
    refreshAllWindows()
    updateTapState()
}
NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                       object: nil, queue: .main) { _ in
    refreshDisplays()
    refreshAllWindows()
}

if defaults.bool(forKey: "gestureDemo") { installGestureDemo() }   // scripts/check.sh's debuggable copy

// Ask once for Accessibility permission, then keep retrying until granted.
_ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
if !installTap() {
    reloadBrowsers()
    log("waiting for Accessibility permission")
    Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
        if installTap() { timer.invalidate() }
    }
}
app.run()
