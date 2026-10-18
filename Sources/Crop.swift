// Crop maths shared by the capture pipeline and the UI (kept free of AVFoundation so it can be unit-tested).
import CoreGraphics
import Foundation

struct CropParams: Equatable {
    var zoom = 2.0
    var centerX = 0.5
    var centerY = 0.5
    var outputWidth = 1280
    var outputHeight = 720
}

enum Crop {
    static let minZoom = 1.0
    static let maxZoom = 8.0

    /// Crop size (not yet aligned) with the output aspect ratio.
    static func size(width w: Double, height h: Double, _ p: CropParams) -> (Double, Double) {
        let aspect = Double(p.outputWidth) / Double(p.outputHeight)
        let z = min(max(minZoom, p.zoom), maxZoom)
        let cw = min(w, h * aspect) / z
        return (cw, cw / aspect)
    }

    /// Crop rectangle in source pixels: output aspect, kept inside the frame, even-aligned for 4:2:x video.
    static func rect(width w: Int, height h: Int, _ p: CropParams) -> CGRect {
        let (cw, ch) = size(width: Double(w), height: Double(h), p)
        let x = min(max(p.centerX * Double(w) - cw / 2, 0), Double(w) - cw)
        let y = min(max(p.centerY * Double(h) - ch / 2, 0), Double(h) - ch)
        func even(_ v: Double) -> Double { Double(Int(v) & ~1) }
        return CGRect(x: even(x), y: even(y), width: max(even(cw), 2), height: max(even(ch), 2))
    }
}
