// Checks that a gesture's trail and title reach the screen: draws a scripted gesture the
// way the event tap thread does (no action runs, the cursor is not moved), then asks the
// window server which of this process's windows are on screen, where and at what level.
// Built only by scripts/check.sh (swiftc -D OVERLAYTEST Sources/MousePilot/*.swift
// Tests/OverlayTest.swift); the shipped app does not contain it.
import AppKit

private var failures: Int32 = 0

private func expect(_ condition: Bool, _ name: String, _ detail: String = "") {
    if !condition {
        failures += 1
        print("FAIL  \(name)" + (detail.isEmpty ? "" : " — " + detail))
    }
}

/// This process's windows on screen above the normal level.
private func panelsOnScreen() -> [CGRect] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w in
        guard w[kCGWindowOwnerPID as String] as? pid_t == getpid(),
              (w[kCGWindowLayer as String] as? Int ?? 0) >= Int(CGWindowLevelForKey(.popUpMenuWindow)),
              (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let b = w[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: b)
    }
}

func runOverlayTest() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let display = NSScreen.screens.first?.frame else {
        print("overlay test: no display")
        exit(1)
    }
    // A browser-window-sized area off the main display's centre (global coordinates), so a
    // title placed with the y axis unflipped would show up elsewhere.
    let window = CGRect(x: display.midX - 400 + 200, y: display.midY - 300 + 150, width: 800, height: 600)
    let hit = Hit(pid: 0, window: window, windowID: 0, frontmostOwn: true)
    let browser = Browser(bundleID: "test", band: Band(top: 0, bottom: 40), kind: .none)
    Thread.detachNewThread {
        let start = CGPoint(x: window.midX - 120, y: window.midY - 120)
        var p = start
        beginDrawing(at: p, window: window, stroke: true, title: true)
        var g = Gesture(tracker: GestureTracker(at: p), hit: hit, browser: browser, focused: true,
                        map: whaleGestures, flags: [], start: p, press: 0)
        for i in 0..<240 {   // down 120 pt, then right 120 pt: "DR"
            p = i < 120 ? CGPoint(x: p.x, y: p.y + 1) : CGPoint(x: p.x + 1, y: p.y)
            let changed = g.tracker.move(to: p)
            draw(g, at: p, changed: changed)
            usleep(1000)
        }
        usleep(300_000)   // the last redraw
        DispatchQueue.main.sync {
            let shown = panelsOnScreen()
            expect(shown.count == 2, "trail and title panels are on screen", "\(shown)")
            expect(shown.contains { $0.contains(start) && $0.contains(p) }, "the trail panel covers the strokes", "\(shown)")
            // The title panel is the one away from where the strokes began (the trail has it).
            let title = shown.first { !$0.contains(start) }
            expect(title.map { abs($0.midX - window.midX) <= 2 && abs($0.midY - window.midY) <= 2 } == true,
                   "the title panel is in the middle of the window", "\(shown)")
            expect(gestureDrawing.get().title == GestureAction.closeTab.title, "the title is the gesture's action",
                   gestureDrawing.get().title ?? "nil")
        }
        endDrawing()
        usleep(300_000)
        var before = Set<CGWindowID>()
        DispatchQueue.main.sync {
            expect(panelsOnScreen().isEmpty, "both panels are gone after the gesture", "\(panelsOnScreen())")
            // After the displays change the panels are thrown away; the next gesture makes new
            // ones, and they reach the screen.
            before = overlayWindowIDs.get()
            gestureOverlay.discardPanels()
            expect(overlayWindowIDs.get() == before, "discarded panels stay out of the window cache a while")
        }
        usleep(1_300_000)
        DispatchQueue.main.sync {
            expect(overlayWindowIDs.get().isEmpty, "…then the window cache forgets them", "\(overlayWindowIDs.get())")
        }
        p = start
        beginDrawing(at: p, window: window, stroke: true, title: true)
        g = Gesture(tracker: GestureTracker(at: p), hit: hit, browser: browser, focused: true,
                    map: whaleGestures, flags: [], start: p, press: 0)
        for _ in 0..<120 {   // down 120 pt: "D"
            p = CGPoint(x: p.x, y: p.y + 1)
            let changed = g.tracker.move(to: p)
            draw(g, at: p, changed: changed)
            usleep(1000)
        }
        usleep(300_000)
        var shownIDs = Set<CGWindowID>()
        DispatchQueue.main.sync {
            let ids = overlayWindowIDs.get()
            shownIDs = ids
            expect(panelsOnScreen().count == 2 && ids.count == 2 && ids.isDisjoint(with: before),
                   "after the panels are discarded, the next gesture shows new ones", "\(panelsOnScreen()) \(ids) \(before)")
            // Discarded in the middle of a gesture (the displays changed): drawn again at once on
            // new panels, without waiting for the pointer to move.
            gestureOverlay.discardPanels()
        }
        usleep(300_000)
        DispatchQueue.main.sync {
            let ids = overlayWindowIDs.get().subtracting(shownIDs)
            expect(panelsOnScreen().count == 2 && ids.count == 2,
                   "discarded mid-gesture: trail and title back at once on new panels", "\(panelsOnScreen()) \(ids)")
        }
        endDrawing()
        usleep(300_000)
        DispatchQueue.main.sync {
            expect(panelsOnScreen().isEmpty, "…and hides them after it", "\(panelsOnScreen())")
            print("overlay test: \(failures == 0 ? "trail and title shown, then hidden" : "\(failures) failed")")
            exit(failures)
        }
    }
    app.run()
    exit(1)
}
