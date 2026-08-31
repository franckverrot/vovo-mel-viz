import AppKit
import Foundation
import Network
import VovoData

/// Minimal local HTTP/JSON API on 127.0.0.1:4747 so the editor can be driven and inspected from a shell.
///   GET  /state              -> JSON state (source, params, stats, vocoder, playing…)
///   GET  /mel.png[?which=original|edited&scale=N]  -> heatmap PNG
///   GET  /screenshot.png     -> PNG of the app window (self-capture, no TCC needed)
///   GET  /audio.wav[?which=…] -> vocoded audio
///   POST /params   {"exposure":..,"contrast":..,...}   (partial: only given keys change)
///   POST /load     {"wav":"path"} | {"say":"text","ckpt":"path","guidance":2,"steps":16} | {"layer":"prior|decoder"}
///   GET  /models             -> {"acoustic":[{path,step}…],"vocoders":[…]} (safetensors found under checkpoints/, exports/, assets/)
///   POST /models   {"ckpt":"path","vocoder":"path|griffinlim","rescan":true,"download":true}
///                  (switching the checkpoint re-synthesizes the last sentence; download = fetch the published weights from the Hub, async — poll /state)
///   POST /vocoder  {"name":"vocos|griffinlim"} | {"path":"….safetensors"}
///   POST /play     {"which":"edited|original"} ; POST /stop
///   POST /view     {"showOriginal":bool,"terrain3D":bool,"live":bool}   (live = loop the utterance, hot-swap on every edit)
///   GET  /pitch              -> per-phone base/edited F0 in Hz, the hand-drawn deltas, and the phone spans
///   POST /pitch    {"phone":N,"hz":180,"radius":1} | {"reset":true} | {"scrub":seconds} | {"editing":bool}
///                  | {"break":300} | {"emphasis":"strong|moderate|reduced|none"} | {"commit":true}
///                  (structural edits apply at the playhead and rewrite the text as SSML)
///   POST /export   {"dir":"path"} -> {"written":[…]}
final class LocalServer {
    let model: AppModel
    let port: UInt16
    private var listener: NWListener?

    init(model: AppModel, port: UInt16 = 4747) { self.model = model; self.port = port }

    func start() {
        guard let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!) else { print("API: could not listen on \(port)"); return }
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.start(queue: DispatchQueue(label: "vovo.mel.api"))
        print("API: http://127.0.0.1:\(port)/state")
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: DispatchQueue(label: "vovo.mel.conn"))
        var buffer = Data()
        func receive() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
                guard let self else { return }
                if let data { buffer.append(data) }
                if let (req, rest) = Self.parse(buffer) {
                    _ = rest
                    self.respond(req, on: c)
                } else if done || err != nil { c.cancel() } else { receive() }
            }
        }
        receive()
    }

    struct Request { var method: String, path: String, query: [String: String], body: Data }

    static func parse(_ data: Data) -> (Request, Data)? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headEnd.lowerBound], as: UTF8.self)
        let lines = head.split(separator: "\r\n").map(String.init)
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        var length = 0
        for l in lines.dropFirst() where l.lowercased().hasPrefix("content-length:") { length = Int(l.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
        let bodyStart = headEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let body = data[bodyStart..<(bodyStart + length)]
        var path = parts[1], query: [String: String] = [:]
        if let q = path.firstIndex(of: "?") {
            for kv in path[path.index(after: q)...].split(separator: "&") {
                let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
                query[p[0]] = p.count > 1 ? p[1].removingPercentEncoding ?? p[1] : ""
            }
            path = String(path[..<q])
        }
        return (Request(method: parts[0], path: path, query: query, body: Data(body)), data[(bodyStart + length)...])
    }

    private func respond(_ req: Request, on c: NWConnection) {
        DispatchQueue.main.async { [self] in
            let (status, type, body) = self.route(req)
            var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            var out = Data(head.utf8); out.append(body)
            c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
            head = ""
        }
    }

    private func json(_ obj: Any) -> Data { (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8) }
    private func body(_ req: Request) -> [String: Any] { (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:] }

    @MainActor private func route(_ req: Request) -> (String, String, Data) {
        do {
            switch (req.method, req.path) {
            case ("GET", "/state"), ("GET", "/"):
                return ("200 OK", "application/json", try JSONEncoder().encode(model.state))
            case ("GET", "/mel.png"):
                let which = req.query["which"] ?? "edited"
                let mel = which == "original" ? model.original : model.edited
                guard !mel.isEmpty, let img = MelEdit.image(mel, frames: model.frames, scale: Int(req.query["scale"] ?? "4") ?? 4), let png = MelEdit.pngData(img) else { return ("404 Not Found", "text/plain", Data("no mel loaded".utf8)) }
                return ("200 OK", "image/png", png)
            case ("GET", "/screenshot.png"):
                guard let png = model.screenshot() else { return ("500 Internal Server Error", "text/plain", Data("capture failed".utf8)) }
                return ("200 OK", "image/png", png)
            case ("GET", "/audio.wav"):
                let a = (req.query["which"] ?? "edited") == "original" ? model.audioOriginal : model.audioEdited
                guard !a.isEmpty else { return ("404 Not Found", "text/plain", Data("no audio".utf8)) }
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vovo-mel-\(UUID().uuidString).wav")
                try Audio.writeWAV(a, rate: 24000, to: tmp); defer { try? FileManager.default.removeItem(at: tmp) }
                return ("200 OK", "audio/wav", try Data(contentsOf: tmp))
            case ("POST", "/params"):
                var p = model.params
                let b = body(req)
                func f(_ k: String) -> Float? { (b[k] as? NSNumber)?.floatValue }
                if let v = f("exposure") { p.exposure = v }; if let v = f("contrast") { p.contrast = v }; if let v = f("pivot") { p.pivot = v }
                if let v = f("highlights") { p.highlights = v }; if let v = f("shadows") { p.shadows = v }; if let v = f("tiltLow") { p.tiltLow = v }
                if let v = f("tiltHigh") { p.tiltHigh = v }; if let v = f("floorDB") { p.floorDB = v }; if let v = f("smooth") { p.smooth = v }
                if let v = b["highCut"] as? NSNumber { p.highCut = v.intValue }
                if b["reset"] as? Bool == true { p = EditParams() }
                model.params = p
                model.recompute(immediately: true)
                return ("200 OK", "application/json", try JSONEncoder().encode(model.state))
            case ("POST", "/load"):
                let b = body(req)
                if let wav = b["wav"] as? String { try model.loadWAV(wav) }
                else if let text = b["say"] as? String {
                    try model.synthesize(text: text, ckpt: b["ckpt"] as? String, guidance: (b["guidance"] as? NSNumber)?.floatValue ?? 2, steps: (b["steps"] as? NSNumber)?.intValue ?? 16)
                } else if let layer = b["layer"] as? String { model.selectLayer(layer) }
                return ("200 OK", "application/json", try JSONEncoder().encode(model.state))
            case ("POST", "/vocoder"):
                let b = body(req)
                if let path = b["path"] as? String { try model.setVocoder(path: path) }
                else { model.setVocoder(b["name"] as? String ?? "vocos") }
                return ("200 OK", "application/json", try JSONEncoder().encode(model.state))
            case ("GET", "/models"):
                return ("200 OK", "application/json", try JSONEncoder().encode(model.models))
            case ("POST", "/models"):
                let b = body(req)
                if b["rescan"] as? Bool == true { model.rescanModels() }
                if b["download"] as? Bool == true { model.downloadWeights() }   // async; poll /state → weights.downloading
                if let v = b["vocoder"] as? String { try model.setVocoder(path: v) }
                if let c = b["ckpt"] as? String { try model.setCheckpoint(c) }
                return ("200 OK", "application/json", try JSONEncoder().encode(model.state))
            case ("POST", "/play"):
                model.play(original: (body(req)["which"] as? String) == "original")
                return ("200 OK", "application/json", json(["playing": true]))
            case ("POST", "/stop"):
                model.audio.stop(); if model.live { model.live = false }; return ("200 OK", "application/json", json(["playing": false]))
            case ("POST", "/pitch"):
                let b = body(req)
                if b["reset"] as? Bool == true { model.resetPitchCurve() }
                if let phone = (b["phone"] as? NSNumber)?.intValue, let hz = (b["hz"] as? NSNumber)?.floatValue {
                    model.setPitch(phone: phone, hz: hz, radius: (b["radius"] as? NSNumber)?.intValue ?? 1)
                }
                if let t = (b["scrub"] as? NSNumber)?.doubleValue { model.scrub(to: t) }
                if let e = b["editing"] as? Bool { model.editingPitch = e }
                if let ms = (b["break"] as? NSNumber)?.intValue { model.insertBreak(milliseconds: ms) }
                if let level = b["emphasis"] as? String { model.setEmphasis(level == "none" ? nil : level) }
                if b["commit"] as? Bool == true { model.commitToMarkup() }
                return ("200 OK", "application/json", try JSONEncoder().encode(model.state))
            case ("GET", "/pitch"):
                return ("200 OK", "application/json", json(["baseHz": model.baseHz.map(Double.init),
                                                            "editedHz": model.editedHz.map(Double.init),
                                                            "delta": model.pitchDelta.map(Double.init),
                                                            "phones": model.timeline.phones.map { ["symbol": $0.symbol, "start": $0.start, "length": $0.length] }]))
            case ("POST", "/view"):
                let b = body(req)
                if let v = b["showOriginal"] as? Bool { model.showOriginal = v }
                if let v = b["terrain3D"] as? Bool { model.terrain3D = v }
                if let v = b["live"] as? Bool, v != model.live { model.live = v }
                return ("200 OK", "application/json", try JSONEncoder().encode(model.state))
            case ("POST", "/export"):
                let written = try model.export(to: body(req)["dir"] as? String ?? "eval/mel-export")
                return ("200 OK", "application/json", json(["written": written]))
            default:
                return ("404 Not Found", "text/plain", Data("unknown route \(req.method) \(req.path)".utf8))
            }
        } catch {
            return ("500 Internal Server Error", "application/json", json(["error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription]))
        }
    }
}
