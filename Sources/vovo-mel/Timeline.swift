import SwiftUI
import VovoData
import VovoModel

/// What the mel picture means in time: the F0 contour drawn where its frequency lands on the mel scale,
/// the phone the model is pronouncing at each moment, and where playback has reached.
struct Timeline {
    /// Per-phone spans in frames, from the durations the model predicted (synthesized audio only —
    /// a loaded WAV has no alignment).
    struct Phone: Identifiable {
        let id: Int
        let symbol: String
        let start: Int, length: Int
    }

    var f0: [Float] = []          // Hz per frame, 0 = unvoiced
    var phones: [Phone] = []
    var frames: Int = 0

    /// Mel-scale position of a frequency, as a fraction of the band axis — so the contour sits where that
    /// pitch actually lives in the picture above it.
    static func melFraction(hz: Float, cfg: MelConfig = MelConfig()) -> Double? {
        guard hz > 0 else { return nil }
        func mel(_ f: Float) -> Double { 2595 * log10(1 + Double(f) / 700) }
        let lo = mel(cfg.fMin), hi = mel(cfg.fMax)
        let v = (mel(hz) - lo) / (hi - lo)
        return v.isFinite ? min(max(v, 0), 1) : nil
    }

    static func phones(tokens: [String], durations: [Int]) -> [Phone] {
        var out: [Phone] = []
        var t = 0
        for (i, d) in durations.enumerated() {
            let symbol = i < tokens.count ? tokens[i] : "?"
            out.append(Phone(id: i, symbol: symbol, start: t, length: d))
            t += d
        }
        return out
    }
}

/// Drawn over the heatmap in SwiftUI (rather than in Metal) so text, hairlines and hit-testing stay simple.
struct TimelineOverlay: View {
    let timeline: Timeline
    let playhead: Double        // seconds
    let showF0: Bool
    let showPhones: Bool
    let frameRate: Double = 93.75

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let frames = max(timeline.frames, 1)
            let ribbon: CGFloat = showPhones && !timeline.phones.isEmpty ? 22 : 0
            let melHeight = h - ribbon

            ZStack(alignment: .topLeading) {
                if showF0, !timeline.f0.isEmpty {
                    // The contour, in mel-scale position: broken at unvoiced frames rather than joined through them.
                    Path { p in
                        var pen = false
                        for (t, hz) in timeline.f0.enumerated() {
                            guard let f = Timeline.melFraction(hz: hz) else { pen = false; continue }
                            let pt = CGPoint(x: w * Double(t) / Double(frames), y: melHeight * (1 - f))
                            if pen { p.addLine(to: pt) } else { p.move(to: pt); pen = true }
                        }
                    }
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .shadow(color: .black.opacity(0.6), radius: 1)
                }

                if showPhones, !timeline.phones.isEmpty {
                    ForEach(timeline.phones) { phone in
                        let x = w * Double(phone.start) / Double(frames)
                        let pw = w * Double(phone.length) / Double(frames)
                        // Boundary tick up the spectrogram, label in the ribbon below it.
                        Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: melHeight)) }
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                        Text(phone.symbol == " " ? "·" : phone.symbol)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(playing(phone) ? Color.orange : Color.secondary)
                            .frame(width: max(pw, 4), height: ribbon)
                            .background(playing(phone) ? Color.orange.opacity(0.18) : Color.clear)
                            .clipped()
                            .position(x: x + pw / 2, y: melHeight + ribbon / 2)
                    }
                }

                if playhead > 0 {
                    let x = w * min(playhead * frameRate / Double(frames), 1)
                    Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h)) }
                        .stroke(Color.orange, lineWidth: 1.5)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func playing(_ phone: Timeline.Phone) -> Bool {
        let t = Int(playhead * frameRate)
        return playhead > 0 && t >= phone.start && t < phone.start + phone.length
    }
}
