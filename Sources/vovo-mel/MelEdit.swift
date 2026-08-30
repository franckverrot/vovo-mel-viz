import VovoData
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Photo-style global remaps on a [T, 100] log-mel (natural-log units; 1 dB ≈ 0.115 units).
struct EditParams: Codable, Equatable {
    var exposure: Float = 0       // dB, global offset
    var contrast: Float = 1       // scale around the pivot
    var pivot: Float = -6         // log-mel units around which contrast/highlights/shadows act
    var highlights: Float = 0     // -1…1: compress/expand above the pivot
    var shadows: Float = 0        // -1…1: lift/deepen below the pivot
    var tiltLow: Float = 0        // dB gain at band 0 (ramps to 0 at band 99)
    var tiltHigh: Float = 0       // dB gain at band 99 (ramps to 0 at band 0)
    var floorDB: Float = -140     // clamp: values below this (dB) become this; -140 = off
    var highCut: Int = 100        // bands >= highCut are muted (set to the floor)
    var smooth: Float = 0         // 0…1 temporal smoothing (EMA over frames)
    static let dBToLog: Float = Foundation.log(10) / 20   // 1 dB in natural-log units
}

enum MelEdit {
    static let floor = MelImage.floor
    static let displayMin = MelImage.displayMin, displayMax = MelImage.displayMax

    static func apply(_ p: EditParams, to mel: [Float], frames T: Int, bands: Int = 100) -> [Float] {
        var out = mel
        let k = EditParams.dBToLog
        let floorLog = Swift.max(floor, p.floorDB * k)
        for t in 0..<T {
            for b in 0..<bands {
                var v = mel[t * bands + b] + p.exposure * k
                let x = (v - p.pivot) * p.contrast
                let hs: Float = x > 0 ? x * (1 + p.highlights) : x * (1 - p.shadows)
                v = p.pivot + hs
                let fb = Float(b) / Float(bands - 1)
                v += (p.tiltLow * (1 - fb) + p.tiltHigh * fb) * k
                if b >= p.highCut { v = floor }
                out[t * bands + b] = Swift.max(v, floorLog)
            }
        }
        if p.smooth > 0 && T > 1 {
            let a = 1 - p.smooth
            for t in 1..<T { for b in 0..<bands { out[t * bands + b] = a * out[t * bands + b] + (1 - a) * out[(t - 1) * bands + b] } }
        }
        return out
    }

    struct Stats: Codable { var min: Float, max: Float, mean: Float, floorFraction: Float }
    static func stats(_ mel: [Float]) -> Stats {
        var mn = Float.greatestFiniteMagnitude, mx = -Float.greatestFiniteMagnitude, sum: Float = 0, atFloor = 0
        for v in mel { mn = Swift.min(mn, v); mx = Swift.max(mx, v); sum += v; if v <= floor + 1e-3 { atFloor += 1 } }
        return Stats(min: mn, max: mx, mean: sum / Float(Swift.max(mel.count, 1)), floorFraction: Float(atFloor) / Float(Swift.max(mel.count, 1)))
    }

    static func color(_ v: Float) -> (Float, Float, Float) { MelImage.color(v) }
    static func image(_ mel: [Float], frames T: Int, bands: Int = 100, scale: Int = 4) -> CGImage? { MelImage.image(mel, frames: T, bands: bands, scale: scale) }
    static func pngData(_ image: CGImage) -> Data? { MelImage.pngData(image) }
}
