// Posts zero-delta scroll events — they reach event taps but scroll nothing and switch no
// tab — for scripts/check.sh.
//   post <count> auto            cycle through points at the top and middle of every display
//   post <count> x y [x y ...]   cycle through the given points
// About 2,000 events a second.
import CoreGraphics
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard let count = args.first.flatMap(Int.init) else {
    print("usage: post <count> auto | x y ...")
    exit(2)
}
var points: [CGPoint] = []
if args.count > 1, args[1] == "auto" {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    for d in ids.prefix(Int(n)).map(CGDisplayBounds) {
        points += [CGPoint(x: d.midX, y: d.minY + 20), CGPoint(x: d.midX, y: d.minY + 60),
                   CGPoint(x: d.midX, y: d.minY + 130), CGPoint(x: d.midX, y: d.midY),
                   CGPoint(x: d.minX + 200, y: d.maxY - 200)]
    }
} else {
    let numbers = args.dropFirst().compactMap(Double.init)
    points = stride(from: 0, to: numbers.count - 1, by: 2).map { CGPoint(x: numbers[$0], y: numbers[$0 + 1]) }
}
guard !points.isEmpty else { print("no points"); exit(2) }
for i in 0..<count {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0)
    else { continue }
    e.location = points[i % points.count]
    e.post(tap: .cghidEventTap)
    usleep(500)
}
print("posted \(count) at \(points.count) points")
