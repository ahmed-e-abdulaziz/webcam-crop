// Unit tests for Sources/Crop.swift. Plain assertions (no XCTest needed): run ./test.sh
import CoreGraphics
import Foundation

var failures = 0
var checks = 0

func check(_ ok: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok {
        failures += 1
        if failures <= 10 { print("FAIL (line \(line)): \(message())") }
    }
}

func rect(_ w: Int, _ h: Int, zoom: Double, cx: Double = 0.5, cy: Double = 0.5, out: (Int, Int) = (1280, 720)) -> CGRect {
    Crop.rect(width: w, height: h,
              CropParams(zoom: zoom, centerX: cx, centerY: cy, outputWidth: out.0, outputHeight: out.1))
}

// 1x is the whole 16:9 frame
check(rect(1920, 1080, zoom: 1) == CGRect(x: 0, y: 0, width: 1920, height: 1080),
      "1x should cover the full frame, got \(rect(1920, 1080, zoom: 1))")

// 2x centred
check(rect(1920, 1080, zoom: 2) == CGRect(x: 480, y: 270, width: 960, height: 540),
      "2x centred, got \(rect(1920, 1080, zoom: 2))")

// 8x is the maximum; values outside 1...8 are clamped
let r8 = rect(1920, 1080, zoom: 8)
check(r8 == CGRect(x: 840, y: 472, width: 240, height: 134), "8x centred, got \(r8)")
check(rect(1920, 1080, zoom: 20) == r8, "zoom above 8x must clamp to 8x")
check(rect(1920, 1080, zoom: 0.25) == rect(1920, 1080, zoom: 1), "zoom below 1x must clamp to 1x")

// the box never leaves the frame, even when the centre is pushed past the edges
check(rect(1920, 1080, zoom: 2, cx: 0, cy: 0).origin == .zero, "top-left clamp")
check(rect(1920, 1080, zoom: 2, cx: 1, cy: 1) == CGRect(x: 960, y: 540, width: 960, height: 540), "bottom-right clamp")
check(rect(1920, 1080, zoom: 2, cx: -3, cy: 9) == CGRect(x: 0, y: 540, width: 960, height: 540), "far out-of-range centre")

// a 4:3 camera with 16:9 output is letterboxed vertically at 1x
check(rect(1440, 1080, zoom: 1) == CGRect(x: 0, y: 134, width: 1440, height: 810),
      "4:3 source at 1x, got \(rect(1440, 1080, zoom: 1))")

// property sweep: even-aligned, inside the frame, output aspect kept
var generator = SystemRandomNumberGenerator()
let sizes = [(1920, 1080), (1280, 720), (3840, 2160), (1440, 1080), (640, 480)]
for _ in 0..<5000 {
    let (w, h) = sizes.randomElement(using: &generator)!
    let out = Bool.random(using: &generator) ? (1280, 720) : (1920, 1080)
    let r = rect(w, h, zoom: .random(in: 0.5...10, using: &generator),
                 cx: .random(in: -0.5...1.5, using: &generator), cy: .random(in: -0.5...1.5, using: &generator), out: out)
    check([r.minX, r.minY, r.width, r.height].allSatisfy { Int($0) % 2 == 0 }, "not even-aligned: \(r)")
    check(r.minX >= 0 && r.minY >= 0 && r.maxX <= CGFloat(w) && r.maxY <= CGFloat(h), "outside \(w)x\(h): \(r)")
    // even-rounding may cost up to 2 px per side, so allow a few pixels of aspect error
    check(abs(r.width - r.height * 16 / 9) <= 4, "aspect drifted: \(r)")
    check(r.width >= CGFloat(min(w, h * 16 / 9)) / 8 - 2, "zoomed past 8x: \(r)")
}

print(failures == 0 ? "OK: \(checks) checks passed" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
