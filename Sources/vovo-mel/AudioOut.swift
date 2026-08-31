import AVFoundation
import Foundation

/// Plays Float32 24 kHz mono buffers: one-shot (`play`) or looped with hot-swapping (`startLoop`/`swap`).
/// The loop is an AVAudioSourceNode render callback reading a shared buffer; `swap` replaces the buffer
/// under a lock and crossfades from the old one over 20 ms at the current playhead, so a slider edit is
/// heard mid-sentence without a click and without restarting the utterance.
final class AudioOut {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var source: AVAudioSourceNode!
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private(set) var playing = false
    /// Where playback currently is, in seconds (loop position, or elapsed time for a one-shot take).
    var playhead: Double {
        if looping {
            os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
            return Double(pos) / 24000
        }
        guard playing, let start = oneShotStart else { return 0 }
        return min(Date().timeIntervalSince(start), oneShotSeconds)
    }
    private var oneShotStart: Date? = nil
    private var oneShotSeconds: Double = 0
    private(set) var looping = false

    // Loop state, guarded by `lock` (touched from the audio thread and the main thread).
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1); p.initialize(to: os_unfair_lock()); return p
    }()
    private var loopBuf: [Float] = []
    private var prevBuf: [Float] = []
    private var pos = 0
    private var fade = 0
    private let fadeLen = 480            // 20 ms crossfade on swap
    private let gap = 24000 * 4 / 10     // 0.4 s of silence between repeats

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        source = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, abl -> OSStatus in
            let out = UnsafeMutableAudioBufferListPointer(abl)[0].mData!.assumingMemoryBound(to: Float.self)
            let n = Int(frameCount)
            os_unfair_lock_lock(self.lock)
            defer { os_unfair_lock_unlock(self.lock) }
            guard self.looping, !self.loopBuf.isEmpty else { for i in 0..<n { out[i] = 0 }; return noErr }
            for i in 0..<n {
                var v = self.loopBuf[self.pos]
                if self.fade > 0 {
                    let p = self.pos < self.prevBuf.count ? self.prevBuf[self.pos] : 0
                    let a = Float(self.fade) / Float(self.fadeLen)
                    v = v * (1 - a) + p * a
                    self.fade -= 1
                }
                out[i] = v
                self.pos += 1
                if self.pos >= self.loopBuf.count { self.pos = 0; self.fade = 0 }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    func play(_ samples: [Float]) {
        stop()
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if !engine.isRunning { try? engine.start() }
        playing = true
        oneShotStart = Date(); oneShotSeconds = Double(samples.count) / 24000
        player.scheduleBuffer(buf, at: nil, options: []) { [weak self] in DispatchQueue.main.async { self?.playing = false; self?.oneShotStart = nil } }
        player.play()
    }

    func stop() { player.stop(); playing = false; oneShotStart = nil }

    /// Start looping `samples` from the beginning (stops one-shot playback).
    func startLoop(_ samples: [Float]) {
        stop()
        if !engine.isRunning { try? engine.start() }
        os_unfair_lock_lock(lock)
        loopBuf = samples + [Float](repeating: 0, count: gap); prevBuf = []; pos = 0; fade = 0; looping = true
        os_unfair_lock_unlock(lock)
    }

    /// Replace the looped audio at the current playhead (crossfaded). No-op unless looping.
    func swap(_ samples: [Float]) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard looping else { return }
        prevBuf = loopBuf
        loopBuf = samples + [Float](repeating: 0, count: gap)
        if pos >= loopBuf.count { pos = 0; fade = 0 } else { fade = fadeLen }
    }

    func stopLoop() {
        os_unfair_lock_lock(lock)
        looping = false; loopBuf = []; prevBuf = []; pos = 0; fade = 0
        os_unfair_lock_unlock(lock)
    }
}
