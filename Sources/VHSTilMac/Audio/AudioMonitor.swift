import AVFoundation

/// Spiller av lyden fra adapteren i sanntid (lyttemodus) via Mac-ens standard lydutgang.
final class AudioMonitor {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let chunkFrames: AVAudioFrameCount = 1024    // ca. 21 ms
    private var pending: AVAudioPCMBuffer?
    private let lock = NSLock()
    private let counterLock = NSLock()   // eget lås: fullføringsblokker kan kalles mens 'lock' holdes
    private var queued = 0
    private var running = false
    private let log: LogStore

    var volume: Float = 0.8 { didSet { player.volume = volume } }

    init(log: LogStore) {
        self.log = log
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        do {
            engine.prepare()
            try engine.start()
            player.volume = volume
            player.play()
            running = true
        } catch {
            log.warn("Lyttemodus kunne ikke starte lydutgangen: \(error.localizedDescription)")
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        player.stop()
        engine.stop()
        running = false
        counterLock.lock(); queued = 0; counterLock.unlock()
        pending = nil
    }

    /// Mottar 32-bit heltall, flettet stereo (L R L R …).
    func feed(_ samples: UnsafePointer<Int32>, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        var i = 0
        while i < frames {
            if pending == nil {
                pending = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
                pending?.frameLength = 0
            }
            guard let buf = pending, let ch = buf.floatChannelData else { return }
            let start = Int(buf.frameLength)
            let n = min(frames - i, Int(chunkFrames) - start)
            let scale: Float = 1.0 / 2_147_483_648.0
            for k in 0..<n {
                ch[0][start + k] = Float(samples[(i + k) * 2]) * scale
                ch[1][start + k] = Float(samples[(i + k) * 2 + 1]) * scale
            }
            buf.frameLength = AVAudioFrameCount(start + n)
            i += n
            if buf.frameLength == chunkFrames {
                pending = nil
                // Hold forsinkelsen nede: maks ca. 0,2 s i kø.
                counterLock.lock()
                let canQueue = queued < 10
                if canQueue { queued += 1 }
                counterLock.unlock()
                if canQueue {
                    player.scheduleBuffer(buf) { [weak self] in
                        guard let self = self else { return }
                        self.counterLock.lock(); self.queued = max(0, self.queued - 1); self.counterLock.unlock()
                    }
                }
            }
        }
    }
}
