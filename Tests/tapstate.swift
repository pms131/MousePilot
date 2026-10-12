// Prints MousePilot's event taps for scripts/check.sh: how many it has, how many are enabled,
// and whether its scroll, right-button and drag taps are on (1) or off (0).
import CoreGraphics
import Foundation

var n: UInt32 = 0
CGGetEventTapList(0, nil, &n)
var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(n))
CGGetEventTapList(n, &taps, &n)
func mask(_ type: CGEventType) -> CGEventMask { 1 << type.rawValue }
var mine = 0, enabled = 0, scroll = 0, buttons = 0, drags = 0
for tap in taps.prefix(Int(n)) {
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(Int32(tap.tappingProcess), &path, UInt32(path.count)) > 0,
          String(cString: path).hasSuffix("/Contents/MacOS/mousepilot") else { continue }
    mine += 1
    guard tap.enabled else { continue }
    enabled += 1
    if tap.eventsOfInterest & mask(.scrollWheel) != 0 { scroll = 1 }
    if tap.eventsOfInterest & mask(.rightMouseDown) != 0 { buttons = 1 }
    if tap.eventsOfInterest & mask(.rightMouseDragged) != 0 { drags = 1 }
}
print("taps \(mine) enabled \(enabled) scroll \(scroll) buttons \(buttons) drags \(drags)")
