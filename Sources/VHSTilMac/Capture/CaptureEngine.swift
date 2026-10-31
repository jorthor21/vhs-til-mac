import Foundation
import QuartzCore
import CoreVideo
import CoreMedia
import SMICore

// MARK: - Tilstander som vises i brukergrensesnittet

enum USBState: Equatable {
    case searching
    case notFound
    case found(String)          // f.eks. "ezcap Video Grabber 1c88:1001"
    case unsupported(String)
}

enum StreamState: Equatable {
    case stopped
    case starting
    case streaming
    case failed(String)
}

enum SignalState: Equatable {
    case unknown
    case noData                 // ingen byte fra adapteren
    case noSync                 // data, men ingen BT.656-synk
    case noSignal               // dekoderen ser ikke noe videosignal
    case locked(String)         // signal låst
    case wrongStandard(String)  // signal, men feil TV-standard valgt
}

enum AdapterAudioState: Equatable {
    case off, waiting, receiving, missing
}

struct StreamMetrics: Equatable {
    var megabytesPerSecond: Double = 0
    var framesPerSecond: Double = 0
    var partialFramesPerSecond: Double = 0
    var linesField1: Int = 0
    var linesField2: Int = 0
    var isoErrors: UInt64 = 0
    var audioBlocksPerSecond: Double = 0
    var decoderStatus: UInt8? = nil
    var meanLuma: Double = 0
    var lumaSpread: Double = 0
    var droppedInApp: Int = 0
}

/// Konfigurasjon som sendes til C-kjernen.
struct CaptureConfig: Equatable {
    var standard: VideoStandard = .pal
    var input: VideoInput = .composite
    var compositeMode: Int = 0
    var adapterAudio: Bool = true
    var brightness: UInt8 = 0x80
    var contrast: UInt8 = 0x47
    var saturation: UInt8 = 0x40
    var hue: Int8 = 0
    var swapFields: Bool = false
    var deinterlace: Bool = true
}

// MARK: - C-callbacks (kan ikke fange kontekst – bruker user-pekeren)

private let smiLogCallback: smi_log_fn = { user, level, message in
    guard let user = user, let message = message else { return }
    let engine = Unmanaged<CaptureEngine>.fromOpaque(user).takeUnretainedValue()
    let text = String(cString: message)
    switch level {
    case 3: engine.log.error(text)
    case 2: engine.log.warn(text)
    case 1: engine.log.info(text)
    default: engine.log.debug(text)
    }
}

private let smiFrameCallback: smi_frame_fn = { user, info in
    guard let user = user, let info = info else { return }
    Unmanaged<CaptureEngine>.fromOpaque(user).takeUnretainedValue().handleFrame(info.pointee)
}

private let smiAudioCallback: smi_audio_fn = { user, samples, count in
    guard let user = user, let samples = samples, count > 0 else { return }
    Unmanaged<CaptureEngine>.fromOpaque(user).takeUnretainedValue().handleAudio(samples, Int(count))
}

// MARK: - Motoren

/// Eier USB-adapteren via C-kjernen (libusb), bygger CVPixelBuffer-bilder,
/// og leverer bilde og lyd videre til forhåndsvisning og opptak.
final class CaptureEngine {
    let log: LogStore

    /// Kalles på videokøen: (linjeflettet råbilde, bilde for visning/MP4, vertstid, komplett)
    var onVideo: ((CVPixelBuffer, CVPixelBuffer, Double, Bool) -> Void)?
    /// Kalles på videokøen med 32-bit stereo 48 kHz fra adapteren.
    var onAdapterAudio: ((UnsafePointer<Int32>, Int, Double) -> Void)?
    /// Statusendringer (kalles på hovedtråden).
    var onStateChange: ((USBState, StreamState, SignalState, AdapterAudioState, StreamMetrics) -> Void)?
    /// Adapteren forsvant under strømming (hovedtråden).
    var onDeviceLost: (() -> Void)?

    let videoQueue = DispatchQueue(label: "vhs.video", qos: .userInteractive)
    private let usbQueue = DispatchQueue(label: "vhs.usb", qos: .userInitiated)

    private var ctx: OpaquePointer?
    private var device: OpaquePointer?
    private var timer: DispatchSourceTimer?

    private(set) var config = CaptureConfig()
    private var wantsStreaming = false     // brukeren ønsker forhåndsvisning
    private var startFailures = 0
    private var nextStartAttempt = Date.distantPast

    // tilstand (endres kun på usbQueue)
    private var usbState: USBState = .searching
    private var streamState: StreamState = .stopped
    private var signalState: SignalState = .unknown
    private var audioState: AdapterAudioState = .off
    private var metrics = StreamMetrics()
    private var lastStats = smi_stream_stats()
    private var lastStatsTime = CACurrentMediaTime()
    private var streamStartTime = CACurrentMediaTime()
    private var tick = 0

    // bildebuffere (brukes på USB-tråden og videokøen)
    private let poolLock = NSLock()
    private var rawPool: CVPixelBufferPool?
    private var outPool: CVPixelBufferPool?
    private var poolHeight = 0
    private var inFlight = 0
    private var droppedInApp = 0
    private var frameCounter = 0
    private var lumaMean: Double = 0
    private var lumaSpread: Double = 0
    private var deinterlaceEnabled = true

    // siste bilde for diagnose (videokøen)
    private(set) var lastRawFrame: CVPixelBuffer?

    // rå USB-data for diagnose
    private var tapBuffer: UnsafeMutablePointer<UInt8>?
    private var tapCapacity = 0

    init(log: LogStore) {
        self.log = log
        let me = Unmanaged.passUnretained(self).toOpaque()
        ctx = smi_context_create(smiLogCallback, me)
        if ctx == nil { log.error("Kunne ikke starte USB-biblioteket (libusb).") }
    }

    deinit {
        timer?.cancel()
        if let d = device { smi_close(d) }
        if let c = ctx { smi_context_destroy(c) }
        tapBuffer?.deallocate()
    }

    // MARK: Offentlig API (trådsikkert – alt kjøres på usbQueue)

    func startMonitoring() {
        usbQueue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: usbQueue)
            t.schedule(deadline: .now() + 0.2, repeating: 1.0)
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            timer = t
        }
    }

    /// Ønsket tilstand: forhåndsvisning på/av. Motoren starter automatisk når adapteren dukker opp.
    func setPreviewWanted(_ wanted: Bool) {
        usbQueue.async { [self] in
            wantsStreaming = wanted
            startFailures = 0
            nextStartAttempt = .distantPast
            if wanted { poll() } else { stopStreaming(reason: "forhåndsvisning stoppet") }
        }
    }

    func apply(_ newConfig: CaptureConfig) {
        usbQueue.async { [self] in
            let old = config
            config = newConfig
            poolLock.lock(); deinterlaceEnabled = newConfig.deinterlace; poolLock.unlock()
            guard let d = device, smi_is_running(d) else { return }
            if old.standard != newConfig.standard {
                log.info("TV-standard endret til \(newConfig.standard == .pal ? "PAL" : "NTSC") – starter strømmen på nytt.")
                stopStreaming(reason: "bytte av TV-standard")
                startStreaming()
                return
            }
            if old.input != newConfig.input || old.compositeMode != newConfig.compositeMode {
                let r = smi_set_input(d, newConfig.input == .svideo ? SMI_INPUT_SVIDEO : SMI_INPUT_COMPOSITE,
                                      UInt8(clamping: newConfig.compositeMode))
                if r != 0 { log.warn("Bytte av inngang feilet: \(errorName(r))") }
            }
            if old.brightness != newConfig.brightness || old.contrast != newConfig.contrast ||
                old.saturation != newConfig.saturation || old.hue != newConfig.hue {
                _ = smi_set_picture(d, newConfig.brightness, newConfig.contrast, newConfig.saturation, newConfig.hue)
            }
            if old.adapterAudio != newConfig.adapterAudio {
                _ = smi_set_audio_enabled(d, newConfig.adapterAudio)
                audioState = newConfig.adapterAudio ? .waiting : .off
            }
            if old.swapFields != newConfig.swapFields { smi_set_swap_fields(d, newConfig.swapFields) }
        }
    }

    func shutdown() {
        usbQueue.sync {
            timer?.cancel(); timer = nil
            wantsStreaming = false
            stopStreaming(reason: "appen avsluttes")
        }
    }

    // MARK: Polling

    private func poll() {
        guard let ctx = ctx else { return }
        tick += 1

        if let d = device, smi_is_running(d) {
            updateStreamStatus(d)
            return
        }

        var p = smi_presence()
        let r = smi_find(ctx, &p)
        let newUSB: USBState
        if r == 0 && p.found {
            let id = String(format: "%04x:%04x", p.vendor_id, p.product_id)
            if p.product_id == 0x0007 {
                newUSB = .unsupported("Somagic \(id) trenger firmware og støttes ikke")
            } else {
                newUSB = .found(p.product_id == 0x1001 ? "ezcap Video Grabber (\(id))" : "Somagic-adapter (\(id))")
            }
            if p.speed != 3 && p.speed != 0 && tick % 30 == 1 {
                log.warn("Adapteren er ikke tilkoblet med USB 2.0 høyhastighet (speed=\(p.speed)). Prøv en annen port eller kabel.")
            }
        } else {
            newUSB = .notFound
        }
        if newUSB != usbState {
            switch newUSB {
            case .found(let s): log.info("USB: fant \(s)")
            case .notFound: log.info("USB: ingen Somagic-adapter funnet")
            case .unsupported(let s): log.warn("USB: \(s)")
            case .searching: break
            }
            usbState = newUSB
            if case .notFound = newUSB { streamState = .stopped; signalState = .unknown; audioState = .off }
        }
        if case .found(_) = usbState, wantsStreaming, Date() >= nextStartAttempt {
            startStreaming()
        }
        publish()
    }

    private func startStreaming() {
        guard let ctx = ctx else { return }
        streamState = .starting
        publish()

        if device == nil {
            var dev: OpaquePointer?
            let r = smi_open(ctx, &dev)
            if r != 0 || dev == nil {
                fail(start: "Kunne ikke åpne adapteren: \(friendlyError(r))")
                return
            }
            device = dev
        }
        guard let d = device else { return }

        var cfg = smi_config()
        smi_config_default(&cfg)
        cfg.standard = config.standard == .ntsc ? SMI_STD_NTSC : SMI_STD_PAL
        cfg.input = config.input == .svideo ? SMI_INPUT_SVIDEO : SMI_INPUT_COMPOSITE
        cfg.composite_mode = UInt8(clamping: config.compositeMode)
        cfg.enable_audio = config.adapterAudio
        cfg.brightness = config.brightness
        cfg.contrast = config.contrast
        cfg.saturation = config.saturation
        cfg.hue = config.hue
        cfg.swap_fields = config.swapFields

        preparePools(height: config.standard.height)
        if let tap = tapBuffer { smi_set_raw_tap(d, tap, tapCapacity) } else { smi_set_raw_tap(d, nil, 0) }

        let me = Unmanaged.passUnretained(self).toOpaque()
        let r = smi_start(d, &cfg, smiFrameCallback, smiAudioCallback, me)
        if r != 0 {
            smi_close(d)
            device = nil
            fail(start: "Kunne ikke starte videostrømmen: \(friendlyError(r))")
            return
        }
        startFailures = 0
        streamState = .streaming
        signalState = .unknown
        audioState = config.adapterAudio ? .waiting : .off
        lastStats = smi_stream_stats()
        lastStatsTime = CACurrentMediaTime()
        streamStartTime = lastStatsTime
        metrics = StreamMetrics()
        publish()
    }

    private func fail(start message: String) {
        startFailures += 1
        // Ikke prøv i det uendelige: 2 s, 4 s, 8 s ... maks 30 s mellom forsøk.
        let delay = min(30.0, pow(2.0, Double(min(startFailures, 5))))
        nextStartAttempt = Date().addingTimeInterval(delay)
        streamState = .failed(message)
        log.error(message + " (nytt forsøk om \(Int(delay)) s)")
        publish()
    }

    private func stopStreaming(reason: String) {
        if let d = device {
            if smi_is_running(d) { _ = smi_stop(d) }
            smi_close(d)
            device = nil
            log.info("Adapteren frigitt (\(reason)).")
        }
        if case .failed(_) = streamState {} else { streamState = .stopped }
        signalState = .unknown
        audioState = .off
        publish()
    }

    private func updateStreamStatus(_ d: OpaquePointer) {
        var s = smi_stream_stats()
        smi_get_stats(d, &s)
        let now = CACurrentMediaTime()
        let dt = max(0.001, now - lastStatsTime)

        if s.device_gone {
            log.error("Adapteren ble koblet fra under strømming.")
            stopStreaming(reason: "frakoblet")
            usbState = .notFound
            streamState = .failed("Adapteren ble koblet fra")
            publish()
            DispatchQueue.main.async { [weak self] in self?.onDeviceLost?() }
            return
        }

        let dBytes = Double(s.bytes_received &- lastStats.bytes_received)
        let dFrames = Double(s.parser.frames_complete &- lastStats.parser.frames_complete)
        let dPartial = Double(s.parser.frames_partial &- lastStats.parser.frames_partial)
        let dVideo = s.parser.video_blocks &- lastStats.parser.video_blocks
        let dTRC = s.parser.trc_valid &- lastStats.parser.trc_valid
        let dAudio = Double(s.parser.audio_blocks &- lastStats.parser.audio_blocks)

        metrics.megabytesPerSecond = dBytes / dt / 1e6
        metrics.framesPerSecond = dFrames / dt
        metrics.partialFramesPerSecond = dPartial / dt
        metrics.linesField1 = Int(s.parser.last_lines_field.0)
        metrics.linesField2 = Int(s.parser.last_lines_field.1)
        metrics.isoErrors = s.iso_packets_error
        metrics.audioBlocksPerSecond = dAudio / dt
        poolLock.lock()
        metrics.meanLuma = lumaMean
        metrics.lumaSpread = lumaSpread
        metrics.droppedInApp = droppedInApp
        poolLock.unlock()

        let running = now - streamStartTime
        if s.parser.unknown_blocks > lastStats.parser.unknown_blocks && tick % 10 == 0 {
            log.warn(String(format: "Ukjente datablokker mottatt (siste hode 0x%08x).", s.parser.last_unknown_header))
        }

        // Signalvurdering i tre trinn: data -> synk -> dekoderlås.
        if dBytes == 0 {
            signalState = running > 2 ? .noData : .unknown
        } else if dVideo > 0 && dTRC == 0 {
            signalState = .noSync
        } else if tick % 2 == 0 {
            var status: UInt8 = 0
            if smi_read_decoder_status(d, &status) == 0 {
                metrics.decoderStatus = status
                if status & 0x40 != 0 {
                    signalState = .noSignal
                } else {
                    let sixty = status & 0x20 != 0
                    let detected = sixty ? "NTSC 60 Hz" : "PAL 50 Hz"
                    if sixty != (config.standard == .ntsc) {
                        signalState = .wrongStandard(detected)
                    } else if dFrames > 0 {
                        signalState = .locked(detected)
                    } else {
                        signalState = .noSync
                    }
                }
            } else if dFrames > 0 {
                signalState = .locked("ukjent standard")
            }
        }

        if config.adapterAudio {
            if dAudio > 0 { audioState = .receiving }
            else if running > 3 { audioState = .missing }
            else { audioState = .waiting }
        } else {
            audioState = .off
        }

        if s.iso_packets_error > lastStats.iso_packets_error && tick % 5 == 0 {
            log.warn("USB-pakkefeil: \(s.iso_packets_error) totalt (siste status \(s.last_iso_status)). Prøv å koble adapteren direkte til Mac-en uten hub.")
        }

        lastStats = s
        lastStatsTime = now
        publish()
    }

    private func publish() {
        let u = usbState, st = streamState, sig = signalState, a = audioState, m = metrics
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(u, st, sig, a, m) }
    }

    // MARK: Bilder og lyd (USB-tråden)

    private func makePool(height: Int) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr8,
            kCVPixelBufferWidthKey as String: 720,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 6]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)
        return pool
    }

    private func preparePools(height: Int) {
        poolLock.lock()
        if poolHeight != height || rawPool == nil || outPool == nil {
            rawPool = makePool(height: height)
            outPool = makePool(height: height)
            poolHeight = height
        }
        deinterlaceEnabled = config.deinterlace
        poolLock.unlock()
    }

    private func attach(_ pb: CVPixelBuffer, interlaced: Bool, standard: VideoStandard) {
        let par: [String: Any] = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: standard.pixelAspect.h,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: standard.pixelAspect.v
        ]
        var a: [String: Any] = [
            kCVImageBufferPixelAspectRatioKey as String: par,
            kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_601_4,
            kCVImageBufferColorPrimariesKey as String:
                (standard == .pal ? kCVImageBufferColorPrimaries_EBU_3213 : kCVImageBufferColorPrimaries_SMPTE_C),
            kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferFieldCountKey as String: interlaced ? 2 : 1
        ]
        if interlaced {
            a[kCVImageBufferFieldDetailKey as String] = kCVImageBufferFieldDetailTemporalTopFirst
        }
        CVBufferSetAttachments(pb, a as CFDictionary, .shouldPropagate)
    }

    fileprivate func handleFrame(_ info: smi_frame_info) {
        let host = CACurrentMediaTime()
        poolLock.lock()
        guard let rawPool = rawPool, let outPool = outPool, Int(info.height) == poolHeight else {
            poolLock.unlock(); return
        }
        if inFlight >= 4 {           // videokøen henger etter – dropp heller enn å bygge kø
            droppedInApp += 1
            poolLock.unlock()
            return
        }
        inFlight += 1
        let deint = deinterlaceEnabled
        frameCounter += 1
        let measure = frameCounter % 12 == 0
        poolLock.unlock()

        var rawOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, rawPool, &rawOut)
        guard let raw = rawOut, let src = info.data else { finishFrame(); return }

        let h = Int(info.height)
        CVPixelBufferLockBaseAddress(raw, [])
        if let base = CVPixelBufferGetBaseAddress(raw) {
            let bpr = CVPixelBufferGetBytesPerRow(raw)
            for y in 0..<h {
                memcpy(base + y * bpr, src + y * Int(info.stride), 1440)
            }
        }
        CVPixelBufferUnlockBaseAddress(raw, [])

        if measure {
            var m = 0.0, sd = 0.0
            smi_uyvy_luma_stats(src, Int(info.stride), 720, Int32(h), &m, &sd)
            poolLock.lock(); lumaMean = m; lumaSpread = sd; poolLock.unlock()
        }

        let standard: VideoStandard = h == 480 ? .ntsc : .pal
        let complete = info.complete
        videoQueue.async { [weak self] in
            guard let self = self else { return }
            self.attach(raw, interlaced: true, standard: standard)
            var display = raw
            if deint {
                var o: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outPool, &o)
                if let out = o {
                    CVPixelBufferLockBaseAddress(raw, .readOnly)
                    CVPixelBufferLockBaseAddress(out, [])
                    if let s = CVPixelBufferGetBaseAddress(raw), let d = CVPixelBufferGetBaseAddress(out) {
                        smi_deinterlace_uyvy(s.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRow(raw),
                                             d.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRow(out),
                                             720, Int32(h), 144)
                    }
                    CVPixelBufferUnlockBaseAddress(out, [])
                    CVPixelBufferUnlockBaseAddress(raw, .readOnly)
                    self.attach(out, interlaced: false, standard: standard)
                    display = out
                }
            }
            self.lastRawFrame = raw
            self.onVideo?(raw, display, host, complete)
            self.finishFrame()
        }
    }

    private func finishFrame() {
        poolLock.lock(); inFlight -= 1; poolLock.unlock()
    }

    fileprivate func handleAudio(_ samples: UnsafePointer<Int32>, _ frames: Int) {
        let host = CACurrentMediaTime()
        // Kopier, fordi C-bufferen gjenbrukes straks.
        let copy = Array(UnsafeBufferPointer(start: samples, count: frames * 2))
        videoQueue.async { [weak self] in
            copy.withUnsafeBufferPointer { p in
                if let base = p.baseAddress { self?.onAdapterAudio?(base, frames, host) }
            }
        }
    }

    // MARK: Diagnose

    func describeDevices(completion: @escaping (String) -> Void) {
        usbQueue.async { [self] in
            guard let ctx = ctx else { completion("USB-biblioteket er ikke tilgjengelig."); return }
            let bufSize = 128 * 1024
            var buf = [CChar](repeating: 0, count: bufSize)
            _ = smi_describe(ctx, &buf, bufSize)
            var text = String(cString: buf)
            if device == nil {
                let accSize = 8 * 1024
                var acc = [CChar](repeating: 0, count: accSize)
                _ = smi_test_access(ctx, &acc, accSize)
                text += "\n" + String(cString: acc)
            } else {
                text += "\nTilgangstest: hoppet over – appen bruker allerede adapteren (forhåndsvisning).\n"
            }
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// Strømmetest: kjører (eller starter) strømmen i 'seconds' sekunder med rå USB-opptak,
    /// og returnerer en tekstrapport og de første megabytene rådata.
    func runStreamTest(seconds: Int, completion: @escaping (String, Data) -> Void) {
        usbQueue.async { [self] in
            var lines: [String] = []
            let wasStreaming = isRunning
            if wasStreaming { stopStreaming(reason: "strømmetest") }
            tapCapacity = 6 * 1024 * 1024
            tapBuffer?.deallocate()
            tapBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: tapCapacity)
            startStreaming()
            guard let d = device, smi_is_running(d) else {
                lines.append("Strømmetest: kunne ikke starte strømmen. Se loggen.")
                tapBuffer?.deallocate(); tapBuffer = nil; tapCapacity = 0
                DispatchQueue.main.async { completion(lines.joined(separator: "\n"), Data()) }
                return
            }
            lines.append("Strømmetest \(seconds) s – \(config.standard == .pal ? "PAL" : "NTSC"), \(config.input == .svideo ? "S-Video" : "kompositt (modus \(config.compositeMode))"), lyd fra adapter: \(config.adapterAudio ? "på" : "av")")
            var prev = smi_stream_stats()
            var gone = false
            for sec in 1...max(1, seconds) {
                Thread.sleep(forTimeInterval: 1.0)
                var s = smi_stream_stats()
                smi_get_stats(d, &s)
                if s.device_gone { gone = true; lines.append("Adapteren ble koblet fra under testen."); break }
                var status: UInt8 = 0
                let sr = smi_read_decoder_status(d, &status)
                let statusText = sr != 0 ? "lesefeil (\(errorName(sr)))" :
                    String(format: "0x%02x %@", status, (status & 0x40) != 0 ? "INGEN SIGNAL" : ((status & 0x20) != 0 ? "låst 60 Hz" : "låst 50 Hz"))
                lines.append(String(format: "t=%2ld s  %.2f MB/s  iso ok %llu feil %llu tomme %llu | blokker video %llu lyd %llu ukjent %llu | TRC %llu (ugyldige %llu) | rammer %llu (+%llu delvise) | linjer %u/%u | dekoder %@",
                                    sec,
                                    Double(s.bytes_received &- prev.bytes_received) / 1e6,
                                    s.iso_packets_ok, s.iso_packets_error, s.iso_packets_empty,
                                    s.parser.video_blocks, s.parser.audio_blocks, s.parser.unknown_blocks,
                                    s.parser.trc_valid, s.parser.trc_invalid,
                                    s.parser.frames_complete, s.parser.frames_partial,
                                    s.parser.last_lines_field.0, s.parser.last_lines_field.1,
                                    statusText))
                prev = s
            }
            if gone {
                stopStreaming(reason: "frakoblet under strømmetest")
                tapBuffer?.deallocate(); tapBuffer = nil; tapCapacity = 0
                DispatchQueue.main.async { completion(lines.joined(separator: "\n"), Data()) }
                return
            }
            let h = prev.parser.trc_histogram
            lines.append("TRC-fordeling: 80=\(h.0) 9d=\(h.1) ab=\(h.2) b6=\(h.3) c7=\(h.4) da=\(h.5) ec=\(h.6) f1=\(h.7)")
            lines.append("Maks linjer per felt: \(prev.parser.max_lines_field.0)/\(prev.parser.max_lines_field.1), lange linjer \(prev.parser.long_lines), korte linjer \(prev.parser.short_lines), brudd \(prev.parser.discontinuities)")
            lines.append("Lydsampler: \(prev.parser.audio_sample_frames), omjusteringer: \(prev.parser.audio_realign)")
            if prev.parser.unknown_blocks > 0 {
                lines.append(String(format: "Siste ukjente blokkhode: 0x%08x", prev.parser.last_unknown_header))
            }
            for reg: UInt8 in [0x00, 0x02, 0x08, 0x0e, 0x10, 0x1e, 0x1f] {
                var v: UInt8 = 0
                if smi_read_decoder_register(d, reg, &v) == 0 {
                    lines.append(String(format: "Dekoder reg 0x%02x = 0x%02x", reg, v))
                }
            }
            let n = smi_raw_tap_length(d)
            var data = Data()
            if let tap = tapBuffer, n > 0 { data = Data(bytes: tap, count: n) }
            lines.append("Rå USB-data lagret: \(n) byte (format: [uint16 lengde LE][pakkedata] per isokron pakke)")
            stopStreaming(reason: "strømmetest ferdig")
            tapBuffer?.deallocate(); tapBuffer = nil; tapCapacity = 0
            if wasStreaming || wantsStreaming { startStreaming() }
            DispatchQueue.main.async { completion(lines.joined(separator: "\n"), data) }
        }
    }

    /// Går gjennom alle kompositt-kanaler og S-Video og ser hvor dekoderen låser på et signal.
    func searchInputs(completion: @escaping (String, (VideoInput, Int)?) -> Void) {
        usbQueue.async { [self] in
            if !isRunning { startStreaming() }
            guard let d = device, smi_is_running(d) else {
                DispatchQueue.main.async { completion("Strømmen kjører ikke – kan ikke søke etter signal.", nil) }
                return
            }
            var lines = ["Søker etter videosignal på alle innganger (ca. 1,5 s per inngang):"]
            var found: (VideoInput, Int)?
            let candidates: [(VideoInput, Int)] = [(.composite, 0), (.composite, 1), (.composite, 2), (.composite, 3),
                                                   (.composite, 4), (.composite, 5), (.svideo, 0)]
            for (inp, mode) in candidates {
                _ = smi_set_input(d, inp == .svideo ? SMI_INPUT_SVIDEO : SMI_INPUT_COMPOSITE, UInt8(mode))
                Thread.sleep(forTimeInterval: 1.5)
                var status: UInt8 = 0
                let r = smi_read_decoder_status(d, &status)
                let locked = r == 0 && (status & 0x40) == 0
                let name = inp == .svideo ? "S-Video" : "Kompositt modus \(mode)"
                lines.append(String(format: "  %@: %@", name, r != 0 ? "lesefeil" : (locked ? String(format: "SIGNAL (status 0x%02x)", status) : String(format: "ingen signal (0x%02x)", status))))
                if locked && found == nil { found = (inp, mode) }
            }
            // Tilbake til valgt (eller funnet) inngang.
            let target = found ?? (config.input, config.compositeMode)
            _ = smi_set_input(d, target.0 == .svideo ? SMI_INPUT_SVIDEO : SMI_INPUT_COMPOSITE, UInt8(target.1))
            if let f = found {
                lines.append("Første inngang med signal: \(f.0 == .svideo ? "S-Video" : "Kompositt modus \(f.1)").")
            } else {
                lines.append("Fant ikke signal på noen inngang. Kontroller kabel, at kameraet spiller av, og at kameraet er satt til avspilling (VCR/PLAY).")
            }
            DispatchQueue.main.async { completion(lines.joined(separator: "\n"), found) }
        }
    }

    // MARK: Hjelpere

    private var isRunning: Bool {
        guard let d = device else { return false }
        return smi_is_running(d)
    }

    func errorName(_ code: Int32) -> String { String(cString: smi_error_name(code)) }

    func friendlyError(_ code: Int32) -> String {
        let name = errorName(code)
        switch name {
        case "LIBUSB_ERROR_ACCESS":
            return "ingen tilgang (\(name)). Et annet program kan bruke adapteren – lukk andre opptaksprogrammer og prøv igjen."
        case "LIBUSB_ERROR_BUSY":
            return "adapteren er opptatt (\(name)). Lukk andre programmer som bruker den, eller koble den fra og til."
        case "LIBUSB_ERROR_NO_DEVICE", "SMI_ERR_NOT_FOUND":
            return "adapteren ble ikke funnet (\(name))."
        case "LIBUSB_ERROR_NO_MEM", "LIBUSB_ERROR_INSUFFICIENT_RESOURCES":
            return "for lite USB-båndbredde (\(name)). Koble adapteren direkte til Mac-en, uten hub."
        case "LIBUSB_ERROR_TIMEOUT", "LIBUSB_ERROR_PIPE", "LIBUSB_ERROR_IO":
            return "adapteren svarte ikke riktig på kommandoene (\(name)). Koble den fra og til igjen."
        case "SMI_ERR_BAD_DESCRIPTOR":
            return "uventet USB-struktur (\(name)). Kjør diagnosen og send rapporten."
        default:
            return name
        }
    }

    var coreVersion: String { String(cString: smi_version()) }
}
