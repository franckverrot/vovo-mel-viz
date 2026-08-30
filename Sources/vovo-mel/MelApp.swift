import AppKit
import SwiftUI

/// "Lightroom for Vovo mels": load or synthesize a [T,100] log-mel, remap it with photo-style controls,
/// re-vocode, A/B against the original, export. A local HTTP API (Server.swift) mirrors every control.
@main
struct VovoMelApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Vovo Mel Editor") {
            EditorView().environmentObject(model)
                .frame(minWidth: 1100, minHeight: 640)
                .onAppear {
                    delegate.server = LocalServer(model: model, port: UInt16(ProcessInfo.processInfo.environment["VOVO_MEL_PORT"] ?? "") ?? 4747)
                    delegate.server?.start()
                    if let path = ProcessInfo.processInfo.environment["VOVO_MEL_WAV"] { try? model.loadWAV(path) }
                }
        }
        .windowStyle(.titleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var server: LocalServer?
    func applicationDidFinishLaunching(_ n: Notification) {
        // Running from `swift run` there is no bundle: make this a regular app so the window shows and takes focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct EditorView: View {
    @EnvironmentObject var model: AppModel
    @State private var sayText = "The quick brown fox jumps over the lazy dog."
    @State private var guidance: Float = 2
    @State private var steps = 16

    var body: some View {
        HSplitView {
            VStack(spacing: 8) {
                header
                ZStack {
                    if model.frames == 0 {
                        Text("Drop a WAV, open one (⌘O), or synthesize below").foregroundStyle(.secondary)
                    } else if model.terrain3D {
                        MelTerrain(mel: model.showOriginal ? model.original : model.edited, frames: model.frames)
                    } else {
                        MelHeatmap(mel: model.showOriginal ? model.original : model.edited, frames: model.frames)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.05, green: 0.05, blue: 0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    providers.first?.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                        if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) {
                            DispatchQueue.main.async { try? model.loadWAV(u.path) }
                        }
                    }
                    return true
                }
                transport
                synthBar
            }
            .padding(12)
            .frame(minWidth: 700)
            controls.frame(width: 320)
        }
    }

    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.sourceName).font(.headline).lineLimit(1)
                let s = model.stats
                Text(String(format: "%d frames · %.2fs · layer %@ · min %.2f max %.2f mean %.2f · floor %.0f%%",
                            model.frames, Double(model.frames) * 256 / 24000, model.layer, s.min, s.max, s.mean, s.floorFraction * 100))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $model.terrain3D) { Text("2-D").tag(false); Text("3-D").tag(true) }.pickerStyle(.segmented).frame(width: 120)
        }
    }

    var transport: some View {
        HStack(spacing: 12) {
            Picker("", selection: $model.showOriginal) { Text("Edited").tag(false); Text("Original").tag(true) }.pickerStyle(.segmented).frame(width: 180)
            Button(model.audio.playing ? "■ Stop" : "▶ Play") { model.audio.playing ? model.audio.stop() : model.play() }.keyboardShortcut(.space, modifiers: [])
            Button("A/B") { model.showOriginal.toggle(); if !model.live { model.play() } }.keyboardShortcut("b")
            Toggle("Live", isOn: $model.live).toggleStyle(.switch).keyboardShortcut("l").help("Loop the utterance and hear every slider move mid-sentence (L)")
            Picker("Vocoder", selection: Binding(get: { model.vocoderName == "vocos" ? model.vocoderPath : "griffinlim" },
                                                 set: { v in do { try model.setVocoder(path: v) } catch { model.status = "\(error)" } })) {
                ForEach(model.models.vocoders) { f in Text(label(f)).tag(f.path) }
                if !model.models.vocoders.contains(where: { $0.path == model.vocoderPath }) { Text(label(model.vocoderPath)).tag(model.vocoderPath) }
                Divider()
                Text("Griffin-Lim").tag("griffinlim")
            }.frame(width: 300)
            Button("…") { browse(kind: .vocoder) }.help("Choose a vocoder safetensors file")
            if model.synthesis != nil {
                Picker("Layer", selection: Binding(get: { model.layer }, set: { model.selectLayer($0) })) {
                    Text("decoder").tag("decoder"); Text("prior μ").tag("prior")
                }.frame(width: 170)
            }
            Spacer()
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            Button("Export…") {
                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                if p.runModal() == .OK, let u = p.url { model.status = ((try? model.export(to: u.path)) ?? []).isEmpty ? "export failed" : "exported to \(u.lastPathComponent)" }
            }
        }
    }

    var synthBar: some View {
        HStack {
            Button("Open WAV…") {
                let p = NSOpenPanel(); p.allowedContentTypes = [.wav, .audio]
                if p.runModal() == .OK, let u = p.url { try? model.loadWAV(u.path) }
            }.keyboardShortcut("o")
            TextField("Text to synthesize", text: $sayText).textFieldStyle(.roundedBorder)
            Picker("Model", selection: Binding(get: { model.checkpointPath }, set: { v in do { try model.setCheckpoint(v) } catch { model.status = "\(error)" } })) {
                ForEach(model.models.acoustic) { f in Text(label(f)).tag(f.path) }
                if !model.models.acoustic.contains(where: { $0.path == model.checkpointPath }) { Text(label(model.checkpointPath)).tag(model.checkpointPath) }
            }.frame(width: 300)
            Button("…") { browse(kind: .acoustic) }.help("Choose an acoustic checkpoint")
            Button("⟳") { model.rescanModels() }.help("Rescan checkpoints/, exports/ and assets/ for safetensors files")
            Stepper("g \(String(format: "%.1f", guidance))", value: $guidance, in: 1...4, step: 0.5).frame(width: 90)
            Stepper("\(steps) steps", value: $steps, in: 2...64, step: 2).frame(width: 100)
            Button("Say") {
                model.status = "synthesizing…"
                do { try model.synthesize(text: sayText, guidance: guidance, steps: steps) } catch { model.status = "\(error)" }
            }.keyboardShortcut(.return, modifiers: .command)
        }
    }

    enum ModelKind { case acoustic, vocoder }

    /// "lj3/step_6000 (6000)" style labels: the two last path components plus the step from the metadata.
    func label(_ f: AppModel.ModelScan.File) -> String { label(f.path) + (f.step.isEmpty ? "" : " · step \(f.step)") }
    func label(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        return parts.suffix(2).joined(separator: "/").replacingOccurrences(of: ".safetensors", with: "")
    }

    func browse(kind: ModelKind) {
        let p = NSOpenPanel(); p.canChooseDirectories = false; p.allowsMultipleSelection = false
        p.directoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard p.runModal() == .OK, let u = p.url else { return }
        do {
            switch kind {
            case .acoustic: try model.setCheckpoint(u.path)
            case .vocoder: try model.setVocoder(path: u.path)
            }
        } catch { model.status = "\(error)" }
    }

    var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Develop").font(.title3.bold())
                slider("Exposure", $model.params.exposure, -20...20, unit: "dB")
                slider("Contrast", $model.params.contrast, 0.25...3, unit: "×")
                slider("Pivot", $model.params.pivot, -14...2, unit: "log")
                slider("Highlights", $model.params.highlights, -1...1)
                slider("Shadows", $model.params.shadows, -1...1)
                Divider()
                Text("Tone (bands)").font(.title3.bold())
                slider("Low tilt", $model.params.tiltLow, -6...6, unit: "dB")
                slider("High tilt", $model.params.tiltHigh, -6...6, unit: "dB")
                slider("Floor", $model.params.floorDB, -140...(-20), unit: "dB")
                intSlider("High cut", $model.params.highCut, 10...100, unit: "bands")
                slider("Smooth (time)", $model.params.smooth, 0...0.95)
                Divider()
                HStack {
                    Button("Reset") { model.params = EditParams() }
                    Spacer()
                    Text(String(format: "render %.0f ms", model.lastRenderMs)).font(.caption).foregroundStyle(.secondary)
                }
                Text("API: http://127.0.0.1:4747/state").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(14)
        }
    }

    func slider(_ name: String, _ v: Binding<Float>, _ r: ClosedRange<Float>, unit: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(name); Spacer(); Text(String(format: "%.2f %@", v.wrappedValue, unit)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            Slider(value: v, in: r)
        }
    }

    func intSlider(_ name: String, _ v: Binding<Int>, _ r: ClosedRange<Int>, unit: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(name); Spacer(); Text("\(v.wrappedValue) \(unit)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            Slider(value: Binding(get: { Double(v.wrappedValue) }, set: { v.wrappedValue = Int($0.rounded()) }), in: Double(r.lowerBound)...Double(r.upperBound), step: 1)
        }
    }
}
