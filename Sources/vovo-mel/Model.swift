import Foundation
import MetalKit
import SceneKit
import SwiftUI
import VovoData
import VovoMetal
import VovoModel
import VovoText

/// The editor's state: a source mel, edit parameters, the edited mel, and the vocoded audio for both.
@MainActor
final class AppModel: ObservableObject {
    @Published var sourceName = "—"
    @Published var frames = 0
    @Published var original: [Float] = []
    @Published var edited: [Float] = []
    @Published var params = EditParams() { didSet { recompute() } }
    @Published var vocoderName = "vocos"
    @Published var showOriginal = false { didSet { if live { audio.swap(currentAudio) } } }   // A/B for the view, play and the live loop
    @Published var live = false { didSet { live ? audio.startLoop(currentAudio) : audio.stopLoop(); if live { status = "live: edits are heard in the loop" } } }
    @Published var terrain3D = false
    @Published var status = "load a WAV or synthesize"
    @Published var lastRenderMs = 0.0
    @Published var audioOriginal: [Float] = []
    @Published var audioEdited: [Float] = []
    @Published var layer = "decoder"          // decoder | prior | wav
    var synthesis: VovoTTS.Synthesis? = nil
    @Published var checkpointPath = ""            // empty = no acoustic checkpoint chosen yet
    @Published var vocoderPath = ""               // empty = no Vocos file (Griffin-Lim fallback)
    @Published var models = ModelScan()
    @Published var timeline = Timeline()
    @Published var showF0 = true
    @Published var showPhones = true
    @Published var playhead: Double = 0
    /// Prosody knobs for the next synthesis (variance-adaptor models).
    /// Hand-drawn pitch: one semitone offset per phone, edited by dragging the contour.
    @Published var pitchDelta: [Float] = []
    @Published var editingPitch = false
    /// Per-phone F0 in Hz as predicted before any hand editing (the curve you drag away from).
    @Published var baseHz: [Float] = []
    @Published var pitchShift: Float = 0
    @Published var pitchScale: Float = 1
    @Published var energyShift: Float = 0
    @Published var downloadProgress: Double? = nil  // non-nil while the Hub weights are downloading
    @Published var downloadMessage = ""
    let audio = AudioOut()
    weak var heatmap: MTKView? = nil
    var heatmapRenderer: MelHeatmap.Renderer? = nil
    weak var terrain: SCNView? = nil
    private var vocos: Vocos? = nil
    private let inverter = MelInverter()
    private var model: (path: String, model: VovoTTS)? = nil
    private var pendingVocode: DispatchWorkItem? = nil
    private var lastSay: (text: String, guidance: Float, steps: Int)? = nil
    private var lastPhones: [String] = []
    private var lastNoise: [Float] = []
    private var pendingResynth: DispatchWorkItem? = nil
    private var lastPlan: [VovoTTS.PhoneControl]? = nil

    var weightsInstalled: Bool { HubWeights.isInstalled }
    var hasAcoustic: Bool { !checkpointPath.isEmpty && FileManager.default.fileExists(atPath: checkpointPath) }
    var hasVocos: Bool { vocos != nil }

    init() {
        models = ModelScan.scan()
        pickDefaults()
    }

    /// Choose a checkpoint and a vocoder from what is on disk: the downloaded Hub weights first, then the
    /// bundled Vocos / anything found under checkpoints/, exports/, assets/. Says clearly when nothing is there.
    func pickDefaults() {
        if checkpointPath.isEmpty || !FileManager.default.fileExists(atPath: checkpointPath) {
            checkpointPath = HubWeights.isInstalled ? HubWeights.modelPath : (models.acoustic.last?.path ?? "")
        }
        if vocos == nil {
            let candidates = [HubWeights.isInstalled ? HubWeights.vocoderPath : nil, Vocos.defaultCheckpoint?.path, models.vocoders.first?.path].compactMap { $0 }
            for c in candidates { if let v = try? Vocos(checkpoint: URL(fileURLWithPath: c)) { vocos = v; vocoderPath = c; vocoderName = "vocos"; break } }
            if vocos == nil { vocoderName = "griffinlim" }
        }
        if !hasAcoustic && !hasVocos { status = "no weights found — Download the published voice (\(HubWeights.approxMB) MB) or open a WAV" }
        else if !hasAcoustic { status = "no acoustic checkpoint — Download the published voice or choose one; WAVs work" }
        else if !hasVocos { status = "no Vocos weights — Download the published voice; using Griffin-Lim" }
    }

    /// Fetch the published weights from the Hub (async), then select them.
    func downloadWeights() {
        guard downloadProgress == nil else { return }
        downloadProgress = 0; downloadMessage = "starting…"
        Task { @MainActor in
            do {
                try await HubWeights.download { [weak self] frac, msg in self?.downloadProgress = frac; self?.downloadMessage = msg }
                rescanModels()
                if let v = try? Vocos(checkpoint: URL(fileURLWithPath: HubWeights.vocoderPath)) { vocos = v; vocoderPath = HubWeights.vocoderPath; vocoderName = "vocos" }
                checkpointPath = HubWeights.modelPath
                if !original.isEmpty { audioOriginal = vocode(original); recompute(immediately: true); if live { audio.swap(currentAudio) } }
                status = "weights installed — ready to synthesize"
            } catch {
                status = "download failed: \(error.localizedDescription)"
                downloadMessage = "failed: \(error.localizedDescription)"
            }
            downloadProgress = nil
        }
    }

    /// Safetensors files under checkpoints/, exports/, assets/ and the downloaded Hub weights, classified by their keys.
    struct ModelScan: Codable {
        struct File: Codable, Identifiable, Hashable { var path: String, step: String; var id: String { path } }
        var acoustic: [File] = [], vocoders: [File] = []

        static func scan(roots: [String] = ["checkpoints", "exports", "assets", HubWeights.directory.path]) -> ModelScan {
            var out = ModelScan()
            let fm = FileManager.default
            for root in roots {
                guard let e = fm.enumerator(atPath: root) else { continue }
                for case let rel as String in e where rel.hasSuffix(".safetensors") && rel.split(separator: "/").count <= 3 {
                    let path = root + "/" + rel
                    guard let (keys, meta) = header(of: path) else { continue }
                    let f = File(path: path, step: meta["step"] ?? "")
                    if keys.contains("encoder.emb.weight") { out.acoustic.append(f) } else if keys.contains("backbone.embed.weight") { out.vocoders.append(f) }
                }
            }
            out.acoustic.sort { $0.path < $1.path }; out.vocoders.sort { $0.path < $1.path }
            return out
        }

        /// Reads only the JSON header of a safetensors file: (tensor names, metadata).
        static func header(of path: String) -> (Set<String>, [String: String])? {
            guard let h = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? h.close() }
            guard let lenData = try? h.read(upToCount: 8), lenData.count == 8 else { return nil }
            let n = Int(lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian })
            guard n > 0, n < 50_000_000, let json = try? h.read(upToCount: n),
                  let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
            let meta = obj["__metadata__"] as? [String: String] ?? [:]
            return (Set(obj.keys.filter { $0 != "__metadata__" }), meta)
        }
    }

    func rescanModels() { models = ModelScan.scan() }

    /// Switch the acoustic checkpoint; re-synthesizes the last sentence if there is one.
    struct FileMissing: LocalizedError { var path: String; var errorDescription: String? { "no such file: \(path)" } }

    func setCheckpoint(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path), ModelScan.header(of: path)?.0.contains("encoder.emb.weight") == true else {
            if !FileManager.default.fileExists(atPath: path) { throw FileMissing(path: path) }
            throw NSError(domain: "vovo-mel", code: 2, userInfo: [NSLocalizedDescriptionKey: "not a Vovo acoustic checkpoint: \(path)"])
        }
        checkpointPath = path
        if let s = lastSay { try synthesize(text: s.text, ckpt: path, guidance: s.guidance, steps: s.steps) }
        else { status = "checkpoint: \(URL(fileURLWithPath: path).lastPathComponent)" }
    }

    /// Switch the vocoder: a Vocos safetensors path, or "griffinlim".
    func setVocoder(path: String) throws {
        if path == "griffinlim" { setVocoder("griffinlim"); return }
        vocos = try Vocos(checkpoint: URL(fileURLWithPath: path))
        vocoderPath = path
        setVocoder("vocos")
        status = "vocoder: \(path)"
    }

    var stats: MelEdit.Stats { MelEdit.stats(edited.isEmpty ? original : edited) }
    var currentAudio: [Float] { showOriginal ? audioOriginal : audioEdited }

    func loadWAV(_ path: String) throws {
        let a = try Audio.load(URL(fileURLWithPath: path), targetRate: 24000)
        let mel = MelExtractor().logMel(a)
        setSource(mel, name: URL(fileURLWithPath: path).lastPathComponent, layer: "wav")
    }

    struct NoWeights: LocalizedError { var errorDescription: String? { "no acoustic checkpoint — Download the published voice (\(HubWeights.approxMB) MB) or choose a safetensors file" } }

    /// Normalized log-F0 (what the model predicts) -> Hz, using this speaker's statistics.
    func hzFromNormalized(_ values: [Float]) -> [Float] {
        guard let cfg = model?.model.cfg, !cfg.f0Mean.isEmpty else { return values.map { _ in 0 } }
        let mean = cfg.f0Mean[0], std = Swift.max(cfg.f0Std[0], 1e-3)
        return values.map { exp(mean + $0 * std) }
    }

    /// The curve as edited: the prediction times the hand-drawn semitone offsets.
    var editedHz: [Float] {
        zip(baseHz, pitchDelta.isEmpty ? [Float](repeating: 0, count: baseHz.count) : pitchDelta).map { $0 * pow(2, $1 / 12) }
    }

    /// Drag one phone's pitch to `hz` (and blend it into `radius` neighbours so the line stays smooth).
    func setPitch(phone: Int, hz: Float, radius: Int = 1) {
        guard phone >= 0, phone < baseHz.count, baseHz[phone] > 0, hz > 20 else { return }
        let target = 12 * log2(hz / baseHz[phone])
        for r in -radius...radius {
            let i = phone + r
            guard i >= 0, i < pitchDelta.count else { continue }
            let weight = Float(1) / Float(abs(r) + 1)
            pitchDelta[i] += (target - pitchDelta[i]) * weight
        }
        scheduleResynth()
    }

    /// Move the playhead by hand, and follow it with the audio when something is playing.
    func scrub(to seconds: Double) {
        playhead = max(0, seconds)
        if audio.playing || audio.looping { audio.seek(playhead, in: currentAudio) }
    }

    func resetPitchCurve() {
        guard !pitchDelta.isEmpty else { return }
        pitchDelta = [Float](repeating: 0, count: pitchDelta.count)
        scheduleResynth()
    }

    /// Re-synthesize from the same noise so only the prosody you dragged changes, then re-vocode.
    func scheduleResynth(immediately: Bool = false) {
        pendingResynth?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.resynthesize() }
        pendingResynth = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.12), execute: work)
    }

    private func resynthesize() {
        guard let m = model?.model, let last = lastSay, !pitchDelta.isEmpty else { return }
        let g2p = G2P()
        let ids: [Int32]
        var control: [VovoTTS.PhoneControl]
        if let plan = lastPlan {
            ids = (try? VovoTTS.plan(ssml: last.text, g2p: g2p).phones) ?? []
            control = plan
        } else {
            ids = g2p.encode(last.text)
            control = ids.map { _ in VovoTTS.PhoneControl() }
        }
        guard ids.count == pitchDelta.count else { return }
        for i in 0..<control.count { control[i].pitchShift += pitchDelta[i] }
        let t0 = Date()
        let s = m.synthesize(phones: ids, steps: last.steps, guidance: last.guidance,
                             noise: lastNoise.count == 0 ? nil : lastNoise,
                             pitchShift: pitchShift, pitchScale: pitchScale, energyShift: energyShift, control: control)
        synthesis = s
        original = layer == "prior" ? s.prior : s.mel
        frames = original.count / 100
        audioOriginal = vocode(original)
        recompute(immediately: true)
        rebuildTimeline()
        if live { audio.swap(currentAudio) }
        status = String(format: "re-synthesized in %.0f ms", Date().timeIntervalSince(t0) * 1000)
    }

    /// Pitch contour of whatever is currently playing, plus the phone spans when we synthesized it.
    func rebuildTimeline() {
        var t = Timeline()
        t.frames = frames
        let audio = currentAudio
        if !audio.isEmpty { t.f0 = PitchTracker().f0(audio) }
        if let s = synthesis, layer != "wav", !lastPhones.isEmpty {
            t.phones = Timeline.phones(tokens: lastPhones, durations: s.durations)
        }
        timeline = t
    }

    func synthesize(text: String, ckpt: String? = nil, guidance: Float = 2, steps: Int = 16) throws {
        let path = ckpt ?? checkpointPath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { status = NoWeights().errorDescription!; throw NoWeights() }
        if model?.path != path { model = (path, try VovoTTS.load(from: URL(fileURLWithPath: path)).model) }
        checkpointPath = path
        let g2p = G2P()
        let tokens: [String]
        let plan: (phones: [Int32], control: [VovoTTS.PhoneControl], spans: [SSML.Span])?
        if SSML.looksLikeMarkup(text) {
            let p = try VovoTTS.plan(ssml: text, g2p: g2p)
            plan = p; tokens = PhoneSet.decode(p.phones).map(String.init)
        } else {
            plan = nil; tokens = g2p.phonemize(text)
        }
        lastPhones = plan == nil ? tokens : PhoneSet.decode(plan!.phones).map(String.init)
        let ids = plan?.phones ?? PhoneSet.encode(tokens)
        let s = model!.model.synthesize(phones: ids, steps: steps, guidance: guidance,
                                        pitchShift: pitchShift, pitchScale: pitchScale, energyShift: energyShift,
                                        control: plan?.control)
        // Fresh sentence: reset the hand-drawn curve and remember the noise, so later edits move only pitch.
        lastNoise = s.x0
        pitchDelta = [Float](repeating: 0, count: s.pitch.count)
        baseHz = hzFromNormalized(s.pitch)
        lastPlan = plan?.control
        synthesis = s
        lastSay = (text, guidance, steps)
        setSource(s.mel, name: "\"\(text.prefix(40))\" (\(URL(fileURLWithPath: path).lastPathComponent), g\(guidance), \(steps) steps)", layer: "decoder")
    }

    func selectLayer(_ name: String) {
        guard let s = synthesis else { return }
        layer = name
        original = name == "prior" ? s.prior : s.mel
        recompute()
    }

    private func setSource(_ mel: [Float], name: String, layer: String) {
        original = mel; frames = mel.count / 100; sourceName = name; self.layer = layer
        audioOriginal = vocode(mel)
        if layer == "wav" { lastPhones = [] }
        recompute(immediately: true)
        rebuildTimeline()
        if live { audio.swap(currentAudio) }
    }

    func vocode(_ mel: [Float]) -> [Float] {
        let t = Date()
        defer { lastRenderMs = Date().timeIntervalSince(t) * 1000 }
        if vocoderName == "vocos", let v = vocos { return v.synthesize(logMel: mel) }
        return inverter.synthesize(logMel: mel)
    }

    func setVocoder(_ name: String) {
        vocoderName = name
        if !original.isEmpty { audioOriginal = vocode(original) }
        recompute(immediately: true)
    }

    /// Re-apply the remap now; re-vocode after a short debounce (slider drags).
    func recompute(immediately: Bool = false) {
        guard !original.isEmpty else { return }
        edited = MelEdit.apply(params, to: original, frames: frames)
        pendingVocode?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.audioEdited = self.vocode(self.edited)
            self.rebuildTimeline()
            self.status = String(format: "vocoded in %.0f ms%@", self.lastRenderMs, self.live ? " · live" : "")
            if self.live, !self.showOriginal { self.audio.swap(self.audioEdited) }
        }
        pendingVocode = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : (live ? 0.1 : 0.25)), execute: work)
    }

    func play(original: Bool? = nil) {
        let useOriginal = original ?? showOriginal
        let a = useOriginal ? audioOriginal : audioEdited
        guard !a.isEmpty else { return }
        if live { live = false }
        audio.play(a)
        status = useOriginal ? "playing original" : "playing edited"
    }

    func export(to dir: String) throws -> [String] {
        let d = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var written: [String] = []
        for (name, mel, wav) in [("original", original, audioOriginal), ("edited", edited, audioEdited)] {
            let wavURL = d.appendingPathComponent("\(name).wav"); try Audio.writeWAV(wav, rate: 24000, to: wavURL); written.append(wavURL.path)
            if let img = MelEdit.image(mel, frames: frames), let png = MelEdit.pngData(img) {
                let u = d.appendingPathComponent("\(name).png"); try png.write(to: u); written.append(u.path)
            }
        }
        let p = d.appendingPathComponent("params.json"); try JSONEncoder().encode(params).write(to: p); written.append(p.path)
        return written
    }

    struct State: Codable {
        var source: String, layer: String, frames: Int, params: EditParams, vocoder: String, vocoderPath: String, showOriginal: Bool, terrain3D: Bool, live: Bool
        var stats: MelEdit.Stats, playing: Bool, lastRenderMs: Double, status: String, checkpoint: String
        var phones: String, voicedFraction: Double, medianF0: Double, playhead: Double
        var pitchShift: Float, pitchScale: Float, energyShift: Float
        var weights: Weights
        struct Weights: Codable { var installed: Bool, directory: String, repo: String, hasAcoustic: Bool, hasVocos: Bool, downloading: Double?, message: String }
    }
    var state: State {
        State(source: sourceName, layer: layer, frames: frames, params: params, vocoder: vocoderName, vocoderPath: vocoderName == "vocos" ? vocoderPath : "griffinlim",
              showOriginal: showOriginal, terrain3D: terrain3D, live: live,
              stats: stats, playing: audio.playing || audio.looping, lastRenderMs: lastRenderMs, status: status, checkpoint: checkpointPath,
              phones: lastPhones.joined(), voicedFraction: timeline.f0.isEmpty ? 0 : Double(timeline.f0.filter { $0 > 0 }.count) / Double(timeline.f0.count),
              medianF0: {
                  let v = timeline.f0.filter { $0 > 0 }.sorted()
                  return v.isEmpty ? 0 : Double(v[v.count / 2])
              }(),
              playhead: playhead, pitchShift: pitchShift, pitchScale: pitchScale, energyShift: energyShift,
              weights: .init(installed: weightsInstalled, directory: HubWeights.directory.path, repo: HubWeights.repo, hasAcoustic: hasAcoustic, hasVocos: hasVocos,
                             downloading: downloadProgress, message: downloadMessage))
    }
}

extension AppModel {
    /// The contour, phone boundaries and playhead, drawn into a rect of a CG context (screenshots and exports).
    func drawTimeline(in rect: NSRect, ctx: CGContext) {
        guard timeline.frames > 0 else { return }
        let frames = Double(timeline.frames)
        func x(_ frame: Double) -> CGFloat { rect.minX + rect.width * frame / frames }

        if showF0, !timeline.f0.isEmpty {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1.5); ctx.setLineJoin(.round)
            var pen = false
            for (t, hz) in timeline.f0.enumerated() {
                guard let f = Timeline.melFraction(hz: hz) else { pen = false; continue }
                let p = CGPoint(x: x(Double(t)), y: rect.minY + rect.height * f)   // CG origin is bottom-left
                if pen { ctx.addLine(to: p) } else { ctx.move(to: p); pen = true }
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
        if showPhones, !timeline.phones.isEmpty {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
            ctx.setLineWidth(0.5)
            for phone in timeline.phones {
                ctx.move(to: CGPoint(x: x(Double(phone.start)), y: rect.minY))
                ctx.addLine(to: CGPoint(x: x(Double(phone.start)), y: rect.maxY))
            }
            ctx.strokePath()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor.white]
            for phone in timeline.phones where phone.length > 2 {
                let label = phone.symbol == " " ? "·" : phone.symbol
                (label as NSString).draw(at: CGPoint(x: x(Double(phone.start)) + 1, y: rect.minY + 2), withAttributes: attrs)
            }
            ctx.restoreGState()
        }
        if editingPitch, !baseHz.isEmpty, !timeline.phones.isEmpty {
            let hz = editedHz
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.cyan.cgColor); ctx.setLineWidth(2.5); ctx.setLineCap(.round)
            for (i, phone) in timeline.phones.enumerated() where i < hz.count {
                guard let f = Timeline.melFraction(hz: hz[i]) else { continue }
                let y = rect.minY + rect.height * f
                ctx.move(to: CGPoint(x: x(Double(phone.start)), y: y))
                ctx.addLine(to: CGPoint(x: x(Double(phone.start + phone.length)), y: y))
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
        if playhead > 0 {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemOrange.cgColor); ctx.setLineWidth(1.5)
            let px = x(min(playhead * 93.75, frames))
            ctx.move(to: CGPoint(x: px, y: rect.minY)); ctx.addLine(to: CGPoint(x: px, y: rect.maxY))
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// PNG of the window: SwiftUI chrome via cacheDisplay, Metal/SceneKit regions rendered offscreen and composited.
    /// (Screen capture APIs need a TCC grant this machine denies; the app can always render its own content.)
    func screenshot() -> Data? {
        guard let win = NSApp.windows.first(where: { $0.isVisible }), let cv = win.contentView, let rootLayer = cv.layer else { return nil }
        let scale = win.backingScaleFactor
        // Render the layer tree (SwiftUI text lives in layers that cacheDisplay skips); Metal/SceneKit layers stay black and get composited below.
        let base = NSImage(size: cv.bounds.size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            rootLayer.render(in: ctx); return true
        }
        let composed = NSImage(size: cv.bounds.size, flipped: false) { [self] rect in
            base.draw(in: rect)
            if let v = heatmap, v.window === win, !v.isHidden, let r = heatmapRenderer,
               let snap = r.snapshot(width: Int(v.bounds.width * scale), height: Int(v.bounds.height * scale)) {
                NSImage(cgImage: snap, size: v.bounds.size).draw(in: v.convert(v.bounds, to: cv))
            }
            if let s = terrain, s.window === win, !s.isHidden { s.snapshot().draw(in: s.convert(s.bounds, to: cv)) }
            // The SwiftUI overlay sits above the Metal view on screen, but the composite above just painted
            // over it — so redraw the contour, phone boundaries and playhead with Core Graphics.
            if let v = heatmap, v.window === win, !v.isHidden, let ctx = NSGraphicsContext.current?.cgContext {
                drawTimeline(in: v.convert(v.bounds, to: cv), ctx: ctx)
            }
            // SwiftUI text is not captured by cacheDisplay/CALayer.render on macOS 26: stamp the state as a caption.
            let st = stats, p = params
            let caption = String(format: "%@  ·  layer %@  ·  %d frames  ·  min %.2f max %.2f mean %.2f floor %.0f%%  ·  %@ %@\nexposure %.1f dB  contrast %.2f@%.1f  hi %.2f  sh %.2f  tilt %.1f/%.1f  floor %.0f dB  highCut %d  smooth %.2f  ·  %@",
                                 sourceName, layer, frames, st.min, st.max, st.mean, st.floorFraction * 100, vocoderName, showOriginal ? "(original)" : "(edited)",
                                 p.exposure, p.contrast, p.pivot, p.highlights, p.shadows, p.tiltLow, p.tiltHigh, p.floorDB, p.highCut, p.smooth, status)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
            let box = NSRect(x: 0, y: rect.maxY - 36, width: rect.width, height: 36)
            NSColor(calibratedWhite: 0, alpha: 0.75).setFill(); box.fill()
            (caption as NSString).draw(in: box.insetBy(dx: 8, dy: 3), withAttributes: attrs)
            return true
        }
        guard let tiff = composed.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff) else { return nil }
        return bmp.representation(using: .png, properties: [:])
    }
}
