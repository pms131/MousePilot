// Mouse gestures like Naver Whale's: hold the right button over a browser window, draw one
// or two strokes (left, right, up, down) and let go. Whale's own defaults apply (read from
// Whale 4.35) unless ~/.config/mousepilot/gestures says otherwise, one per line:
//   <gesture> <ACTION>      e.g.  DR CLOSE_TAB      (L R U D, at most two strokes)
// A right click without a stroke still opens the context menu — on release, as in Whale
// with gestures on. Browsers with mouse gestures of their own (Whale, Vivaldi, Opera) are
// left alone.
//
// The event tap thread recognizes the strokes. Actions run on their own queue as the
// browser's menu commands or keyboard shortcuts, after bringing the window forward if it
// was not the focused one; opening the page in an incognito window uses Apple Events
// (Chromium).
// The trail and the title are drawn on the main thread by two click-through panels sized
// to what they show, hidden and shrunk again when the button is released.

import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore

// MARK: - Gestures and actions

enum GestureAction: String, CaseIterable {
    case none = "NONE", back = "BACK", forward = "FORWARD", top = "JUMPTO_TOP", bottom = "JUMPTO_BOTTOM"
    case homepage = "HOMEPAGE", refresh = "REFRESH", fullScreen = "FULLSCREEN_WINDOW"
    case maximize = "MAXIMIZE_WINDOW", minimize = "MINIMIZE_WINDOW", newWindow = "NEW_WINDOW", newTab = "NEW_TAB"
    case incognito = "OPENIN_SECRET_WINDOW", closeWindow = "CLOSE_WINDOW", previousTab = "ACTIVATE_LEFT_TAB"
    case nextTab = "ACTIVATE_RIGHT_TAB", closeTab = "CLOSE_TAB", reopenTab = "REOPEN_CLOSED_TAB"
    case pageUp = "PAGE_UP", pageDown = "PAGE_DOWN", bookmark = "TOGGLE_BOOKMARK"
    case bookmarkBar = "TOGGLE_BOOKMARKBAR", downloads = "OPEN_DOWNLOADS"

    /// Whale's names (its settings use the same identifiers).
    var title: String { gestureTitles[self] ?? rawValue }
}

let gestureTitles: [GestureAction: String] = [
    .none: "없음", .back: "이전 페이지", .forward: "다음 페이지", .top: "맨 위로", .bottom: "맨 아래로",
    .homepage: "홈페이지로", .refresh: "새로고침", .fullScreen: "전체화면", .maximize: "창 최대화",
    .minimize: "창 최소화", .newWindow: "새 창 열기", .newTab: "새 탭 열기", .incognito: "시크릿창에서 열기",
    .closeWindow: "창 닫기", .previousTab: "왼쪽 탭으로 이동", .nextTab: "오른쪽 탭으로 이동", .closeTab: "탭 닫기",
    .reopenTab: "닫은 탭 다시 열기", .pageUp: "한 페이지 위로 이동", .pageDown: "한 페이지 아래로 이동",
    .bookmark: "북마크에 추가", .bookmarkBar: "북마크바 표시/숨기기", .downloads: "다운로드",
]

/// The 16 gestures in the order of Whale's settings.
let gestureCodes = ["L", "R", "U", "D", "LR", "RL", "UD", "DU", "UL", "UR", "DL", "DR", "LU", "LD", "RU", "RD"]

/// Whale 4.35's defaults (its preference registration).
let whaleGestures: [String: GestureAction] = [
    "L": .back, "R": .forward, "U": .top, "D": .bottom, "LR": .homepage, "RL": .homepage,
    "DU": .refresh, "UD": .refresh, "LU": .fullScreen, "RU": .maximize, "RD": .minimize,
    "UL": .newWindow, "UR": .newTab, "DL": .incognito, "DR": .closeTab, "LD": .reopenTab,
]

/// Browsers with mouse gestures of their own (bundle ID prefixes, lowercased; Opera's and
/// Vivaldi's variants included). Edge's gestures are Windows only.
let builtInGesturePrefixes = ["com.naver.whale", "com.vivaldi.", "com.operasoftware."]

func hasOwnGestures(_ bundleID: String) -> Bool {
    let id = bundleID.lowercased()
    return builtInGesturePrefixes.contains { id.hasPrefix($0) }
}

struct KeyChord: Equatable { let key: CGKeyCode; let flags: CGEventFlags }

/// The browser's shortcut for an action: Chromium's (= the macOS convention), Safari's and
/// Firefox's where they differ. Nil for actions done another way.
func keyChord(_ action: GestureAction, bundleID: String) -> KeyChord? {
    let firefox = bundleID.hasPrefix("org.mozilla."), safari = bundleID == "com.apple.Safari"
    let cmd = CGEventFlags.maskCommand, shift = CGEventFlags.maskShift
    let ctrl = CGEventFlags.maskControl, option = CGEventFlags.maskAlternate
    let fn = CGEventFlags.maskSecondaryFn
    func chord(_ key: CGKeyCode, _ flags: CGEventFlags) -> KeyChord { KeyChord(key: key, flags: flags) }
    switch action {
    case .back: return chord(0x21, cmd)                                     // ⌘[
    case .forward: return chord(0x1E, cmd)                                  // ⌘]
    // Home and End scroll the page even with the caret in a text field (⌘↑/⌘↓ would move it);
    // a gesture sends them only when it cannot scroll by wheel (see wheelDelta).
    case .top: return chord(0x73, fn)                                       // Home
    case .bottom: return chord(0x77, fn)                                    // End
    case .homepage: return firefox ? chord(0x73, option.union(fn)) : chord(0x04, [cmd, shift])   // ⌥Home / ⌘⇧H
    case .refresh: return chord(0x0F, cmd)                                  // ⌘R
    case .fullScreen: return chord(0x03, [cmd, ctrl])                       // ⌃⌘F
    case .minimize: return chord(0x2E, cmd)                                 // ⌘M
    case .newWindow: return chord(0x2D, cmd)                                // ⌘N
    case .newTab: return chord(0x11, cmd)                                   // ⌘T
    // A private window; the page itself goes along only by scripting (Chromium, see below).
    case .incognito: return firefox ? chord(0x23, [cmd, shift]) : chord(0x2D, [cmd, shift])   // ⌘⇧P / ⌘⇧N
    case .closeWindow: return chord(0x0D, [cmd, shift])                     // ⌘⇧W
    case .previousTab: return chord(0x30, [ctrl, shift])                    // ⌃⇧Tab
    case .nextTab: return chord(0x30, ctrl)                                 // ⌃Tab
    case .closeTab: return chord(0x0D, cmd)                                 // ⌘W
    case .reopenTab: return chord(0x11, [cmd, shift])                       // ⌘⇧T
    case .pageUp: return chord(0x74, fn)                                    // Page Up
    case .pageDown: return chord(0x79, fn)                                  // Page Down
    case .bookmark: return chord(0x02, cmd)                                 // ⌘D
    case .bookmarkBar: return chord(0x0B, [cmd, shift])                     // ⌘⇧B
    case .downloads:                                                        // ⌥⌘L / ⌘J / ⌘⇧J
        return safari ? chord(0x25, [cmd, option]) : firefox ? chord(0x26, cmd) : chord(0x26, [cmd, shift])
    case .none, .maximize: return nil
    }
}

/// Top, bottom, page up and page down go as one wheel event at the pointer rather than as
/// Home, End, Page Up or Page Down: a page element with focus takes those keys first — a
/// YouTube player seeks to the start or the end with Home and End — while a wheel event goes
/// to what is under the pointer, and a player passes it on to the page. Pixels, + = up; nil
/// for the other actions.
func wheelDelta(_ action: GestureAction, windowHeight: CGFloat) -> Int32? {
    let page = Int32(max(100, (windowHeight - pageTop) * 0.875))   // about what Page Down scrolls
    switch action {
    case .top: return wholePage
    case .bottom: return -wholePage
    case .pageUp: return page
    case .pageDown: return -page
    default: return nil
    }
}

let wholePage: Int32 = 10_000_000   // pixels: more than any page; the browser stops at the end
/// How far below a window's top edge its page may start (tab strip, toolbar, bookmarks bar).
let pageTop: CGFloat = 120

/// Where a gesture ended: the pointer, and the session's location at that moment, which the
/// gesture's swallowed events never moved — it is where the last event that went through left
/// it: the gesture's start, or the start of an earlier gesture made without moving between —
/// and how many gestures had begun by then.
struct GestureEnd { let pointer: CGPoint; let session: CGPoint?; let gesturesBegun: Int }

/// Right-button gestures begun so far (event tap thread writes, the actions read).
let gesturesBegun = Locked(0)

/// Where a gesture's wheel event goes, which is where the pointer is just after the gesture:
/// where the button was released while the session's location is still what it was then
/// (the pointer has not moved since), the session's location once it has. Nil — the pointer
/// is not known, and the keys go instead — when a button is held (a drag or another gesture
/// under way), when a later gesture has begun (its swallowed events moved the pointer unseen
/// too: an action run late), or when the session's location could not be read.
func wheelPoint(session: CGPoint?, end: GestureEnd, gesturesBegun begun: Int, buttonHeld: Bool) -> CGPoint? {
    guard !buttonHeld, begun == end.gesturesBegun, let session, let then = end.session else { return nil }
    return hypot(session.x - then.x, session.y - then.y) < 0.5 ? end.pointer : session
}

/// Whether a mouse button is held: a drag or another gesture under way, whose pointer moves
/// the session has not seen (a gesture's are swallowed) — a posted wheel event would pull
/// the pointer back to where the session last saw it.
func mouseButtonHeld() -> Bool {
    [CGMouseButton.left, .right, .center].contains { CGEventSource.buttonState(.hidSystemState, button: $0) }
}

/// Whether a wheel event at `p` goes to the page of `window` rather than to its toolbars.
func onPage(_ p: CGPoint, window: CGRect) -> Bool {
    window.contains(p) && p.y - window.minY >= pageTop
}

/// The character a menu shows for a shortcut's key (the keys the actions use).
func menuCharacter(_ key: CGKeyCode) -> String? {
    [0x21: "[", 0x1E: "]", 0x0F: "R", 0x04: "H", 0x03: "F", 0x2E: "M", 0x2D: "N", 0x11: "T",
     0x0D: "W", 0x02: "D", 0x0B: "B", 0x26: "J", 0x25: "L", 0x23: "P"][key]
}

/// Accessibility's modifier mask for a ⌘ shortcut in a menu (⇧ 1, ⌥ 2, ⌃ 4; ⌘ implied);
/// nil without ⌘, which menu commands here always have.
func axMenuModifiers(_ flags: CGEventFlags) -> Int? {
    guard flags.contains(.maskCommand) else { return nil }
    return (flags.contains(.maskShift) ? 1 : 0) | (flags.contains(.maskAlternate) ? 2 : 0) | (flags.contains(.maskControl) ? 4 : 0)
}

/// Chromium's tab and window shortcuts (⌘W ⌘⇧W ⌘T ⌘⇧T ⌘N ⌘⇧N) go as keys, not menu presses:
/// what ⌘W closes — the tab, or a popup or DevTools window — Chromium settles only when a key
/// comes in, by renaming one menu item, and a press would run whatever that item last meant,
/// closing a whole window. Pages cannot take these keys, except in full screen with the
/// toolbar hidden, where they reach the page first, as the user's own keys would.
func goesAsKeys(_ chord: KeyChord, kind: ScriptKind) -> Bool {
    guard kind == .chromium, chord.flags.subtracting(.maskShift) == .maskCommand else { return false }
    return [0x0D, 0x11, 0x2D].contains(chord.key)   // W, T, N
}

/// AppKit brings a menu up to date for Accessibility at most once a second
/// (-[NSMenu(Accessibility) _openForInspection:]), so an item read again sooner can still
/// show the state of the last read: a command enabled since then reads disabled.
let menuRefreshInterval: TimeInterval = 1.1

/// How long to wait before an item that reads disabled can be believed, given when the
/// app's menus were last read.
func staleMenuWait(since lastRead: TimeInterval?, now: TimeInterval) -> TimeInterval {
    guard let lastRead else { return 0 }
    return max(0, lastRead + menuRefreshInterval - now)
}

/// Whether a menu item's Accessibility modifier mask is this ⌘ shortcut's. macOS adds 16
/// for fn (globe) to items it lists with fn: Enter Full Screen is fn⌃⌘F (20), not ⌃⌘F.
func menuModifiersMatch(_ ax: Int?, _ wanted: Int) -> Bool {
    ax.map { $0 & ~16 == wanted } ?? false
}

/// How long a shortcut no menu had is not looked for again.
let menuMissRecheck: TimeInterval = 120

/// Whether a "disabled" read can be believed: the menus were read up to date after the
/// gesture was made and after MousePilot last acted on the app (a Back makes Forward enabled).
func menuReadIsFresh(refreshedAt: TimeInterval?, changedAt: TimeInterval?, made: TimeInterval) -> Bool {
    guard let refreshedAt else { return false }
    return refreshedAt >= max(made, changedAt ?? 0)
}

enum MenuPress: Equatable { case done, lookAgain, useKeys }

/// What a menu item press's result means. A press that timed out was still delivered, and
/// the app runs it once it is free (AXUIElement.h): pressing again or posting the shortcut
/// as well would run the command twice.
func menuPressOutcome(_ result: AXError, remembered: Bool) -> MenuPress {
    switch result {
    case .success, .cannotComplete: return .done
    case .invalidUIElement where remembered: return .lookAgain   // its menu was rebuilt since
    default: return .useKeys
    }
}

// MARK: - Config

let gesturePath = configDir + "/gestures"

/// "L" … "RD" (any case), or nil if not one of the 16 gestures.
func gestureCode(_ s: String) -> String? {
    let code = s.uppercased()
    return gestureCodes.contains(code) ? code : nil
}

/// Whale's defaults, overridden by the lines of the gestures file.
func parseGestures(_ text: String) -> [String: GestureAction] {
    var map = whaleGestures
    for line in configLines(text) {
        let fields = configFields(line)
        guard fields.count >= 2, let code = gestureCode(fields[0]),
              let action = GestureAction(rawValue: fields[1].uppercased()) else { continue }
        map[code] = action
    }
    return map
}

func defaultGestureText() -> String {
    var lines = ["# MousePilot 마우스 제스처: <제스처> <동작>   (고치면 다음 제스처부터 적용)",
                 "# 제스처는 오른쪽 버튼을 누른 채 긋는 방향: L 왼쪽, R 오른쪽, U 위, D 아래 — 두 획까지",
                 "# (예: DR = 아래로 그은 뒤 오른쪽으로). 동작을 NONE으로 하면 그 제스처는 쓰지 않습니다.",
                 "# 동작:"]
    lines += GestureAction.allCases.map { "#   \($0.rawValue.padding(toLength: 21, withPad: " ", startingAt: 0))\($0.title)" }
    lines.append("")
    lines += gestureCodes.map { "\($0.padding(toLength: 4, withPad: " ", startingAt: 0))\(whaleGestures[$0]!.rawValue)" }
    return lines.joined(separator: "\n") + "\n"
}

func ensureGestureFile() {
    guard !FileManager.default.fileExists(atPath: gesturePath) else { return }   // follows a link
    try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
    writeConfig(defaultGestureText(), to: gesturePath)
}

private let gestureFile = Locked<(stamp: FileStamp?, map: [String: GestureAction])>((nil, whaleGestures))

/// The gesture map as last read. The event tap thread uses only this: a file behind a link
/// on a network or cloud disk can take seconds to answer, and input would wait on it.
func currentGestureMap() -> [String: GestureAction] { gestureFile.get().map }

private let gestureMapQueue = DispatchQueue(label: "MousePilot.gesturemap", qos: .utility)
private let gestureMapReading = Locked(false)

/// Re-reads the gestures file on a background queue if it changed; one read at a time.
func refreshGestureMap() {
    guard gestureMapReading.update({ busy -> Bool in defer { busy = true }; return !busy }) else { return }
    gestureMapQueue.async {
        _ = gestureMap()
        gestureMapReading.update { $0 = false }
    }
}

/// The gesture map, re-read when the file has changed (one stat). Not on the event tap thread.
func gestureMap() -> [String: GestureAction] {
    let stamp = fileStamp(gesturePath)
    return gestureFile.update { file in
        if file.stamp != stamp {
            file.stamp = stamp
            var encoding = String.Encoding.utf8
            let text = stamp == nil ? nil : try? String(contentsOfFile: gesturePath, usedEncoding: &encoding)
            file.map = text.map(parseGestures) ?? whaleGestures
        }
        return file.map
    }
}

/// The gestures file's lines with `code` set to `action`: its line replaced (later
/// duplicates dropped), or one added at the end.
func gestureLines(_ lines: [String], setting code: String, to action: GestureAction) -> [String] {
    let entry = code.padding(toLength: 4, withPad: " ", startingAt: 0) + action.rawValue
    var out: [String] = [], done = false
    for line in lines {
        guard configFields(line).first.flatMap(gestureCode) == code else {
            out.append(line)
            continue
        }
        if !done { out.append(entry) }
        done = true
    }
    if !done {
        while out.last?.isEmpty == true { out.removeLast() }
        out.append(entry)
    }
    return out
}

/// Sets one gesture's action in the gestures file (the settings window's choices).
func setGesture(_ code: String, _ action: GestureAction) {
    ensureGestureFile()
    var encoding = String.Encoding.utf8
    guard let text = try? String(contentsOfFile: gesturePath, usedEncoding: &encoding) else {
        log("cannot read \(gesturePath); not changing it")
        NSSound.beep()
        return
    }
    var lines = gestureLines(configLines(text), setting: code, to: action)
    while lines.last?.isEmpty == true { lines.removeLast() }
    if !writeConfig(lines.joined(separator: "\n") + "\n", to: gesturePath) { NSSound.beep() }
}

// MARK: - Pictures of the gestures

/// A gesture's picture as arrows in unit steps (y down), each drawn with a head at its
/// end: one arrow for one stroke, one bent arrow for two, and for there-and-back two
/// side by side (the way out above or left of the way back).
func gestureIconStrokes(_ code: String) -> [[CGPoint]] {
    let step: [Character: CGPoint] = ["L": CGPoint(x: -1, y: 0), "R": CGPoint(x: 1, y: 0),
                                      "U": CGPoint(x: 0, y: -1), "D": CGPoint(x: 0, y: 1)]
    let moves = code.compactMap { step[$0] }
    guard let first = moves.first else { return [] }
    if moves.count == 2, first.x == -moves[1].x, first.y == -moves[1].y {
        let side = CGPoint(x: abs(first.y) / 2, y: abs(first.x) / 2)
        return [[.zero, first], [CGPoint(x: first.x + side.x, y: first.y + side.y), side]]
    }
    var points = [CGPoint.zero]
    for m in moves { points.append(CGPoint(x: points[points.count - 1].x + m.x, y: points[points.count - 1].y + m.y)) }
    return [points]
}

/// A picture of a gesture, `size` points square.
func gestureImage(_ code: String, size: CGFloat, color: NSColor) -> NSImage {
    let strokes = gestureIconStrokes(code)
    let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
        let all = strokes.flatMap { $0 }
        guard !all.isEmpty else { return false }
        let xs = all.map(\.x), ys = all.map(\.y)
        let span = CGSize(width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let box = rect.insetBy(dx: size * 0.2, dy: size * 0.2)   // room for the arrowheads
        let scale = min(span.width > 0 ? box.width / span.width : .infinity,
                        span.height > 0 ? box.height / span.height : .infinity)
        let origin = CGPoint(x: box.midX - (xs.min()! + span.width / 2) * scale,
                             y: box.midY - (ys.min()! + span.height / 2) * scale)
        let path = NSBezierPath()
        path.lineWidth = max(1.5, size / 13)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for stroke in strokes {
            let p = stroke.map { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) }
            path.move(to: p[0])
            if p.count == 3 {   // a bend, rounded
                let r = scale * 0.3
                func toward(_ a: CGPoint, _ b: CGPoint, _ d: CGFloat) -> CGPoint {
                    let l = hypot(b.x - a.x, b.y - a.y)
                    return CGPoint(x: a.x + (b.x - a.x) * d / l, y: a.y + (b.y - a.y) * d / l)
                }
                path.line(to: toward(p[1], p[0], r))
                path.curve(to: toward(p[1], p[2], r), controlPoint1: p[1], controlPoint2: p[1])
            }
            path.line(to: p[p.count - 1])
            let end = p[p.count - 1], from = p[p.count - 2]
            let angle = atan2(end.y - from.y, end.x - from.x), head = size * 0.22
            for turn in [CGFloat.pi * 0.75, -CGFloat.pi * 0.75] {
                path.move(to: end)
                path.line(to: CGPoint(x: end.x + head * cos(angle + turn), y: end.y + head * sin(angle + turn)))
            }
        }
        color.setStroke()
        path.stroke()
        return true
    }
    image.accessibilityDescription = code
    return image
}

enum GestureSetting: Int { case enabled, stroke, title }

/// Turns gestures, the trail or the title on or off (menu and settings window).
func setGestureSetting(_ setting: GestureSetting, _ on: Bool) {
    state.update { s in
        switch setting {
        case .enabled: s.gestures = on
        case .stroke: s.gestureStroke = on
        case .title: s.gestureTitle = on
        }
    }
    defaults.set(on, forKey: ["mouseGestures", "gestureStroke", "gestureTitle"][setting.rawValue])
    if setting == .enabled { updateTapState() }   // the right-button tap follows
    GestureSettings.refresh()
}

// MARK: - Recognizing the strokes

/// Up to two strokes in four directions. A stroke counts once the cursor has gone
/// `stroke` points from where the last counted movement ended, in the dominant axis, so
/// wobble and small turns do not; a third stroke voids the gesture (as in Whale).
struct GestureTracker {
    static let stroke: CGFloat = 20
    private(set) var directions: [Character] = []
    private(set) var invalid = false
    private var anchor: CGPoint

    init(at p: CGPoint) { anchor = p }

    var started: Bool { !directions.isEmpty }
    /// "L", "UR", …; nil before the first stroke and after a third.
    var code: String? { invalid || directions.isEmpty ? nil : String(directions) }
    var arrows: String { directions.map { ["L": "←", "R": "→", "U": "↑", "D": "↓"][$0] ?? "" }.joined(separator: " ") }

    /// Adds a cursor position (global coordinates, y down); true when the gesture changed.
    mutating func move(to p: CGPoint) -> Bool {
        let dx = p.x - anchor.x, dy = p.y - anchor.y
        guard max(abs(dx), abs(dy)) >= Self.stroke else { return false }
        anchor = p
        let d: Character = abs(dx) >= abs(dy) ? (dx > 0 ? "R" : "L") : (dy > 0 ? "D" : "U")
        guard !invalid, d != directions.last else { return false }
        if directions.count == 2 { invalid = true } else { directions.append(d) }
        return true
    }
}

/// The window a gesture starting at `p` acts on: the topmost window there must be a
/// browser window proper — not a popup, menu or another app's window — of an enabled
/// browser without gestures of its own. Anywhere in it counts, tab strip included.
func gestureTarget(_ p: CGPoint, _ s: State) -> Hit? {
    guard let top = s.windows.first(where: { $0.bounds.contains(p) }), top.layer == 0,
          let browser = s.browsers[top.pid], !hasOwnGestures(browser.bundleID),
          !coveredInFront(p, s, except: top.pid), shownOnDisplay(top, at: p, s) else { return nil }
    let mains = browserWindows(top.pid, s).mains
    guard mains.contains(where: { $0.id == top.id }) else { return nil }
    return Hit(pid: top.pid, window: top.bounds, windowID: top.id, frontmostOwn: mains.first?.id == top.id)
}

// MARK: - Right-button events (event tap thread)

struct Gesture {
    var tracker: GestureTracker
    let hit: Hit
    let browser: Browser
    let focused: Bool        // the focused window of the frontmost app when it began
    let map: [String: GestureAction]
    let flags: CGEventFlags
    let start: CGPoint
    let press: Int64         // the button press's event number, shared by its button-up
}

let gestureTag: Int64 = 0x5457_4730   // "TWG0": the right clicks and page scrolls MousePilot posts
var activeGesture: Gesture?          // event tap thread only

/// Returns true when the event belongs to a gesture (and must be swallowed).
func handleRightMouse(_ type: CGEventType, _ event: CGEvent) -> Bool {
    if event.getIntegerValueField(.eventSourceUserData) == gestureTag { return false }
    let p = event.location
    switch type {
    case .rightMouseDown:
        if activeGesture != nil { endDrawing() }   // its button-up was lost (the tap was off)
        activeGesture = startGesture(at: p, flags: event.flags,
                                     press: event.getIntegerValueField(.mouseEventNumber))
        setDragTap(activeGesture != nil)   // before returning, so the drags that follow come here
        return activeGesture != nil
    case .rightMouseDragged:
        guard var g = activeGesture else { return false }
        let changed = g.tracker.move(to: p)
        activeGesture = g
        draw(g, at: p, changed: changed)
        return true
    case .rightMouseUp:
        guard let g = activeGesture else { return false }
        activeGesture = nil
        setDragTap(false)
        endDrawing()
        // The release of a press the tap never saw (it was off): not this gesture's.
        guard event.getIntegerValueField(.mouseEventNumber) == g.press else { return false }
        finish(g, at: p)
        return true
    default:
        return false
    }
}

func startGesture(at p: CGPoint, flags: CGEventFlags, press: Int64) -> Gesture? {
    var s = state.get()
    guard s.gestures, !s.paused, !s.browsers.isEmpty else { return nil }
    var hit = gestureTarget(p, s)
    if uptime() - s.windowsTime > verifyHitAfter, mayBeGestureTarget(p, s) {
        refreshWindows()   // about to take over a click on possibly outdated geometry (~2 ms)
        s = state.get()
        hit = gestureTarget(p, s)
    }
    guard let hit, let browser = s.browsers[hit.pid] else { return nil }
    beginDrawing(at: p, window: hit.window, stroke: s.gestureStroke, title: s.gestureTitle)
    refreshGestureMap()   // for the next gesture: the file is never read on this thread
    gesturesBegun.update { $0 += 1 }
    return Gesture(tracker: GestureTracker(at: p), hit: hit, browser: browser, focused: isFocusedWindow(hit, s),
                   map: currentGestureMap(), flags: flags, start: p, press: press)
}

/// Whether a fresh window list could make `p` a gesture's start: a window of a browser
/// taking MousePilot's gestures is under it, and the top one there is not a browser with
/// gestures of its own (right clicks there are left alone without asking WindowServer).
func mayBeGestureTarget(_ p: CGPoint, _ s: State) -> Bool {
    let gestureBrowser = { (w: WindowInfo) in s.browsers[w.pid].map { !hasOwnGestures($0.bundleID) } == true }
    guard let top = s.windows.first(where: { $0.bounds.contains(p) }) else { return false }
    if let browser = s.browsers[top.pid], hasOwnGestures(browser.bundleID) { return false }
    return s.windows.contains { $0.bounds.contains(p) && gestureBrowser($0) }
}

func finish(_ g: Gesture, at p: CGPoint) {
    guard g.tracker.started else {
        repostRightClick(at: clickPoint(g, release: p, state.get()), flags: g.flags)
        return
    }
    let action = g.tracker.code.flatMap { g.map[$0] } ?? GestureAction.none
    if debug {
        log("gesture \(g.tracker.code ?? "(three strokes)") -> \(action.rawValue) on \(g.browser.bundleID) "
            + "window \(g.hit.windowID)\(g.focused ? "" : " (not focused)")")
    }
    guard action != .none else { return }
    gestureActions.perform(action, g, end: GestureEnd(pointer: p, session: CGEvent(source: nil)?.location,
                                                      gesturesBegun: gesturesBegun.get()))
}

/// Where a right click without a stroke goes back: the release point, so the cursor does
/// not jump — unless the pointer has drifted off the window pressed, which gets it then.
func clickPoint(_ g: Gesture, release p: CGPoint, _ s: State) -> CGPoint {
    s.windows.first(where: { $0.bounds.contains(p) })?.id == g.hit.windowID ? p : g.start
}

#if SELFTEST
var repostedClicks: [CGPoint] = []            // what would have been handed back
var performedActions: [GestureAction] = []    // what would have run
var performedEnds: [GestureEnd] = []          // …and where its gesture ended
#endif

/// The browser gets its right click back; its context menu opens then. Tagged so the tap
/// lets it through.
func repostRightClick(at p: CGPoint, flags: CGEventFlags) {
    #if SELFTEST
    repostedClicks.append(p)   // self-tests never post a real click
    #else
    let source = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.rightMouseDown, .rightMouseUp] {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p,
                              mouseButton: .right) else { continue }
        e.flags = flags
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        e.setIntegerValueField(.eventSourceUserData, value: gestureTag)
        e.post(tap: .cghidEventTap)
    }
    #endif
}

// MARK: - Running an action

final class GestureActions {
    private let queue = DispatchQueue(label: "MousePilot.gestures", qos: .userInitiated)
    private var restoreFrames: [CGWindowID: CGRect] = [:]   // queue only: frames before "maximize"
    private let prompts = Locked(0)   // Automation prompts answered so far

    func perform(_ action: GestureAction, _ g: Gesture, end: GestureEnd) {
        #if SELFTEST
        performedActions.append(action)   // self-tests never act on a real window
        performedEnds.append(end)
        #else
        let queued = prompts.get(), made = uptime()
        queue.async {
            // Gestures made while a permission prompt was up are dropped, like scrolls are.
            guard self.prompts.get() == queued else {
                if debug { log("gesture: \(action.rawValue) made during the permission prompt; dropped") }
                return
            }
            self.run(action, g, end: end, made: made)
        }
        #endif
    }

    private func run(_ action: GestureAction, _ g: Gesture, end: GestureEnd, made: TimeInterval) {
        switch action {
        case .none:
            return
        case .maximize:
            _ = bringForward(g.hit)   // like every action; before the resize, which the frame match uses
            toggleMaximize(g.hit)
            return
        case .incognito where g.browser.kind == .chromium:
            if openIncognito(g) { return }
        default:
            break
        }
        guard let chord = keyChord(action, bundleID: g.browser.bundleID) else { return }
        // Shortcuts go to the app's focused window: make the gesture's window that one first
        // (the cached focus may be a moment old, so ask Accessibility).
        if !bringForward(g.hit) {
            log("gesture: could not bring \(g.browser.bundleID) window \(g.hit.windowID) forward; \(action.rawValue) skipped")
            return
        }
        if let delta = wheelDelta(action, windowHeight: g.hit.window.height),
           scrollPage(g.hit, by: delta, end: end) { return }
        // Through the browser's menu when it has the command: a page cannot take a menu
        // command the way it takes a shortcut (⌘[ is "decrease indent" in an editor).
        if !goesAsKeys(chord, kind: g.browser.kind), pressMenuItem(g.hit, chord: chord, made: made) { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: chord.key, keyDown: down) else { continue }
            e.flags = chord.flags
            e.postToPid(g.hit.pid)
        }
        menuChangedAt[g.hit.pid] = uptime()
    }

    /// One wheel event at the pointer, when it is over the page of the gesture's window —
    /// looked at afresh, as the pointer may have moved on — and where the pointer is is known
    /// (see wheelPoint); false otherwise, and the keys go. WindowServer moves the pointer to a
    /// posted scroll event's location, so that must be where the pointer really is, read just
    /// before posting.
    private func scrollPage(_ hit: Hit, by delta: Int32, end: GestureEnd) -> Bool {
        guard onPage(end.pointer, window: hit.window) else { return false }
        refreshWindows()   // ~2 ms: before the pointer is read
        guard let p = wheelPoint(session: CGEvent(source: nil)?.location, end: end,
                                 gesturesBegun: gesturesBegun.get(), buttonHeld: mouseButtonHeld()),
              onPage(p, window: hit.window), gestureTarget(p, state.get())?.windowID == hit.windowID,
              let e = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .pixel,
                              wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { return false }
        e.location = p
        e.setIntegerValueField(.eventSourceUserData, value: gestureTag)   // no tab switch (handleScroll)
        e.post(tap: .cgSessionEventTap)
        return true
    }

    private struct MenuKey: Hashable { let pid: pid_t, character: String, modifiers: Int }
    // Queue only: the menu items found, by shortcut, with the menu bar they were found in
    // (Firefox has one per window); shortcuts no menu had, and when; and per app, when its
    // menus were last read, last read up to date, and last acted on.
    private var menuItems: [MenuKey: (bar: AXUIElement, item: AXUIElement)] = [:]
    private var menuMisses: [MenuKey: TimeInterval] = [:]
    private var menuReadAt: [pid_t: TimeInterval] = [:]
    private var menuRefreshedAt: [pid_t: TimeInterval] = [:]
    private var menuChangedAt: [pid_t: TimeInterval] = [:]

    /// Presses the app's menu item with this shortcut — looked for among the items of its
    /// menus (one level down, as Back, Reload or Downloads are) and remembered. True when the
    /// item exists, pressed or disabled (Back with no history: nothing to do, and no
    /// shortcut for the page either), or when the action was dropped; false when there is
    /// none to press, or no answer.
    private func pressMenuItem(_ hit: Hit, chord: KeyChord, made: TimeInterval) -> Bool {
        let pid = hit.pid, app = AXUIElementCreateApplication(pid)
        guard let character = menuCharacter(chord.key), let modifiers = axMenuModifiers(chord.flags) else { return false }
        let key = MenuKey(pid: pid, character: character, modifiers: modifiers)
        forgetQuitApps()
        if let missed = menuMisses[key], uptime() - missed < menuMissRecheck { return false }
        let lastRead = menuReadAt[pid]
        defer { menuReadAt[pid] = uptime() }
        var waited = false
        for _ in 0..<3 {
            // A remembered item counts only while its menu bar is still the app's (Firefox
            // switches bars with the key window).
            if let found = menuItems[key] {
                var bar: CFTypeRef?
                let same = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success
                    && bar.map { CFEqual($0, found.bar) } == true
                if !same { menuItems[key] = nil }
            }
            let remembered = menuItems[key] != nil
            if !remembered {
                let found = findMenuItem(pid: pid, character, modifiers)
                menuItems[key] = found.item
                menuMisses[key] = found.item == nil && found.complete ? uptime() : nil   // a miss only if all answered
            }
            guard let item = menuItems[key]?.item else { return false }
            // An item's element stands for a position in its menu, and this read is what
            // brings the menu up to date: check the shortcut there now, not only when found.
            let readAt = uptime()
            let read = menuItemState(item)
            if read.error == .cannotComplete { return false }   // busy: the keys reach it once it is free
            guard read.error == .success, read.character?.uppercased() == character,
                  menuModifiersMatch(read.modifiers, modifiers) else {
                menuItems[key] = nil
                if remembered { continue }   // the menu changed since it was found: look again
                return false
            }
            if waited || staleMenuWait(since: lastRead, now: readAt) == 0 { menuRefreshedAt[pid] = readAt }
            if read.enabled == false {
                // Believed if the menus were read up to date after this gesture was made and
                // after MousePilot last acted on the app; otherwise read again once they refresh.
                if menuReadIsFresh(refreshedAt: menuRefreshedAt[pid], changedAt: menuChangedAt[pid], made: made) { return true }
                let wait = staleMenuWait(since: menuRefreshedAt[pid] ?? lastRead, now: uptime())
                guard wait > 0, !waited else { return true }   // disabled: nothing to do
                waited = true
                usleep(useconds_t(wait * 1_000_000))
                // The user may have moved to another window meanwhile: never act on that one.
                guard isFocused(app, hit) else {
                    log("gesture: focus moved while waiting for the browser's menus; ⌘\(character) dropped")
                    return true
                }
                continue   // and read it again
            }
            let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
            if result == .cannotComplete, debug { log("gesture: menu ⌘\(character) answered late; counted as pressed") }
            switch menuPressOutcome(result, remembered: remembered) {
            case .done:
                menuChangedAt[pid] = uptime()
                return true
            case .lookAgain: menuItems[key] = nil
            case .useKeys: return false
            }
        }
        return false
    }

    /// An item's shortcut and whether it is enabled, in one request.
    private func menuItemState(_ item: AXUIElement) -> (error: AXError, character: String?, modifiers: Int?, enabled: Bool?) {
        let wanted = [kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXEnabledAttribute] as CFArray
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(item, wanted, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard let v = values as? [Any], v.count == 3 else { return (error, nil, nil, nil) }
        return (error, v[0] as? String, v[1] as? Int, v[2] as? Bool)
    }

    /// Forgets what was found in apps that have quit (a pid can come back as another app).
    private func forgetQuitApps() {
        let live = state.get().browsers
        guard menuItems.keys.contains(where: { live[$0.pid] == nil }) || menuMisses.keys.contains(where: { live[$0.pid] == nil })
        else { return }
        menuItems = menuItems.filter { live[$0.key.pid] != nil }
        menuMisses = menuMisses.filter { live[$0.key.pid] != nil }
        menuReadAt = menuReadAt.filter { live[$0.key] != nil }
        menuRefreshedAt = menuRefreshedAt.filter { live[$0.key] != nil }
        menuChangedAt = menuChangedAt.filter { live[$0.key] != nil }
    }

    /// The item with this shortcut and the menu bar it is in; `complete` is false when some
    /// menu did not answer, so a miss then is not remembered.
    private func findMenuItem(pid: pid_t, _ character: String, _ modifiers: Int)
        -> (item: (bar: AXUIElement, item: AXUIElement)?, complete: Bool) {
        var complete = true
        func children(_ e: AXUIElement, _ attribute: String = kAXChildrenAttribute) -> [AXUIElement] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success else {
                complete = false
                return []
            }
            if let list = value as? [AXUIElement] { return list }
            return value.map { [$0 as! AXUIElement] } ?? []
        }
        let wanted = [kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute] as CFArray
        for bar in children(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) {
            // File, Edit, View, History, … — not the Apple menu every app's bar starts with
            // (Sleep, Log Out…), which is no browser's command.
            for title in children(bar).dropFirst() {
                for menu in children(title) {
                    for item in children(menu) {
                        var values: CFArray?
                        guard AXUIElementCopyMultipleAttributeValues(item, wanted, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                                     &values) == .success else {
                            complete = false
                            continue
                        }
                        guard let v = values as? [Any], v.count == 2, (v[0] as? String)?.uppercased() == character,
                              menuModifiersMatch(v[1] as? Int, modifiers) else { continue }
                        return ((bar, item), true)
                    }
                }
            }
        }
        return (nil, complete)
    }

    private func bringForward(_ hit: Hit) -> Bool {
        let app = AXUIElementCreateApplication(hit.pid)
        if isFocused(app, hit) { return true }
        guard let window = axWindow(hit) else { return false }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        for attempt in 0..<25 {   // up to 0.5 s
            if isFocused(app, hit) { return true }
            if attempt == 5 {   // Accessibility did not activate the app: ask AppKit too
                DispatchQueue.main.async { NSRunningApplication(processIdentifier: hit.pid)?.activate(options: []) }
            }
            usleep(20_000)
        }
        return false
    }

    private func isFocused(_ app: AXUIElement, _ hit: Hit) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFrontmostAttribute as CFString, &value) == .success,
              value as? Bool == true else { return false }
        value = nil
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value else { return false }
        let window = value as! AXUIElement
        if let id = axWindowID(window) { return id == hit.windowID }
        return axFrame(window).map { sameFrame($0, hit.window) } ?? false
    }

    private func axWindow(_ hit: Hit) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(hit.pid), kAXWindowsAttribute as CFString,
                                            &value) == .success, let windows = value as? [AXUIElement] else { return nil }
        return windows.first { axWindowID($0) == hit.windowID }
            ?? windows.first { axFrame($0).map { sameFrame($0, hit.window) } ?? false }
    }

    /// Fills the usable part of its display (without menu bar and Dock); again: back.
    private func toggleMaximize(_ hit: Hit) {
        guard let window = axWindow(hit), let frame = axFrame(window),
              let area = DispatchQueue.main.sync(execute: { usableArea(around: frame) }) else { return }
        if sameFrame(frame, area) {
            guard let old = restoreFrames.removeValue(forKey: hit.windowID) else { return }
            setFrame(window, old)
        } else {
            restoreFrames[hit.windowID] = frame
            setFrame(window, area)
        }
    }

    private func setFrame(_ window: AXUIElement, _ r: CGRect) {
        var origin = r.origin, size = r.size
        if let v = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v) }
        if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v) }
    }

    /// Chromium: the page itself in a new incognito window — the URL of the window's
    /// active tab, by Apple Events (the Automation permission used for background tabs).
    private func openIncognito(_ g: Gesture) -> Bool {
        guard switcher.permitted(pid: g.hit.pid, bundleID: g.browser.bundleID, asked: { self.prompts.update { $0 += 1 } })
        else { return false }
        let target = NSAppleEventDescriptor(processIdentifier: g.hit.pid)
        let app = AppleEvent.application
        let created: NSAppleEventDescriptor
        let url: String
        do {
            guard let index = try scriptingWindow(target, pid: g.hit.pid, bundleID: g.browser.bundleID,
                                                  window: g.hit.window, windowID: g.hit.windowID),
                  let page = try AppleEvent.get(AppleEvent.property("URL ", of: AppleEvent.property(
                      "acTa", of: AppleEvent.element("cwin", index, of: app))), from: target)?.stringValue,
                  !page.isEmpty else { return false }
            url = page
            let properties = NSAppleEventDescriptor.record()
            properties.setDescriptor(NSAppleEventDescriptor(string: "incognito"), forKeyword: AppleEvent.code("mode"))
            // A first incognito window can take a while; one that timed out still opens, so no
            // ⌘⇧N after it.
            do {
                created = try AppleEvent.send("core", "crel", to: target, [
                    "kocl": NSAppleEventDescriptor(typeCode: AppleEvent.code("cwin")), "prdt": properties,
                ], timeout: 10) ?? AppleEvent.element("cwin", 1, of: app)
            } catch let failure as AppleEvent.Failure where failure.code == -1712 {
                log("gesture: \(g.browser.bundleID) is slow to open the incognito window")
                return true
            }
        } catch {
            log("gesture: incognito window for \(g.browser.bundleID) failed: \(error)")
            return false
        }
        do {
            try AppleEvent.set(AppleEvent.property("URL ", of: AppleEvent.property("acTa", of: created)),
                               to: NSAppleEventDescriptor(string: url), in: target)
        } catch {
            log("gesture: could not open the page in the incognito window: \(error)")
        }
        return true
    }
}

let gestureActions = GestureActions()

/// The visible part (without menu bar and Dock) of the display holding the frame's centre,
/// in global coordinates. Main thread.
func usableArea(around frame: CGRect) -> CGRect? {
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    let center = CGPoint(x: frame.midX, y: top - frame.midY)
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else { return nil }
    let v = screen.visibleFrame
    return CGRect(x: v.minX, y: top - v.maxY, width: v.width, height: v.height)
}

// MARK: - Drawing the trail and the title

/// What the main thread draws; written by the event tap thread.
struct GestureDrawing {
    var generation = 0
    var points: [CGPoint] = []   // the trail, in global coordinates (y down)
    var arrows = ""
    var title: String?
    var window = CGRect.zero     // the browser window: the title goes in its middle
    var stroke = true
    var showTitle = true
    var visible = false
    var scheduled = false
}

let gestureDrawing = Locked(GestureDrawing())

func beginDrawing(at p: CGPoint, window: CGRect, stroke: Bool, title: Bool) {
    gestureDrawing.update { d in
        d.generation += 1
        d.points = [p]
        d.arrows = ""
        d.title = nil
        d.window = window
        d.stroke = stroke
        d.showTitle = title
        d.visible = false
    }
}

/// Adds a point (3 pt from the last); redraws when there is something new to show, at most
/// 60 times a second however fast the mouse reports.
func draw(_ g: Gesture, at p: CGPoint, changed: Bool) {
    let schedule = gestureDrawing.update { d -> Bool in
        var added = false
        if let last = d.points.last, hypot(p.x - last.x, p.y - last.y) >= 3, d.points.count < 8000 {
            d.points.append(p)
            added = true
        }
        guard g.tracker.started, d.stroke || d.showTitle, changed || !d.visible || (added && d.stroke) else { return false }
        if changed || !d.visible {
            d.arrows = g.tracker.arrows
            d.title = g.tracker.code.map { (g.map[$0] ?? GestureAction.none).title }
        }
        d.visible = true
        if d.scheduled { return false }
        d.scheduled = true
        return true
    }
    if schedule { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { gestureOverlay.render() } }
}

func endDrawing() {
    let schedule = gestureDrawing.update { d -> Bool in
        let shown = d.visible
        d.visible = false
        d.points = []
        guard shown, !d.scheduled else { return false }
        d.scheduled = true
        return true
    }
    if schedule { DispatchQueue.main.async { gestureOverlay.render() } }
}

/// The trail panel's frame grown to cover `needed`, with room to spare on the sides that
/// grew, so a gesture resizes it only a few times (and never far beyond its strokes).
func grownTrail(_ frame: CGRect, toCover needed: CGRect) -> CGRect {
    frame.union(needed.insetBy(dx: -160, dy: -160)).integral
}

final class GestureOverlay {
    static let green = CGColor(red: 0, green: 0xDC / 255.0, blue: 0x9B / 255.0, alpha: 0.9)   // Whale's green

    private var trail: NSPanel?
    private var hud: NSPanel?
    // The trail is two layers: the points drawn a while ago, redrawn only every 48 points,
    // and the latest ones, redrawn every frame — so a frame costs the same however long the
    // trail has grown.
    private let settled = CAShapeLayer(), recent = CAShapeLayer()
    private var points: [CGPoint] = []      // this gesture's trail (global coordinates)
    private var settledCount = 0            // points[..<settledCount] are in `settled`
    private var trailFrame = CGRect.null    // global coordinates
    private var generation = -1
    private let arrowsLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private var shown = (arrows: "", title: "", window: CGRect.null)   // what the title panel shows
    private(set) var redraws = 0   // for scripts/check.sh

    /// Main thread.
    func render() {
        redraws += 1
        let (d, fresh) = gestureDrawing.update { d -> (GestureDrawing, [CGPoint]) in
            d.scheduled = false
            let from = d.generation == generation ? min(points.count, d.points.count) : 0
            var copy = d
            copy.points = []
            return (copy, Array(d.points[from...]))
        }
        guard d.visible else {
            hide()
            return
        }
        if d.generation != generation {
            generation = d.generation
            points = []
            settledCount = 0
            trailFrame = .null
        }
        points += fresh
        if d.stroke, !fresh.isEmpty { extendTrail(fresh) }
        if d.showTitle, let title = d.title {
            showTitle(d.arrows, title, in: d.window)
        } else if let hud, hud.isVisible {
            hud.orderOut(nil)
        }
    }

    private func extendTrail(_ fresh: [CGPoint]) {
        let panel = trail ?? makeTrail()
        let margin = settled.lineWidth * 2
        let needed = fresh.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -margin, dy: -margin)
        var moved = false
        if trailFrame.isNull || !trailFrame.contains(needed) {
            // Grow in steps so the panel is resized only a few times per gesture.
            trailFrame = grownTrail(trailFrame, toCover: needed)
            panel.setFrame(cocoaRect(trailFrame), display: false)
            for layer in [settled, recent] {
                layer.frame = CGRect(origin: .zero, size: trailFrame.size)
                layer.contentsScale = panel.backingScaleFactor
            }
            moved = true   // panel coordinates changed
        }
        if points.count - settledCount > 48 { settledCount = points.count - 1 }   // the latest point starts `recent`
        if moved || settled.path == nil || settledCount != settledPoints {
            settled.path = polyline(points[..<settledCount])
            settledPoints = settledCount
        }
        recent.path = polyline(points[max(settledCount - 1, 0)...])
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private var settledPoints = -1   // how many points `settled` was drawn with

    /// Points in global coordinates as a path in the trail panel's (y up).
    private func polyline(_ p: ArraySlice<CGPoint>) -> CGPath? {
        guard p.count >= 2 else { return nil }
        let path = CGMutablePath()
        path.addLines(between: p.map { CGPoint(x: $0.x - trailFrame.minX, y: trailFrame.maxY - $0.y) })
        return path
    }

    private func showTitle(_ arrows: String, _ title: String, in window: CGRect) {
        let panel = hud ?? makeHUD()
        guard !panel.isVisible || shown != (arrows, title, window) else { return }   // changes once or twice a gesture
        shown = (arrows, title, window)
        arrowsLabel.stringValue = arrows
        titleLabel.stringValue = title
        arrowsLabel.sizeToFit()
        titleLabel.sizeToFit()
        let width = max(arrowsLabel.frame.width, titleLabel.frame.width, 120) + 48, height: CGFloat = 96
        panel.setFrame(cocoaRect(CGRect(x: window.midX - width / 2, y: window.midY - height / 2,
                                        width: width, height: height)), display: false)
        arrowsLabel.setFrameOrigin(NSPoint(x: (width - arrowsLabel.frame.width) / 2, y: 46))
        titleLabel.setFrameOrigin(NSPoint(x: (width - titleLabel.frame.width) / 2, y: 16))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Hides both panels; the trail's shrinks to a point so its backing store goes too.
    private func hide() {
        settled.path = nil
        recent.path = nil
        points = []
        settledCount = 0
        settledPoints = -1
        trailFrame = .null
        if let trail, trail.isVisible {
            trail.orderOut(nil)
            trail.setFrame(NSRect(x: 0, y: 0, width: 1, height: 1), display: false)
        }
        if let hud, hud.isVisible { hud.orderOut(nil) }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlayWindowIDs.update { $0.insert(CGWindowID(panel.windowNumber)) }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView?.wantsLayer = true
        return panel
    }

    private func makeTrail() -> NSPanel {
        let panel = makePanel()
        for layer in [settled, recent] {
            layer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "contentsScale": NSNull()]   // no animations
            layer.strokeColor = Self.green
            layer.fillColor = nil
            layer.lineWidth = 4
            layer.lineCap = .round
            layer.lineJoin = .round
            panel.contentView?.layer?.addSublayer(layer)
        }
        trail = panel
        return panel
    }

    private func makeHUD() -> NSPanel {
        let panel = makePanel()
        panel.contentView?.layer?.backgroundColor = CGColor(gray: 0, alpha: 0.72)
        panel.contentView?.layer?.cornerRadius = 14
        arrowsLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        arrowsLabel.textColor = NSColor(cgColor: Self.green)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white
        panel.contentView?.addSubview(arrowsLabel)
        panel.contentView?.addSubview(titleLabel)
        hud = panel
        return panel
    }

    /// Global coordinates (origin top left of the main display, y down) to AppKit's.
    private func cocoaRect(_ r: CGRect) -> NSRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
    }
}

let gestureOverlay = GestureOverlay()
/// The trail and title panels: click-through, so the window cache leaves them out.
let overlayWindowIDs = Locked<Set<CGWindowID>>([])

// MARK: - Settings window

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// "마우스 제스처 설정": the switches, then every gesture's shape beside a pop-up of the
/// actions (written to the gestures file). It exists only while it is open.
final class GestureSettings: NSObject, NSWindowDelegate {
    private static var current: GestureSettings?   // main thread
    private let window: NSWindow
    private var switches: [NSButton] = []
    private var popups: [NSPopUpButton] = []

    static func show() {
        let settings = current ?? GestureSettings()
        current = settings
        settings.update()
        NSApp.activate(ignoringOtherApps: true)
        settings.window.makeKeyAndOrderFront(nil)
    }

    /// Shows a change made elsewhere (the menu, the file) if the window is open.
    static func refresh() {
        DispatchQueue.main.async { current?.update() }
    }

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "마우스 제스처 설정"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = makeContent()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        window.contentView = scroll
        content.layoutSubtreeIfNeeded()
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        window.setContentSize(NSSize(width: 480, height: min(content.fittingSize.height, visible - 80)))
        window.contentMinSize = NSSize(width: 420, height: 240)
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        GestureSettings.current = nil   // frees the window and its views
        // Back to the app that was in front (the browser): MousePilot has no window left, and
        // scrolls over the focused browser window would count it as a background one.
        if NSApp.isActive, let app = NSRunningApplication(processIdentifier: lastOtherFrontPID), !app.isTerminated {
            app.activate(options: [])
        }
    }

    /// Back from the editor (the file saved in place, which the folder watch does not see).
    func windowDidBecomeKey(_ notification: Notification) {
        update()
    }

    private func makeContent() -> NSView {
        switches = ["마우스 제스처 사용", "제스처 선 그리기", "제스처 타이틀 보기"].enumerated().map { i, title in
            let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggle(_:)))
            box.tag = i
            return box
        }
        let note = NSTextField(wrappingLabelWithString: "브라우저 창 위에서 오른쪽 버튼을 누른 채 아래 모양으로 긋고 놓으면 동작이 실행됩니다. "
            + "긋지 않고 오른쪽 클릭만 하면 원래 메뉴가 뜹니다. 자체 마우스 제스처가 있는 브라우저(Vivaldi, Opera 등)에는 적용되지 않습니다.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 420

        func header(_ title: String) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabelColor
            return label
        }
        let green = NSColor(cgColor: GestureOverlay.green) ?? .systemGreen
        var rows: [[NSView]] = [[header("제스처"), header("동작")]]
        popups = gestureCodes.enumerated().map { i, _ in
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: GestureAction.allCases.map(\.title))
            popup.tag = i
            popup.target = self
            popup.action = #selector(choose(_:))
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
            return popup
        }
        for (i, code) in gestureCodes.enumerated() {
            let icon = NSImageView(image: gestureImage(code, size: 30, color: green))
            rows.append([icon, popups[i]])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 40
        grid.rowAlignment = .none
        for r in 0..<grid.numberOfRows { grid.row(at: r).yPlacement = .center }
        grid.column(at: 0).xPlacement = .center
        grid.row(at: 0).bottomPadding = 4

        let file = NSButton(title: "설정 파일 열기…", target: self, action: #selector(openFile))
        file.bezelStyle = .rounded
        let stack = NSStackView(views: switches + [note, grid, file])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: switches[2])
        stack.setCustomSpacing(20, after: note)
        stack.setCustomSpacing(20, after: grid)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 28, bottom: 20, right: 28)
        let content = FlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return content
    }

    private func update() {
        let s = state.get()
        for (box, on) in zip(switches, [s.gestures, s.gestureStroke, s.gestureTitle]) { box.state = on ? .on : .off }
        let map = gestureMap()
        for (popup, code) in zip(popups, gestureCodes) {
            popup.selectItem(at: GestureAction.allCases.firstIndex(of: map[code] ?? GestureAction.none) ?? 0)
        }
    }

    @objc private func toggle(_ sender: NSButton) {
        guard let setting = GestureSetting(rawValue: sender.tag) else { return }
        setGestureSetting(setting, sender.state == .on)
    }

    @objc private func choose(_ sender: NSPopUpButton) {
        setGesture(gestureCodes[sender.tag], GestureAction.allCases[sender.indexOfSelectedItem])
        update()   // what the gestures use: the old choice again if the file could not be written
    }

    @objc private func openFile() {
        ensureGestureFile()
        openInTextEditor(gesturePath)
    }
}

// MARK: - Measuring (scripts/check.sh)

var gestureDemoSource: DispatchSourceSignal?

/// For scripts/check.sh only (the debuggable copy runs with -gestureDemo YES). Each SIGUSR1
/// runs three scripted gestures through the event tap's own handler, on the tap thread,
/// with synthetic events: the cursor stays where it is and nothing reaches another app.
/// They start over a browser window and turn three times, so no action runs and no click
/// is handed back. Logs "gesture demo done" with the CPU per event on the tap thread and
/// the main thread's CPU time meanwhile (drawing).
func installGestureDemo() {
    signal(SIGUSR1, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    source.setEventHandler { Thread.detachNewThread(runGestureDemo) }
    source.resume()
    gestureDemoSource = source
}

/// The main thread's CPU time so far (all of it: the redraws, Core Animation's commits after
/// them, the run loop) and the overlay's redraws.
func mainThreadCPU() -> (ns: UInt64, redraws: Int) {
    DispatchQueue.main.sync { (clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), gestureOverlay.redraws) }
}

/// While the demo runs, the tap leaves real right-button events alone, so a real click can
/// never join the demo's strokes (event tap thread only).
var gestureDemoRunning = false

/// Runs `work` on the event tap thread and waits for it (directly without one).
private func onTapThread(_ work: @escaping () -> Void) {
    guard let loop = tapRunLoop else { return work() }
    let done = DispatchSemaphore(value: 0)
    CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { work(); done.signal() }
    CFRunLoopWakeUp(loop)
    done.wait()
}

/// Down, right, up — a third stroke, so nothing runs — then on around a square.
private let demoStrokes: [(CGFloat, CGFloat, Int)] = [(0, 1, 40), (1, 0, 40), (0, -1, 40), (1, 0, 200), (0, 1, 200), (-1, 0, 140)]

private func runGestureDemo() {
    // Only between real gestures; real right-button events pass through until it is done.
    var started = false
    for _ in 0..<500 where !started {
        onTapThread { if activeGesture == nil { gestureDemoRunning = true; started = true } }
        if !started { usleep(10_000) }
    }
    guard started else { return log("gesture demo skipped: a real gesture did not end") }
    defer { onTapThread { gestureDemoRunning = false } }
    refreshWindows()   // the windows as they are now, not as cached
    let s = state.get()
    let start = s.windows.lazy.filter { $0.layer == 0 && s.browsers[$0.pid] != nil }
        .map { CGPoint(x: $0.bounds.midX - 100, y: $0.bounds.midY - 100) }
        .first { gestureTarget($0, s) != nil }
    /// One synthetic event through the tap's handler on the tap thread: its CPU time (ns),
    /// and whether the handler took it.
    func handle(_ type: CGEventType, _ p: CGPoint) -> (ns: UInt64, taken: Bool) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p,
                                  mouseButton: .right) else { return (0, false) }
        var result: (ns: UInt64, taken: Bool) = (0, false)
        onTapThread {
            let t0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let taken = handleRightMouse(type, event)
            result = (clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - t0, taken)
        }
        return result
    }
    let before = mainThreadCPU()
    var press: UInt64 = 0, drag: UInt64 = 0, drags = 0, timed = start != nil
    for _ in 0..<3 {
        var p = start ?? .zero
        if timed {
            let down = handle(.rightMouseDown, p)
            press += down.ns
            timed = down.taken
        }
        if !timed {
            // No browser window in front takes gestures (or it went away): draw the same
            // strokes directly, so the drawing and its memory are still measured.
            guard let display = NSScreen.screens.first?.frame else { return }
            let window = CGRect(x: display.midX - 400, y: display.midY - 300, width: 800, height: 600)
            p = CGPoint(x: window.midX - 100, y: window.midY - 100)
            beginDrawing(at: p, window: window, stroke: s.gestureStroke, title: s.gestureTitle)
            var g = Gesture(tracker: GestureTracker(at: p), hit: Hit(pid: 0, window: window, windowID: 0, frontmostOwn: true),
                            browser: Browser(bundleID: "demo", band: Band(top: 0, bottom: 40), kind: .none), focused: true,
                            map: whaleGestures, flags: [], start: p, press: 0)
            for (dx, dy, n) in demoStrokes {
                for _ in 0..<n {
                    p = CGPoint(x: p.x + dx, y: p.y + dy)
                    let changed = g.tracker.move(to: p)
                    draw(g, at: p, changed: changed)
                    usleep(1000)
                }
            }
            endDrawing()
        } else {
            for (dx, dy, n) in demoStrokes {
                for _ in 0..<n {
                    p = CGPoint(x: p.x + dx, y: p.y + dy)
                    drag += handle(.rightMouseDragged, p).ns
                    drags += 1
                    usleep(1000)   // a 1000 Hz mouse
                }
            }
            _ = handle(.rightMouseUp, p)
        }
        usleep(300_000)
    }
    let after = mainThreadCPU()
    log("gesture demo done: drawing took \((after.ns - before.ns) / 1_000_000) ms in \(after.redraws - before.redraws) redraws; "
        + (timed && drags > 0
           ? String(format: "%d drag events took %.1f us each, a right-button press %.0f us", drags,
                    Double(drag) / Double(drags) / 1000, Double(press) / 3 / 1000)
           : "no browser window in front to start a gesture over, so no event timing"))
}
