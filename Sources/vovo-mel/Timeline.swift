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


/// The interactive layer: drag to scrub, or (in pitch mode) drag the per-phone contour and hear the edit.
/// Editing writes semitone offsets into the same per-phone control array that SSML fills in, so the two are
/// the same feature reached two ways.
struct TimelineEditor: View {
    @EnvironmentObject var model: AppModel
    let frameRate: Double = 93.75

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let frames = max(model.frames, 1)
            let ribbon: CGFloat = model.showPhones && !model.timeline.phones.isEmpty ? 22 : 0
            let melHeight = h - ribbon

            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())

                // The editable curve: one step per phone, at the pitch the model will be told to use.
                if model.editingPitch, !model.baseHz.isEmpty, !model.timeline.phones.isEmpty {
                    let hz = model.editedHz
                    Path { p in
                        for (i, phone) in model.timeline.phones.enumerated() where i < hz.count {
                            guard let f = Timeline.melFraction(hz: hz[i]) else { continue }
                            let x0 = w * Double(phone.start) / Double(frames)
                            let x1 = w * Double(phone.start + phone.length) / Double(frames)
                            let y = melHeight * (1 - f)
                            p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y))
                        }
                    }
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .shadow(color: .black.opacity(0.7), radius: 1)
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let frame = Double(frames) * min(max(g.location.x / w, 0), 1)
                if model.editingPitch, !model.baseHz.isEmpty {
                    guard let phone = model.timeline.phones.firstIndex(where: { frame >= Double($0.start) && frame < Double($0.start + $0.length) }) else { return }
                    // y -> mel fraction -> Hz, the inverse of how the contour is drawn.
                    let fraction = 1 - min(max(g.location.y / melHeight, 0), 1)
                    model.setPitch(phone: phone, hz: Timeline.hz(melFraction: fraction))
                } else {
                    model.scrub(to: frame / frameRate)
                }
            })
        }
    }
}

extension Timeline {
    /// Inverse of `melFraction`: where a point on the band axis sits in Hz.
    static func hz(melFraction v: Double, cfg: MelConfig = MelConfig()) -> Float {
        func mel(_ f: Float) -> Double { 2595 * log10(1 + Double(f) / 700) }
        let lo = mel(cfg.fMin), hi = mel(cfg.fMax)
        let m = lo + (hi - lo) * min(max(v, 0), 1)
        return Float(700 * (pow(10, m / 2595) - 1))
    }
}

/// A downward-pointing playhead handle.
struct PlayheadHandle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// The time ruler above the spectrogram: ticks, seconds, and a handle you can grab and drag. Scrubbing
/// lives here so it stays available while the spectrogram itself is in pitch-editing mode.
struct TimeRuler: View {
    @EnvironmentObject var model: AppModel
    let frameRate: Double = 93.75
    private let height: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let seconds = max(Double(model.frames) / frameRate, 0.001)
            let x = w * min(max(model.playhead / seconds, 0), 1)
            // A tick every 0.1 s, a labelled one every 0.5 s — denser than that is unreadable at this size.
            let step = 0.1, labelEvery = 5

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.22))
                Path { p in
                    var i = 0
                    var t = 0.0
                    while t <= seconds {
                        let tx = w * t / seconds
                        let long = i % labelEvery == 0
                        p.move(to: CGPoint(x: tx, y: long ? height - 11 : height - 6))
                        p.addLine(to: CGPoint(x: tx, y: height))
                        t += step; i += 1
                    }
                }
                .stroke(Color.secondary.opacity(0.55), lineWidth: 0.75)

                ForEach(0...Int(seconds / (step * Double(labelEvery))), id: \.self) { k in
                    let t = Double(k) * step * Double(labelEvery)
                    Text(String(format: "%.1f", t))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .position(x: w * t / seconds + 12, y: 7)
                }

                PlayheadHandle()
                    .fill(Color.orange)
                    .frame(width: 13, height: 9)
                    .position(x: x, y: height - 5)
                    .shadow(color: .black.opacity(0.4), radius: 1)
                Text(String(format: "%.2f s", model.playhead))
                    .font(.system(size: 9, design: .monospaced).bold())
                    .foregroundStyle(Color.orange)
                    .position(x: min(max(x + 26, 26), w - 26), y: 7)
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                model.scrub(to: seconds * min(max(g.location.x / w, 0), 1))
            })
        }
        .frame(height: height)
    }
}
