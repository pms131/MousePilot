// Self-tests for the pure parts of MousePilot: tab-strip hit testing on synthetic window
// layouts, routing, config parsing, scroll steps, tab arithmetic, Apple Event values, and
// mouse gestures (strokes, Whale's defaults, the gestures file, shortcuts, target windows).
// Built only by scripts/check.sh (swiftc -D SELFTEST Sources/MousePilot/*.swift SelfTests.swift);
// the shipped app does not contain them.
import AppKit
import CoreGraphics

private var failures = 0
private var passed = 0

private func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        passed += 1
    } else {
        failures += 1
        print("FAIL  \(name)" + { let d = detail(); return d.isEmpty ? "" : " — \(d)" }())
    }
}

private let brave: pid_t = 100, safari: pid_t = 200, firefox: pid_t = 300, other: pid_t = 900
private let display1 = CGRect(x: 0, y: 0, width: 2560, height: 1440)
private let display2 = CGRect(x: 2560, y: 0, width: 2560, height: 1440)

private func w(_ id: CGWindowID, _ pid: pid_t, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
               layer: Int = 0) -> WindowInfo {
    WindowInfo(id: id, pid: pid, layer: layer, bounds: CGRect(x: x, y: y, width: width, height: height))
}

/// A state with Brave (Chromium), Safari and Firefox running; `windows` front to back.
private func layout(_ windows: [WindowInfo], standard: [pid_t: Set<CGWindowID>]? = nil) -> State {
    var s = State()
    s.paused = false
    s.browsers = [
        brave: Browser(bundleID: "com.brave.Browser", band: Band(top: 0, bottom: 40), kind: .chromium),
        safari: Browser(bundleID: "com.apple.Safari", band: Band(top: 50, bottom: 88), kind: .safari),
        firefox: Browser(bundleID: "org.mozilla.firefox", band: Band(top: 0, bottom: 40), kind: .none),
    ]
    s.windows = windows
    s.displays = [display1, display2]
    if let standard {
        s.standard = standard.mapValues { StandardWindows(ids: $0, frames: []) }
    }
    return s
}

private func hits(_ s: State, _ x: CGFloat, _ y: CGFloat) -> Hit? { hitTest(CGPoint(x: x, y: y), s) }

private func testHitTest() {
    // Windowed Brave.
    var s = layout([w(1, brave, 100, 100, 1200, 800)], standard: [brave: [1]])
    check(hits(s, 300, 120)?.windowID == 1, "windowed: tab strip hits")
    check(hits(s, 300, 145) == nil, "windowed: below the band misses")
    check(hits(s, 300, 500) == nil, "windowed: page misses")
    check(hits(s, 1400, 120) == nil, "windowed: outside the window misses")

    // Another app's window over the strip.
    s = layout([w(9, other, 200, 90, 400, 300), w(1, brave, 100, 100, 1200, 800)], standard: [brave: [1]])
    check(hits(s, 300, 120) == nil, "covered strip misses")
    check(hits(s, 700, 120)?.windowID == 1, "uncovered part of the strip hits")

    // A menu (layer > 0) over the strip.
    s = layout([w(8, other, 250, 110, 200, 300, layer: 101), w(1, brave, 100, 100, 1200, 800)], standard: [brave: [1]])
    check(hits(s, 300, 120) == nil, "menu over the strip misses")

    // Full screen with the toolbar shown (as measured on Brave).
    let fullScreen = [w(11, brave, 0, 0, 2560, 40), w(12, brave, 0, 40, 2560, 74), w(13, brave, 0, 0, 2560, 150),
                      w(14, brave, 4, 1414, 771, 22), w(15, brave, 0, 114, 2560, 1326)]
    s = layout(fullScreen, standard: [brave: [15]])
    let fs = hits(s, 500, 20)
    check(fs?.windowID == 15 && fs?.window == CGRect(x: 0, y: 114, width: 2560, height: 1326),
          "full screen: strip window hits as the browser window", "\(String(describing: fs))")
    check(hits(s, 500, 60) == nil, "full screen: toolbar misses")
    check(hits(s, 500, 130) == nil, "full screen: top of the page misses")
    check(hits(s, 500, 700) == nil, "full screen: page misses")
    s = layout(fullScreen)   // Accessibility not answered yet: geometry
    check(hits(s, 500, 20)?.windowID == 15, "full screen without the standard list: strip hits")
    check(hits(s, 500, 130) == nil, "full screen without the standard list: page top misses")

    // Menu bar revealed: the strip slides down below it.
    s = layout([w(30, other, 0, 0, 2560, 37, layer: 24), w(11, brave, 0, 37, 2560, 40), w(12, brave, 0, 77, 2560, 74),
                w(15, brave, 0, 114, 2560, 1326)], standard: [brave: [15]])
    check(hits(s, 500, 20) == nil, "revealed menu bar itself misses")
    check(hits(s, 500, 50)?.windowID == 15, "strip below the revealed menu bar hits")

    // Safari full screen: toolbar and tab bar in one 90 pt window over a display-sized window.
    let safariFull = [w(41, safari, 631, 88, 280, 36), w(42, safari, 0, 0, 2560, 90), w(43, safari, 0, 0, 2560, 1440)]
    s = layout(safariFull, standard: [safari: [43]])
    let sf = hits(s, 1000, 60)
    check(sf?.windowID == 43 && sf?.window == display1, "Safari full screen: tab bar hits", "\(String(describing: sf))")
    check(hits(s, 1000, 20) == nil, "Safari full screen: toolbar misses")
    check(hits(s, 1000, 300) == nil, "Safari full screen: page misses")
    check(hits(s, 700, 100) == nil, "Safari full screen: tab preview misses")
    s = layout([w(30, other, 0, 0, 2560, 30, layer: 24), w(42, safari, 0, 30, 2560, 90), w(43, safari, 0, 0, 2560, 1440)],
               standard: [safari: [43]])
    check(hits(s, 1000, 107)?.windowID == 43, "Safari full screen, menu bar revealed: tab bar hits")
    check(hits(s, 1000, 60) == nil, "Safari full screen, menu bar revealed: toolbar misses")

    // Whale full screen: tab strip and toolbar in one 72 pt window.
    s = layout([w(51, brave, 1096, 44, 368, 46, layer: 999), w(52, brave, 0, 0, 2560, 72), w(53, brave, 0, 0, 2560, 1440)],
               standard: [brave: [53]])
    check(hits(s, 900, 24)?.windowID == 53, "Whale-style full screen: tab strip hits")
    check(hits(s, 900, 55) == nil, "Whale-style full screen: toolbar misses")
    check(hits(s, 1200, 60) == nil, "Whale-style full screen: tooltip misses")

    // Full screen with the toolbar hidden: page covers the display.
    s = layout([w(11, brave, 0, -63, 2560, 40), w(12, brave, 0, -98, 2560, 75), w(16, brave, 0, 0, 2560, 143),
                w(17, brave, 0, 0, 2560, 1440)], standard: [brave: [17]])
    check(hits(s, 500, 20) == nil, "toolbar-hidden full screen: top of the page misses")
    s = layout([w(17, brave, 0, 0, 2560, 1440)], standard: [brave: [17]])
    check(hits(s, 500, 20) == nil, "window covering its display (video full screen) misses")

    // Split View: two Brave tiles.
    s = layout([w(21, brave, 0, 0, 1279, 40), w(22, brave, 1281, 0, 1279, 40),
                w(23, brave, 0, 114, 1279, 1326), w(24, brave, 1281, 114, 1279, 1326)], standard: [brave: [23, 24]])
    check(hits(s, 300, 20)?.windowID == 23, "Split View: left strip hits the left tile")
    check(hits(s, 1500, 20)?.windowID == 24, "Split View: right strip hits the right tile")
    check(hits(s, 300, 130) == nil, "Split View: top of the page misses")

    // A small window in front of a big one of the same browser.
    s = layout([w(2, brave, 300, 200, 1200, 800), w(1, brave, 0, 25, 2560, 1415)], standard: [brave: [1, 2]])
    check(hits(s, 400, 220)?.windowID == 2, "small window in front: its strip hits")
    check(hits(s, 100, 40)?.windowID == 1, "big window behind: its visible strip hits")

    // A popup (extension, bubble, omnibox dropdown) inside the window.
    s = layout([w(5, brave, 900, 140, 380, 600), w(1, brave, 100, 100, 1200, 800)], standard: [brave: [1]])
    check(hits(s, 950, 150) == nil, "popup over the window misses")
    s = layout([w(5, brave, 900, 140, 380, 600), w(1, brave, 100, 100, 1200, 800)])
    check(hits(s, 950, 150) == nil, "popup misses without the standard list too")

    // A window reaching onto the second display (separate Spaces: shown where its center is).
    s = layout([w(1, brave, 2400, 100, 800, 600)], standard: [brave: [1]])
    check(hits(s, 2450, 120) == nil, "part on the other display misses")
    check(hits(s, 2700, 120)?.windowID == 1, "part on its own display hits")

    // Safari: tab bar below the toolbar.
    s = layout([w(40, safari, 647, 70, 1324, 868)], standard: [safari: [40]])
    check(hits(s, 900, 130)?.windowID == 40, "Safari: tab bar hits")
    check(hits(s, 900, 90) == nil, "Safari: toolbar misses")

    // Not a browser.
    s = layout([w(9, other, 100, 100, 1200, 800)])
    check(hits(s, 300, 120) == nil, "other app misses")
}

private func testRouting() {
    let hit = Hit(pid: brave, window: CGRect(x: 100, y: 100, width: 1200, height: 800), windowID: 1, frontmostOwn: true)
    let chromium = Browser(bundleID: "com.brave.Browser", band: Band(top: 0, bottom: 40), kind: .chromium)
    let plain = Browser(bundleID: "org.mozilla.firefox", band: Band(top: 0, bottom: 40), kind: .none)
    var s = layout([])
    s.frontPID = brave
    s.focused[brave] = FocusedWindow(frame: hit.window, id: 1)
    s.wrap = true
    check(route(hit, chromium, s) == .keys, "focused window, wrapping: keys")
    s.wrap = false
    check(route(hit, chromium, s) == .appleEvents, "focused window, not wrapping: Apple Events")
    check(route(hit, plain, s) == .keys, "focused window without scripting: keys")
    s.permission["com.brave.Browser"] = .denied
    check(route(hit, chromium, s) == .keys, "focused window, Automation denied: keys")
    s.permission = [:]
    s.focused[brave] = FocusedWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 10), id: 7)
    check(route(hit, chromium, s) == .appleEvents, "other window of the frontmost browser: Apple Events")
    s.frontPID = other
    check(route(hit, chromium, s) == .appleEvents, "background browser: Apple Events")
    check(route(hit, plain, s) == .pass, "background browser without scripting: pass")
    s.permission["com.brave.Browser"] = .denied
    check(route(hit, chromium, s) == .passAndRecheck, "background, Automation denied: pass and recheck")
}

private func testConfig() {
    var c = parseConfig("com.brave.Browser\r\ncom.naver.Whale 36\r\n")
    check(c["com.brave.browser"] == Band(top: 0, bottom: 40), "CRLF: default band", "\(c)")
    check(c["com.naver.whale"] == Band(top: 0, bottom: 36), "one number is the height", "\(c)")
    c = parseConfig("\u{FEFF}# comment\nCOM.GOOGLE.CHROME\t4 44 # tab-separated\n\n")
    check(c["com.google.chrome"] == Band(top: 4, bottom: 44), "BOM, tabs, comments, case", "\(c)")
    check(c.count == 1, "comments and blank lines are not browsers", "\(c)")
    c = parseConfig("com.apple.Safari 88 50\ncom.vivaldi.Vivaldi -3")
    check(c["com.apple.safari"] == Band(top: 0, bottom: 40), "end before start falls back to default", "\(c)")
    check(c["com.vivaldi.vivaldi"] == Band(top: 0, bottom: 40), "negative height falls back to default", "\(c)")
    let kept = linesRemoving("com.naver.whale", from: ["# header", "com.brave.Browser", "COM.NAVER.WHALE\t30", "", ""])
    check(kept == ["# header", "com.brave.Browser"], "removing a browser keeps the other lines", "\(kept)")
    check(configLines("a\r\nb\nc") == ["a", "b", "c"], "CRLF and LF lines")
}

/// Config files kept as symlinks (dotfiles): writes go to the target and keep the link,
/// edits to the target are noticed, and a dangling link gets its target created.
private func testConfigLinks() {
    let fm = FileManager.default
    let dir = NSTemporaryDirectory() + "mousepilot-selftest-\(getpid())"
    try? fm.removeItem(atPath: dir)
    try? fm.createDirectory(atPath: dir + "/dotfiles", withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    let target = dir + "/dotfiles/gestures", link = dir + "/gestures", chain = dir + "/chain"
    try? "L  BACK\n".write(toFile: target, atomically: true, encoding: .utf8)
    try? fm.createSymbolicLink(atPath: link, withDestinationPath: "dotfiles/gestures")   // relative, as stow makes them
    try? fm.createSymbolicLink(atPath: chain, withDestinationPath: link)
    check(configTarget(link) == target && configTarget(chain) == target && configTarget(target) == target,
          "a config link is followed to its target (relative links and chains too)", configTarget(chain))
    let before = fileStamp(link)
    usleep(10_000)
    check(writeConfig("L  FORWARD\n", to: link), "writing through a link")
    let attributes = try? fm.attributesOfItem(atPath: link)
    check(attributes?[.type] as? FileAttributeType == .typeSymbolicLink, "the link stays a link")
    check((try? String(contentsOfFile: target, encoding: .utf8)) == "L  FORWARD\n", "the target gets the text")
    check(((try? fm.attributesOfItem(atPath: target))?[.posixPermissions] as? Int).map { $0 & 0o111 == 0 } == true,
          "the target is not made executable")
    check(before != nil && fileStamp(link) != before, "an edit to the target changes the link's stamp")
    let dangling = dir + "/browsers"
    try? fm.createSymbolicLink(atPath: dangling, withDestinationPath: dir + "/dotfiles/browsers")
    check(writeConfig("com.brave.Browser\n", to: dangling)
          && (try? fm.attributesOfItem(atPath: dangling))?[.type] as? FileAttributeType == .typeSymbolicLink
          && fm.fileExists(atPath: dir + "/dotfiles/browsers"), "a dangling link gets its target created, not replaced")
    try? fm.createSymbolicLink(atPath: dir + "/nowhere", withDestinationPath: dir + "/missing-folder/x")
    check(!writeConfig("x\n", to: dir + "/nowhere"), "a target that cannot be written reports failure")
    // A linked config folder, and a ".." link to a file not there yet: ".." is taken through the
    // real folders (dotfiles/shared), not textually (home/shared).
    try? fm.createDirectory(atPath: dir + "/home/dotfiles/config/mousepilot", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: dir + "/home/dotfiles/shared", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: dir + "/home/shared", withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: dir + "/home/.config", withDestinationPath: "dotfiles/config")
    try? fm.createSymbolicLink(atPath: dir + "/home/dotfiles/config/mousepilot/browsers", withDestinationPath: "../../shared/browsers")
    check(writeConfig("com.brave.Browser\n", to: dir + "/home/.config/mousepilot/browsers")
          && fm.fileExists(atPath: dir + "/home/dotfiles/shared/browsers") && !fm.fileExists(atPath: dir + "/home/shared/browsers"),
          "a \"..\" link through a linked folder gets its target where the link points")
}

private func testWindowFilter() {
    let displays = [display1, display2]
    check(!keepWindow(layer: 21, alpha: 1, bounds: display1, displays: displays), "screen-sized overlay is ignored")
    check(keepWindow(layer: 101, alpha: 1, bounds: CGRect(x: 10, y: 10, width: 200, height: 300), displays: displays),
          "menu window is kept")
    check(!keepWindow(layer: 0, alpha: 0, bounds: display1, displays: displays), "transparent window is ignored")
    check(keepWindow(layer: 0, alpha: 1, bounds: display1, displays: displays), "full-screen app window is kept")
}

private func scroll(lines: Int32 = 0, horizontal: Int32 = 0, pixels: Int32? = nil, phase: Int64? = nil) -> CGEvent {
    let e: CGEvent
    if let pixels {
        e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0)!
    } else {
        e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: lines, wheel2: horizontal, wheel3: 0)!
    }
    if let phase { e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase) }
    return e
}

private func testScrollSteps() {
    check(scrollSteps(scroll(lines: -1)) == 1, "wheel down: next tab")
    check(scrollSteps(scroll(lines: 1)) == -1, "wheel up: previous tab")
    check(scrollSteps(scroll(lines: -3)) == 1, "a fast notch is still one tab")
    check(scrollSteps(scroll(horizontal: -1)) == 1, "wheel right: next tab")
    check(scrollSteps(scroll(horizontal: 1)) == -1, "wheel left: previous tab")
    // Continuous (trackpad): one tab per ~30 points, reset at a new gesture.
    _ = scrollSteps(scroll(pixels: 1, phase: 1))
    let a = scrollSteps(scroll(pixels: -12)), b = scrollSteps(scroll(pixels: -12)), c = scrollSteps(scroll(pixels: -12))
    check(a + b + c == 1, "trackpad: 36 points down = one tab", "\(a) \(b) \(c)")
    _ = scrollSteps(scroll(pixels: -20))
    let fresh = scrollSteps(scroll(pixels: -20, phase: 1))
    check(fresh == 0, "trackpad: a new gesture starts from zero", "\(fresh)")
}

private func testDirection() {
    check(scrollSteps(scroll(lines: -1), reverse: true) == -1, "reversed: wheel down = previous tab")
    check(scrollSteps(scroll(lines: 1), reverse: true) == 1, "reversed: wheel up = next tab")
}

private func testTabArithmetic() {
    check(nextTab(5, 1, 5, wrap: true) == 1, "wrap: last → first")
    check(nextTab(1, -1, 5, wrap: true) == 5, "wrap: first → last")
    check(nextTab(2, 7, 5, wrap: true) == 4, "wrap: several steps")
    check(nextTab(5, 1, 5, wrap: false) == 5, "no wrap: stays on the last tab")
    check(nextTab(1, -3, 5, wrap: false) == 1, "no wrap: stays on the first tab")
    check(nextTab(2, 2, 5, wrap: false) == 4, "no wrap: moves inside")
}

private func testAppleEventValues() {
    let list = NSAppleEventDescriptor.list()
    for (i, v) in [0, 114, 2560, 1440].enumerated() { list.insert(NSAppleEventDescriptor(int32: Int32(v)), at: i + 1) }
    check(AppleEvent.rect(list) == CGRect(x: 0, y: 114, width: 2560, height: 1326), "bounds as {l, t, r, b}")
    var quickDraw: [Int16] = [114, 0, 1440, 2560]   // top, left, bottom, right
    let qd = NSAppleEventDescriptor(descriptorType: AppleEvent.code("qdrt"), bytes: &quickDraw, length: 8)!
    check(AppleEvent.rect(qd) == CGRect(x: 0, y: 114, width: 2560, height: 1326), "bounds as a QuickDraw rectangle")
    let spec = AppleEvent.property("acTI", of: AppleEvent.element("cwin", 1, of: AppleEvent.application))
    check(spec.descriptorType == AppleEvent.code("obj "), "object specifier coerces to 'obj '")
    check(AppleEvent.items(NSAppleEventDescriptor.list()).isEmpty, "empty list has no items")
    check(sameFrame(CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 1, y: 2, width: 99, height: 101)),
          "frames within 2 pt match")
    check(!sameFrame(CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 3, y: 0, width: 100, height: 100)),
          "frames 3 pt apart differ")
}

/// Draws segments (dx, dy) from (500, 500) in steps of about 4 pt, optionally wobbling
/// `wobble` pt across the direction of travel.
private func drawn(_ segments: [(CGFloat, CGFloat)], wobble: CGFloat = 0) -> GestureTracker {
    var p = CGPoint(x: 500, y: 500)
    var t = GestureTracker(at: p)
    var i = 0
    for (dx, dy) in segments {
        let n = max(1, Int(max(abs(dx), abs(dy)) / 4))
        for _ in 0..<n {
            p.x += dx / CGFloat(n)
            p.y += dy / CGFloat(n)
            i += 1
            let w = i % 2 == 0 ? wobble : -wobble
            _ = t.move(to: CGPoint(x: p.x + (dx == 0 ? w : 0), y: p.y + (dy == 0 ? w : 0)))
        }
    }
    return t
}

private func testGestures() {
    check(!drawn([(12, 5)]).started, "a short wiggle stays a right click")
    check(drawn([(-40, 0)]).code == "L", "left stroke")
    check(drawn([(0, 60)]).code == "D", "down stroke (y grows downwards)")
    check(drawn([(0, -60), (60, 0)]).code == "UR", "up, then right")
    check(drawn([(-50, 0), (80, 0)]).code == "LR", "left and back right")
    check(drawn([(200, 0)], wobble: 8).code == "R", "wobble across a stroke does not count",
          drawn([(200, 0)], wobble: 8).code ?? "nil")
    check(drawn([(80, 0), (0, 12)]).code == "R", "a turn shorter than a stroke does not count")
    let three = drawn([(0, 60), (60, 0), (0, -60)])
    check(three.started && three.code == nil, "a third stroke voids the gesture", three.code ?? "nil")
    check(drawn([(0, 60), (60, 0)]).arrows == "↓ →", "arrows for the title")

    check(gestureCodes.count == 16 && gestureCodes.allSatisfy { whaleGestures[$0] != nil }, "Whale has a default for all 16")
    check(whaleGestures["L"] == .back && whaleGestures["R"] == .forward && whaleGestures["U"] == .top
          && whaleGestures["D"] == .bottom, "Whale: one stroke")
    check(whaleGestures["LR"] == .homepage && whaleGestures["RL"] == .homepage && whaleGestures["UD"] == .refresh
          && whaleGestures["DU"] == .refresh, "Whale: there and back")
    check(whaleGestures["UL"] == .newWindow && whaleGestures["UR"] == .newTab && whaleGestures["DL"] == .incognito
          && whaleGestures["DR"] == .closeTab && whaleGestures["LD"] == .reopenTab, "Whale: tabs and windows")
    check(whaleGestures["LU"] == .fullScreen && whaleGestures["RU"] == .maximize && whaleGestures["RD"] == .minimize,
          "Whale: window size")

    let m = parseGestures("dr none\nUL NEW_TAB # comment\nLL BACK\nXX BACK\nR bogus\nrl\n")
    check(m["DR"] == GestureAction.none, "config: NONE turns a gesture off")
    check(m["UL"] == .newTab, "config: any case, comments")
    check(m.count == 16 && m["R"] == .forward && m["RL"] == .homepage, "config: bad lines keep the defaults", "\(m)")
    check(parseGestures(defaultGestureText()) == whaleGestures, "the default gestures file is Whale's defaults")
    var lines = gestureLines(["# header", "L BACK", "DR CLOSE_TAB # mine", "dr NONE", ""], setting: "DR", to: .newTab)
    check(lines == ["# header", "L BACK", "DR  NEW_TAB", ""], "menu choice replaces the gesture's line", "\(lines)")
    check(parseGestures(lines.joined(separator: "\n"))["DR"] == .newTab, "menu choice takes effect")
    lines = gestureLines(["L BACK", "", ""], setting: "UR", to: .closeTab)
    check(lines == ["L BACK", "UR  CLOSE_TAB"], "menu choice adds a missing gesture", "\(lines)")

    check(gestureIconStrokes("DR") == [[.zero, CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]], "icon: down, then right")
    check(gestureIconStrokes("L") == [[.zero, CGPoint(x: -1, y: 0)]], "icon: left")
    check(gestureIconStrokes("LR") == [[.zero, CGPoint(x: -1, y: 0)], [CGPoint(x: -1, y: 0.5), CGPoint(x: 0, y: 0.5)]],
          "icon: left above, back right below", "\(gestureIconStrokes("LR"))")
    check(gestureIconStrokes("UD") == [[.zero, CGPoint(x: 0, y: -1)], [CGPoint(x: 0.5, y: -1), CGPoint(x: 0.5, y: 0)]],
          "icon: up on the left, back down on the right", "\(gestureIconStrokes("UD"))")
    check(Set(gestureCodes.map { "\(gestureIconStrokes($0))" }).count == 16, "all 16 icons differ")

    check(keyChord(.back, bundleID: "com.brave.Browser") == KeyChord(key: 0x21, flags: .maskCommand), "back: ⌘[")
    check(keyChord(.closeTab, bundleID: "com.apple.Safari") == KeyChord(key: 0x0D, flags: .maskCommand), "close tab: ⌘W")
    check(keyChord(.reopenTab, bundleID: "com.brave.Browser") == KeyChord(key: 0x11, flags: [.maskCommand, .maskShift]),
          "reopen closed tab: ⌘⇧T")
    check(keyChord(.incognito, bundleID: "org.mozilla.firefox") == KeyChord(key: 0x23, flags: [.maskCommand, .maskShift]),
          "Firefox private window: ⌘⇧P")
    check(keyChord(.top, bundleID: "com.brave.Browser") == KeyChord(key: 0x73, flags: .maskSecondaryFn), "top: Home (scrolls even in a text field)")
    check(keyChord(.bottom, bundleID: "com.apple.Safari") == KeyChord(key: 0x77, flags: .maskSecondaryFn), "bottom: End")
    check(keyChord(.downloads, bundleID: "org.mozilla.firefox") == KeyChord(key: 0x26, flags: .maskCommand), "Firefox downloads: ⌘J")
    check(keyChord(.incognito, bundleID: "org.mozilla.firefoxdeveloperedition")?.key == 0x23, "Firefox editions count as Firefox")
    check(menuCharacter(0x21) == "[" && axMenuModifiers(.maskCommand) == 0 && axMenuModifiers([.maskCommand, .maskShift]) == 1
          && axMenuModifiers([.maskCommand, .maskControl]) == 4 && axMenuModifiers(.maskSecondaryFn) == nil, "menu shortcut matching")
    let browsers = ["com.brave.Browser", "com.apple.Safari", "org.mozilla.firefox"]
    check(GestureAction.allCases.allSatisfy { a in browsers.allSatisfy { b in
        keyChord(a, bundleID: b).map { !$0.flags.contains(.maskCommand) || menuCharacter($0.key) != nil } ?? true } },
          "every ⌘ shortcut can be found in a menu")
    let line = grownTrail(.null, toCover: CGRect(x: 100, y: 500, width: 1500, height: 8))
    check(line.height <= 8 + 320 && line.width <= 1500 + 320, "trail panel: room only around the strokes", "\(line)")
    let grown = grownTrail(line, toCover: CGRect(x: 1700, y: 500, width: 100, height: 8))
    check(grown.minY == line.minY && grown.maxY == line.maxY && grown.minX == line.minX, "trail panel grows on the side that needs it", "\(grown)")
    check(GestureAction.allCases.allSatisfy { ($0 == .none || $0 == .maximize) == (keyChord($0, bundleID: "x") == nil) },
          "every action but none and maximize is a shortcut")

    // Chromium's tab and window shortcuts go as keys (a menu press can close a whole window);
    // the rest, and other browsers, through the menu.
    let chromiumKeys = GestureAction.allCases.filter { a in
        keyChord(a, bundleID: "com.brave.Browser").map { goesAsKeys($0, kind: .chromium) } ?? false }
    check(Set(chromiumKeys) == [.closeTab, .closeWindow, .newTab, .reopenTab, .newWindow, .incognito],
          "Chromium: ⌘W ⌘⇧W ⌘T ⌘⇧T ⌘N ⌘⇧N as keys, nothing else", "\(chromiumKeys)")
    check(!goesAsKeys(KeyChord(key: 0x0D, flags: .maskCommand), kind: .safari)
          && !goesAsKeys(KeyChord(key: 0x0D, flags: .maskCommand), kind: .none), "Safari and Firefox: ⌘W through the menu")
    check(!goesAsKeys(KeyChord(key: 0x0D, flags: [.maskCommand, .maskAlternate, .maskShift]), kind: .chromium),
          "Chromium: ⌥⌘⇧W (close all) is not one of them")
    // A disabled item read again within a second of the last read is checked again then.
    check(staleMenuWait(since: nil, now: 50) == 0 && staleMenuWait(since: 10, now: 20) == 0, "menu read long ago: believed")
    check(abs(staleMenuWait(since: 10, now: 10.4) - (menuRefreshInterval - 0.4)) < 1e-9, "menu read 0.4 s ago: wait for the next update")
    check(menuRefreshInterval > 1, "the wait outlasts AppKit's one-second menu refresh")
    // A press that timed out was delivered: no second press, no shortcut on top.
    check(menuPressOutcome(.success, remembered: true) == .done && menuPressOutcome(.cannotComplete, remembered: false) == .done,
          "a press that answered late counts as done")
    check(menuModifiersMatch(20, 4) && menuModifiersMatch(4, 4) && !menuModifiersMatch(24, 4) && !menuModifiersMatch(12, 4)
          && !menuModifiersMatch(nil, 0), "menu modifiers: the fn bit is ignored, no-⌘ items never match")
    check(menuMissRecheck >= 60, "a shortcut no menu has is not looked for on every gesture")
    // A "disabled" read is believed only when the menus were read up to date after the gesture
    // was made and after MousePilot last acted on the app.
    check(menuReadIsFresh(refreshedAt: 10, changedAt: 5, made: 8), "menus read up to date since: believed")
    check(!menuReadIsFresh(refreshedAt: 10, changedAt: 11, made: 8), "acted on the app since the last up-to-date read: read again")
    check(!menuReadIsFresh(refreshedAt: 7, changedAt: nil, made: 8), "the gesture is newer than the last up-to-date read: read again")
    check(!menuReadIsFresh(refreshedAt: nil, changedAt: nil, made: 0), "never read: not believed")
    check(menuPressOutcome(.invalidUIElement, remembered: true) == .lookAgain
          && menuPressOutcome(.invalidUIElement, remembered: false) == .useKeys
          && menuPressOutcome(.actionUnsupported, remembered: true) == .useKeys, "a gone item: look again once, then keys")

    // The drawing the main thread reads: points 2 pt apart, the title once a stroke counts.
    beginDrawing(at: .zero, window: .zero, stroke: true, title: true)
    var g = Gesture(tracker: GestureTracker(at: .zero), hit: Hit(pid: 0, window: .zero, windowID: 0, frontmostOwn: true),
                    browser: Browser(bundleID: "x", band: Band(top: 0, bottom: 40), kind: .none), focused: true,
                    map: whaleGestures, flags: [], start: .zero, press: 0)
    for i in 1...100 {
        let p = CGPoint(x: CGFloat(i) / 2, y: 0)
        let changed = g.tracker.move(to: p)
        draw(g, at: p, changed: changed)
    }
    let d = gestureDrawing.get()
    check(d.points.count == 17, "trail points 3 pt apart", "\(d.points.count)")
    check(d.visible && d.title == "다음 페이지" && d.arrows == "→", "title follows the gesture", "\(d.title ?? "nil") \(d.arrows)")
    endDrawing()
    check(!gestureDrawing.get().visible && gestureDrawing.get().points.isEmpty, "release clears the drawing")

    var t = GestureTracker(at: .zero)
    let n = 1_000_000, start = DispatchTime.now().uptimeNanoseconds
    for i in 0..<n { _ = t.move(to: CGPoint(x: CGFloat(i % 400), y: CGFloat(i / 400 % 2) * 60)) }
    let ns = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(n)
    check(ns < 1000, "a mouse event costs the recognizer under 1 µs", String(format: "%.0f ns", ns))
}

private func testGestureTarget() {
    var s = layout([w(5, brave, 400, 300, 300, 200), w(1, brave, 100, 100, 1200, 800)], standard: [brave: [1]])
    check(gestureTarget(CGPoint(x: 900, y: 700), s)?.windowID == 1, "gesture on a Brave page")
    check(gestureTarget(CGPoint(x: 900, y: 110), s)?.windowID == 1, "gesture on the tab strip")
    check(gestureTarget(CGPoint(x: 500, y: 400), s) == nil, "no gesture on a popup")
    s = layout([w(9, other, 0, 0, 800, 600), w(1, brave, 100, 100, 1200, 800)], standard: [brave: [1]])
    check(gestureTarget(CGPoint(x: 300, y: 300), s) == nil, "no gesture on another app's window in front")
    check(gestureTarget(CGPoint(x: 1000, y: 700), s)?.windowID == 1, "gesture on the uncovered part")
    for (i, id) in ["com.naver.Whale", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.operasoftware.OperaGX"].enumerated() {
        let pid = pid_t(400 + i)
        s.browsers[pid] = Browser(bundleID: id, band: Band(top: 0, bottom: 40), kind: .chromium)
        s.windows = [w(CGWindowID(20 + i), pid, 100, 100, 1200, 800)]
        check(gestureTarget(CGPoint(x: 500, y: 500), s) == nil, "\(id) keeps its own gestures")
    }
    for id in ["com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "org.mozilla.firefox"] {
        check(!hasOwnGestures(id), "\(id) gets MousePilot's gestures")
    }
    s = layout([w(11, brave, 0, 0, 2560, 40), w(12, brave, 0, 40, 2560, 74), w(10, brave, 0, 114, 2560, 1326)],
               standard: [brave: [10]])
    check(gestureTarget(CGPoint(x: 600, y: 20), s) == nil, "full screen: not on the tab strip window")
    check(gestureTarget(CGPoint(x: 600, y: 600), s)?.windowID == 10, "full screen: on the page")

    // A game or overlay of the app in front covering the display, on the same Space.
    let game: pid_t = 500
    s = layout([w(1, brave, 100, 0, 1200, 800)], standard: [brave: [1]])
    s.covers = [w(50, game, 0, 0, 2560, 1440, layer: 25)]
    s.frontPID = game
    check(gestureTarget(CGPoint(x: 600, y: 400), s) == nil, "no gesture through a full-screen game in front")
    check(hitTest(CGPoint(x: 600, y: 20), s) == nil, "no tab switch through a full-screen game in front")
    s.frontPID = brave
    check(gestureTarget(CGPoint(x: 600, y: 400), s)?.windowID == 1, "a background app's screen layer lets gestures through")
    check(hitTest(CGPoint(x: 600, y: 20), s) != nil, "a background app's screen layer lets scrolls through")
    // A screen-sized window below the normal level (a desktop overlay) is behind every window.
    s.covers = [w(51, game, 0, 0, 2560, 1440, layer: -2147483601), w(52, game, 0, 0, 2560, 1440, layer: -1)]
    s.frontPID = game
    check(gestureTarget(CGPoint(x: 600, y: 400), s)?.windowID == 1 && hitTest(CGPoint(x: 600, y: 20), s) != nil,
          "the front app's desktop-level layer stops neither gestures nor scrolls")

    // Separate Spaces per display: the part of a window reaching onto the other display is not there.
    s = layout([w(1, brave, 1600, 100, 1600, 900)], standard: [brave: [1]])
    check(gestureTarget(CGPoint(x: 3000, y: 600), s) == nil, "no gesture on the part shown on no display")
    check(gestureTarget(CGPoint(x: 2000, y: 600), s)?.windowID == 1, "gesture on the part that is shown")

    // A click without a stroke goes back where the pointer was released, unless it left the window.
    s = layout([w(9, other, 50, 50, 100, 100), w(1, brave, 100, 100, 1200, 800)], standard: [brave: [1]])
    let g = Gesture(tracker: GestureTracker(at: CGPoint(x: 160, y: 160)),
                    hit: Hit(pid: brave, window: CGRect(x: 100, y: 100, width: 1200, height: 800), windowID: 1, frontmostOwn: true),
                    browser: s.browsers[brave]!, focused: true, map: whaleGestures, flags: [], start: CGPoint(x: 160, y: 160), press: 0)
    check(clickPoint(g, release: CGPoint(x: 170, y: 175), s) == CGPoint(x: 170, y: 175), "click handed back at the release point")
    check(clickPoint(g, release: CGPoint(x: 145, y: 145), s) == CGPoint(x: 160, y: 160),
          "click handed back where pressed when released over another window")

    // Right clicks on a browser with gestures of its own never wait for WindowServer.
    s = layout([w(2, 400, 100, 100, 1200, 800), w(1, brave, 100, 100, 1200, 800)], standard: [brave: [1]])
    s.browsers[400] = Browser(bundleID: "com.naver.Whale", band: Band(top: 0, bottom: 40), kind: .chromium)
    check(!mayBeGestureTarget(CGPoint(x: 500, y: 500), s), "no window refresh for a right click on Whale")
    s.windows = [w(9, other, 0, 0, 800, 600), w(1, brave, 100, 100, 1200, 800)]
    check(mayBeGestureTarget(CGPoint(x: 500, y: 500), s), "refresh when a gesture browser's window is under the click")
}

/// The event tap thread's handling of a gesture whose tap goes off, or whose button-up is
/// from another press. Uses the shared state; nothing is posted and no action runs.
private func testGestureLifecycle() {
    var s = layout([w(1, brave, 100, 100, 1200, 800)], standard: [brave: [1]])
    s.windowsTime = uptime()
    s.gestures = true
    s.tapOn = true
    s.buttonTapOn = true
    state.update { $0 = s }
    func event(_ type: CGEventType, _ x: CGFloat, _ y: CGFloat, press: Int64) -> CGEvent {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .right)!
        e.setIntegerValueField(.mouseEventNumber, value: press)
        return e
    }
    func tapOff(_ kind: TapKind) {
        _ = callback(OpaquePointer(bitPattern: 1)!, .tapDisabledByUserInput, event(.rightMouseDragged, 500, 560, press: 7),
                     UnsafeMutableRawPointer(bitPattern: kind.rawValue))
    }
    check(!dragTapOn, "right drags do not reach MousePilot before a gesture")
    check(handleRightMouse(.rightMouseDown, event(.rightMouseDown, 500, 500, press: 7)), "a right press on Brave starts a gesture")
    check(dragTapOn, "the drags come to MousePilot while the gesture is under way")
    let begun = gesturesBegun.get()
    for y in stride(from: CGFloat(504), through: 560, by: 4) { _ = handleRightMouse(.rightMouseDragged, event(.rightMouseDragged, 500, y, press: 7)) }
    check(activeGesture?.tracker.code == "D" && gestureDrawing.get().visible, "the stroke is recognized and drawn")
    state.update { $0.tapOn = false }
    tapOff(.scroll)
    check(activeGesture != nil, "the scroll tap going off leaves a gesture alone")
    state.update { $0.tapOn = true; $0.buttonTapOn = false }
    tapOff(.buttons)
    check(activeGesture == nil && !gestureDrawing.get().visible && !dragTapOn,
          "turning the right-button tap off ends the gesture, its drawing and the drags")
    state.update { $0.buttonTapOn = true }
    check(handleRightMouse(.rightMouseDown, event(.rightMouseDown, 500, 500, press: 8)), "next press starts again")
    check(gesturesBegun.get() == begun + 1, "each gesture begun is counted (an action run late can tell)")
    check(!handleRightMouse(.rightMouseUp, event(.rightMouseUp, 500, 500, press: 9)) && activeGesture == nil && !dragTapOn,
          "a button-up of another press passes through and ends the gesture")
    check(repostedClicks.isEmpty && performedActions.isEmpty, "…and neither hands a click back nor runs anything")
    // Self-test builds record what would be posted or run instead of doing it.
    _ = handleRightMouse(.rightMouseDown, event(.rightMouseDown, 500, 500, press: 10))
    check(handleRightMouse(.rightMouseUp, event(.rightMouseUp, 500, 500, press: 10)) && repostedClicks == [CGPoint(x: 500, y: 500)]
          && performedActions.isEmpty, "a right click without a stroke is handed back where it was released")
    _ = handleRightMouse(.rightMouseDown, event(.rightMouseDown, 500, 500, press: 11))
    for y in stride(from: CGFloat(504), through: 560, by: 4) { _ = handleRightMouse(.rightMouseDragged, event(.rightMouseDragged, 500, y, press: 11)) }
    check(handleRightMouse(.rightMouseUp, event(.rightMouseUp, 500, 560, press: 11)) && performedActions == [.bottom]
          && repostedClicks.count == 1, "↓ runs its action (bottom) and hands no click back")
    // Its end: the release point, the gestures begun so far, and the session's location read
    // from the system then — not the gesture's start (synthetic events never move the session).
    let e = performedEnds.last, now = CGEvent(source: nil)?.location
    check(e?.pointer == CGPoint(x: 500, y: 560) && e?.gesturesBegun == gesturesBegun.get(),
          "the action gets the release point and the count of gestures begun")
    let gesturePoints = [CGPoint(x: 500, y: 500), CGPoint(x: 500, y: 560)]
    check(e?.session != nil && (!gesturePoints.contains(e!.session!) || gesturePoints.contains(now ?? .zero)),
          "the action gets the session's location read at the release, not the gesture's start or release point",
          "\(String(describing: e?.session))")
    check(tapOffEndsGesture(stillOn: false, buttonHeld: true) && tapOffEndsGesture(stillOn: true, buttonHeld: false)
          && !tapOffEndsGesture(stillOn: true, buttonHeld: true),
          "a tap turned off ends the gesture even with the button held; a timeout with it held does not")

    // Which taps are on: none while paused; the right-button one only with gestures on and a
    // window of a browser taking them on screen.
    let whale: pid_t = 400
    var t = layout([w(1, brave, 100, 100, 1200, 800)])
    t.gestures = true
    check(wantedTaps(t) == (true, true), "Brave on screen: scroll and right-button taps on")
    t.gestures = false
    check(wantedTaps(t) == (true, false), "gestures off: the right-button tap is off")
    t.gestures = true
    t.paused = true
    check(wantedTaps(t) == (false, false), "paused: both off")
    t.paused = false
    t.browsers[whale] = Browser(bundleID: "com.naver.Whale", band: Band(top: 0, bottom: 40), kind: .chromium)
    t.windows = [w(2, whale, 100, 100, 1200, 800), w(9, other, 0, 0, 800, 600)]
    check(wantedTaps(t) == (true, false), "only Whale (its own gestures) on screen: no right-button tap")
    t.windows = [w(1, brave, 100, 100, 1200, 30, layer: 3), w(9, other, 0, 0, 800, 600)]
    check(wantedTaps(t) == (false, false), "no browser window proper on screen: both off")
}

/// Top, bottom and page up/down scroll by wheel, which a focused page element (a video
/// player) cannot take the way it takes Home and End; MousePilot's own wheel event is no tab switch.
private func testPageScroll() {
    let top = wheelDelta(.top, windowHeight: 900), bottom = wheelDelta(.bottom, windowHeight: 900)
    check((top ?? 0) >= 1_000_000 && bottom == top.map { -$0 }, "top and bottom: one wheel event past any page's end",
          "\(top.map(String.init) ?? "nil") \(bottom.map(String.init) ?? "nil")")
    let down = wheelDelta(.pageDown, windowHeight: 900) ?? 0
    check(wheelDelta(.pageUp, windowHeight: 900) == -down && (-down) > 500 && (-down) < 780,
          "page up/down: about one page of the window's page area", "\(down)")
    check(wheelDelta(.pageDown, windowHeight: 150) == -100, "page down in a tiny window: still a step")
    // Every action whose key a page can take (no ⌘, ⌃ or ⌥: Home, End, Page Up, Page Down)
    // scrolls by wheel instead; nothing else does.
    let pageKeys = Set(GestureAction.allCases.filter { a in
        keyChord(a, bundleID: "com.brave.Browser").map { $0.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty } ?? false })
    let wheels = Set(GestureAction.allCases.filter { wheelDelta($0, windowHeight: 900) != nil })
    check(pageKeys == wheels && wheels == [.top, .bottom, .pageUp, .pageDown], "bare page keys scroll by wheel, nothing else",
          "\(pageKeys) \(wheels)")
    // The wheel event goes where the pointer really is (WindowServer moves the pointer to it).
    // The session's location ignores the gesture's swallowed events: while it still says what
    // it said at the release, the pointer has not moved since and is at the release point.
    let start = CGPoint(x: 1292.7578125, y: 752.1328125), release = CGPoint(x: 1259.8515625, y: 1308.1015625)
    let end = GestureEnd(pointer: release, session: start, gesturesBegun: 7)
    func point(_ session: CGPoint?, _ end: GestureEnd, begun: Int = 7, held: Bool = false) -> CGPoint? {
        wheelPoint(session: session, end: end, gesturesBegun: begun, buttonHeld: held)
    }
    check(point(start, end) == release, "pointer not moved since the release: the release point, not the gesture's start")
    check(point(CGPoint(x: start.x + 0.2, y: start.y), end) == release, "…however it is rounded")
    let moved = CGPoint(x: 1303.5, y: 815.05)
    check(point(moved, end) == moved, "pointer moved on since: where it is now")
    // ← (no wheel) from S0 to R0, then ↑ from R0 without moving: the session still says S0.
    let s0 = CGPoint(x: 400, y: 300), r1 = CGPoint(x: 300, y: 200)
    check(point(s0, GestureEnd(pointer: r1, session: s0, gesturesBegun: 2), begun: 2) == r1,
          "a gesture right after another, without moving between: the release point, not the earlier start")
    // Where the pointer is not known, the keys go.
    check(point(start, end, begun: 8) == nil && point(moved, end, begun: 9) == nil,
          "a later gesture has begun (an action run late): no wheel")
    check(point(start, end, held: true) == nil, "a button held (a drag or the next gesture under way): no wheel")
    check(point(nil, end) == nil && point(start, GestureEnd(pointer: release, session: nil, gesturesBegun: 7)) == nil,
          "the session's location unread, now or at the release: no wheel")
    let window = CGRect(x: 100, y: 100, width: 1200, height: 800)
    check(onPage(CGPoint(x: 600, y: 500), window: window), "wheel over the page")
    check(!onPage(CGPoint(x: 600, y: 150), window: window), "not over the toolbars: the keys go instead")
    check(!onPage(CGPoint(x: 1400, y: 500), window: window), "not outside the window")

    // The tab strip takes the user's wheel, never MousePilot's own.
    var s = layout([w(1, brave, 100, 100, 1200, 800)], standard: [brave: [1]])
    s.windowsTime = uptime()
    s.frontPID = brave
    s.focused[brave] = FocusedWindow(frame: nil, id: 1)
    s.wrap = true
    state.update { $0 = s }
    sentTabSteps = []
    let own = scroll(lines: -1)
    own.location = CGPoint(x: 300, y: 120)
    own.setIntegerValueField(.eventSourceUserData, value: gestureTag)
    check(!handleScroll(own) && sentTabSteps.isEmpty, "MousePilot's own page scroll over the tab strip switches no tab")
    let user = scroll(lines: -1)
    user.location = CGPoint(x: 300, y: 120)
    check(handleScroll(user) && sentTabSteps == [1], "the user's wheel there does", "\(sentTabSteps)")
}

func runSelfTests() -> Int {
    testHitTest()
    testRouting()
    testConfig()
    testConfigLinks()
    testWindowFilter()
    testScrollSteps()
    testTabArithmetic()
    testDirection()
    testAppleEventValues()
    testGestures()
    testGestureTarget()
    testGestureLifecycle()
    testPageScroll()
    print("self-test: \(passed) passed, \(failures) failed")
    return failures
}
