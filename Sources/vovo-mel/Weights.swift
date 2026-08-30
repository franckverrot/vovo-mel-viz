import Foundation

/// The published Vovo weights on the Hugging Face Hub, downloaded on demand into Application Support.
/// No token, no Python: plain HTTPS GETs of `https://huggingface.co/<repo>/resolve/main/<file>`.
enum HubWeights {
    static let repo = "franckverrot/vovo"
    static let files = ["model.safetensors", "vocoder.safetensors"]
    static let approxMB = 135

    /// `~/Library/Application Support/vovo-mel-viz/weights/franckverrot--vovo`
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("vovo-mel-viz/weights/\(repo.replacingOccurrences(of: "/", with: "--"))", isDirectory: true)
    }

    static var isInstalled: Bool { files.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) } }
    static var modelPath: String { directory.appendingPathComponent("model.safetensors").path }
    static var vocoderPath: String { directory.appendingPathComponent("vocoder.safetensors").path }

    static func url(for file: String) -> URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")! }

    /// Downloads every file that is missing. `progress` is called on the main thread with (fraction 0…1, message).
    static func download(progress: @escaping @MainActor (Double, String) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for (i, file) in files.enumerated() {
            let dest = directory.appendingPathComponent(file)
            if fm.fileExists(atPath: dest.path) { continue }
            let base = Double(i) / Double(files.count), span = 1 / Double(files.count)
            await progress(base, "downloading \(file)…")
            let (bytes, response) = try await URLSession.shared.bytes(from: url(for: file))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw NSError(domain: "HubWeights", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(file): HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"])
            }
            let total = Double(http.expectedContentLength)
            let tmp = dest.appendingPathExtension("part")
            fm.createFile(atPath: tmp.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tmp)
            var buffer = Data(); buffer.reserveCapacity(1 << 20)
            var written = 0, lastReport = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 20 {
                    handle.write(buffer); written += buffer.count; buffer.removeAll(keepingCapacity: true)
                    if written - lastReport >= 4 << 20 {
                        lastReport = written
                        let frac = total > 0 ? Double(written) / total : 0
                        await progress(base + span * frac, String(format: "%@ %.0f / %.0f MB", file, Double(written) / 1e6, total / 1e6))
                    }
                }
            }
            if !buffer.isEmpty { handle.write(buffer); written += buffer.count }
            try handle.close()
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
            await progress(base + span, "\(file) done")
        }
        await progress(1, "weights installed in \(directory.path)")
    }

    static func remove() { try? FileManager.default.removeItem(at: directory) }
}
