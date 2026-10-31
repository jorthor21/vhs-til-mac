import AVFoundation
import CoreMedia
import CoreVideo

/// Ett opptak: MP4 (deinterlacet, H.264 + AAC) og eventuelt en arkivkopi
/// (linjeflettet ProRes 422 + 24-bit PCM i .mov).
///
/// Tidsstempler: bildene nummereres fortløpende (adapterens klokke). Hvis det
/// går mer enn to bildeperioder uten bilde (tap på USB), fylles hullet med
/// forrige bilde slik at lyd og bilde holder seg synkrone. Lyd tidsstemples
/// etter antall sampler, forankret i vertstid, og justeres bare fremover.
///
/// Alle metoder kalles på CaptureEngine.videoQueue (seriell).
final class RecordingSession {
    enum AudioMode {
        case none, adapter, mac(sampleRate: Double, channels: Int)
        var isNone: Bool { if case .none = self { return true }; return false }
    }

    let standard: VideoStandard
    let mp4: MovieWriter
    let archive: MovieWriter?
    let audioMode: AudioMode
    let log: LogStore
    let startedAt = Date()

    private var t0: Double?
    private var lastIndex = -1
    private var lastDisplay: CVPixelBuffer?
    private var lastRaw: CVPixelBuffer?
    private(set) var duplicatedFrames = 0
    private(set) var incompleteFrames = 0
    private var audioNext: Int64?           // neste samplenummer (48 kHz)
    private(set) var audioGaps = 0
    private(set) var audioSamples: Int64 = 0
    private var lastAudioHost: Double = 0
    private var adapterFormat: CMAudioFormatDescription?
    private var finished = false

    init(folder: URL, baseName: String, standard: VideoStandard, quality: VideoQuality,
         keepArchive: Bool, audioMode: AudioMode, log: LogStore) throws {
        self.standard = standard
        self.audioMode = audioMode
        self.log = log

        let mp4URL = RecordingSession.uniqueURL(folder: folder, base: baseName, ext: "mp4")
        let mp4Audio: [String: Any]?
        let movAudio: [String: Any]?
        switch audioMode {
        case .none:
            mp4Audio = nil; movAudio = nil
        case .adapter:
            mp4Audio = WriterSettings.aac(sampleRate: 48_000, channels: 2)
            movAudio = WriterSettings.pcm24(sampleRate: 48_000, channels: 2)
        case .mac(let rate, let ch):
            let c = max(1, min(2, ch))
            mp4Audio = WriterSettings.aac(sampleRate: rate, channels: c)
            movAudio = WriterSettings.pcm24(sampleRate: rate, channels: c)
        }

        mp4 = try MovieWriter(url: mp4URL, fileType: .mp4,
                              video: WriterSettings.h264(standard, quality: quality, full: true),
                              fallbackVideo: WriterSettings.h264(standard, quality: quality, full: false),
                              audio: mp4Audio, width: standard.width, height: standard.height, log: log)
        if keepArchive {
            let movURL = RecordingSession.uniqueURL(folder: folder, base: baseName + " (arkiv)", ext: "mov")
            do {
                archive = try MovieWriter(url: movURL, fileType: .mov,
                                          video: WriterSettings.proRes(standard, full: true),
                                          fallbackVideo: WriterSettings.proRes(standard, full: false),
                                          audio: movAudio, width: standard.width, height: standard.height, log: log)
            } catch {
                log.error("Arkivkopi (ProRes) kunne ikke startes: \(error.localizedDescription). Tar opp bare MP4.")
                archive = nil
            }
        } else {
            archive = nil
        }
        log.info("Opptak startet: \(mp4URL.path)" + (archive != nil ? " + arkivkopi" : ""))
    }

    static func uniqueURL(folder: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    var duration: Double { Double(max(0, lastIndex + 1)) / standard.fps }

    private func pts(for index: Int) -> CMTime {
        let fd = standard.frameDuration
        return CMTime(value: Int64(index) * fd.value, timescale: fd.timescale)
    }

    // MARK: Video

    func addVideo(raw: CVPixelBuffer, display: CVPixelBuffer, host: Double, complete: Bool) {
        guard !finished else { return }
        if !complete { incompleteFrames += 1 }
        let period = 1.0 / standard.fps
        if t0 == nil {
            t0 = host - period           // bildet er ferdig ved 'host', startet en periode før
            write(index: 0, raw: raw, display: display)
            return
        }
        var index = lastIndex + 1
        let expected = Int(((host - period - t0!) / period).rounded())
        if expected > index + 1 {
            let missing = min(expected - index, 25)
            if let pd = lastDisplay, let pr = lastRaw {
                for _ in 0..<missing {
                    write(index: index, raw: pr, display: pd)
                    index += 1
                    duplicatedFrames += 1
                }
            } else {
                index += missing
            }
            if missing > 2 { log.warn("Opptak: \(missing) bilder manglet (USB) – fylt med forrige bilde.") }
        }
        write(index: index, raw: raw, display: display)
    }

    private func write(index: Int, raw: CVPixelBuffer, display: CVPixelBuffer) {
        let t = pts(for: index)
        mp4.append(video: display, at: t)
        archive?.append(video: raw, at: t)
        lastIndex = index
        lastDisplay = display
        lastRaw = raw
    }

    // MARK: Lyd fra adapteren (32-bit stereo 48 kHz)

    func addAdapterAudio(_ samples: UnsafePointer<Int32>, frames: Int, host: Double) {
        guard !finished, case .adapter = audioMode, let t0 = t0, frames > 0 else { return }
        lastAudioHost = host
        let rate = 48_000.0
        let chunkStart = host - Double(frames) / rate - t0
        let startSample = Int64((chunkStart * rate).rounded())
        if audioNext == nil {
            audioNext = startSample
        } else if let next = audioNext {
            let drift = Double(startSample - next) / rate
            if drift > 0.25 {
                audioGaps += 1
                log.warn(String(format: "Opptak: lydhull på %.2f s (USB) – lyd justert.", drift))
                audioNext = startSample
            } else if drift < -0.5 {
                // Lyden ligger foran klokken; hopp over denne biten i stedet for å lage overlapp.
                return
            }
        }
        var first = 0
        var at = audioNext!
        if at < 0 {
            first = Int(-at)
            if first >= frames { audioNext = at + Int64(frames); return }
            at = 0
        }
        let count = frames - first
        guard let sb = makeAdapterSampleBuffer(samples + first * 2, frames: count, pts: CMTime(value: at, timescale: 48_000)) else { return }
        mp4.append(audio: sb)
        archive?.append(audio: sb)
        audioNext = at + Int64(count)
        audioSamples += Int64(count)
    }

    private func makeAdapterSampleBuffer(_ p: UnsafePointer<Int32>, frames: Int, pts: CMTime) -> CMSampleBuffer? {
        if adapterFormat == nil {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                           layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &adapterFormat)
        }
        guard let fmt = adapterFormat else { return nil }
        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: 0,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let bb = block,
              CMBlockBufferReplaceDataBytes(with: p, blockBuffer: bb, offsetIntoDestination: 0, dataLength: bytes) == kCMBlockBufferNoErr
        else { return nil }
        var sb: CMSampleBuffer?
        let st = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fmt,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb)
        return st == noErr ? sb : nil
    }

    // MARK: Lyd fra en annen inngang på Mac-en

    func addMacAudio(_ sb: CMSampleBuffer) {
        guard !finished, case .mac(_, _) = audioMode, let t0 = t0 else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isValid else { return }
        let rel = CMTimeSubtract(pts, CMTime(seconds: t0, preferredTimescale: 1_000_000_000))
        guard rel.seconds >= 0 else { return }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sb), presentationTimeStamp: rel,
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sb,
                                                    sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                    sampleBufferOut: &out) == noErr, let o = out else { return }
        mp4.append(audio: o)
        archive?.append(audio: o)
        audioSamples += Int64(CMSampleBufferGetNumSamples(o))
    }

    /// Sekunder siden siste lydblokk fra adapteren ble skrevet.
    func secondsSinceAdapterAudio(now: Double) -> Double { lastAudioHost == 0 ? .infinity : now - lastAudioHost }

    // MARK: Avslutt

    func finish(completion: @escaping ([URL], [String]) -> Void) {
        guard !finished else { return }
        finished = true
        var urls: [URL] = []
        var errors: [String] = []
        let group = DispatchGroup()
        let lock = NSLock()
        let summary = String(format: "Opptak avsluttet: %.1f s, %ld bilder (%ld fylt inn, %ld ufullstendige), %lld lydsampler, %ld lydhull",
                             duration, mp4.framesWritten, duplicatedFrames, incompleteFrames, audioSamples, audioGaps)
        log.info(summary)
        if mp4.framesNotReady > 0 || mp4.audioNotReady > 0 {
            log.warn("Koderen var opptatt: \(mp4.framesNotReady) bilder og \(mp4.audioNotReady) lydblokker ble ikke skrevet.")
        }
        for w in [mp4] + (archive.map { [$0] } ?? []) {
            group.enter()
            w.finish { err in
                lock.lock()
                if let err = err { errors.append("\(w.url.lastPathComponent): \(err.localizedDescription)") }
                else { urls.append(w.url) }
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls, errors) }
    }
}
