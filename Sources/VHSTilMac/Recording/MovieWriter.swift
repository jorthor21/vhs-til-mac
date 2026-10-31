import AVFoundation
import CoreMedia
import CoreVideo

enum RecorderError: LocalizedError {
    case unsupported(String)
    case cannotStart(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let s): return "Formatet støttes ikke på denne Mac-en: \(s)"
        case .cannotStart(let s): return "Kunne ikke starte opptaket: \(s)"
        }
    }
}

/// Én fil (MP4 eller MOV) skrevet med AVAssetWriter.
final class MovieWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private(set) var framesWritten = 0
    private(set) var framesNotReady = 0
    private(set) var audioBuffersWritten = 0
    private(set) var audioNotReady = 0
    private var lastVideoPTS = CMTime.negativeInfinity
    private var lastAudioEnd = CMTime.negativeInfinity

    var hasAudio: Bool { audioInput != nil }
    var failed: Error? { writer.status == .failed ? writer.error : nil }

    init(url: URL, fileType: AVFileType, video: [String: Any], fallbackVideo: [String: Any]?,
         audio: [String: Any]?, width: Int, height: Int, log: LogStore) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = fileType == .mp4

        var vSettings = video
        if !writer.canApply(outputSettings: vSettings, forMediaType: .video) {
            if let fb = fallbackVideo, writer.canApply(outputSettings: fb, forMediaType: .video) {
                log.warn("Videoinnstillinger ble forenklet for \(url.lastPathComponent).")
                vSettings = fb
            } else {
                throw RecorderError.unsupported("videokoding for \(fileType.rawValue)")
            }
        }
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vi.expectsMediaDataInRealTime = true
        guard writer.canAdd(vi) else { throw RecorderError.unsupported("videospor") }
        writer.add(vi)
        videoInput = vi
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr8,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])

        if let a = audio {
            if writer.canApply(outputSettings: a, forMediaType: .audio) {
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: a)
                ai.expectsMediaDataInRealTime = true
                if writer.canAdd(ai) { writer.add(ai); audioInput = ai } else { audioInput = nil }
            } else {
                audioInput = nil
            }
            if audioInput == nil { throw RecorderError.unsupported("lydspor i \(fileType.rawValue)") }
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else {
            throw RecorderError.cannotStart(writer.error?.localizedDescription ?? "ukjent feil")
        }
        writer.startSession(atSourceTime: .zero)
    }

    @discardableResult
    func append(video pb: CVPixelBuffer, at pts: CMTime) -> Bool {
        guard writer.status == .writing, CMTimeCompare(pts, lastVideoPTS) > 0 else { return false }
        guard videoInput.isReadyForMoreMediaData else { framesNotReady += 1; return false }
        if adaptor.append(pb, withPresentationTime: pts) {
            framesWritten += 1
            lastVideoPTS = pts
            return true
        }
        return false
    }

    @discardableResult
    func append(audio sb: CMSampleBuffer) -> Bool {
        guard let ai = audioInput, writer.status == .writing else { return false }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMTimeCompare(pts, lastAudioEnd) >= 0 || lastAudioEnd == .negativeInfinity else { return false }
        guard ai.isReadyForMoreMediaData else { audioNotReady += 1; return false }
        if ai.append(sb) {
            audioBuffersWritten += 1
            lastAudioEnd = CMTimeAdd(pts, CMSampleBufferGetDuration(sb))
            return true
        }
        return false
    }

    func finish(completion: @escaping (Error?) -> Void) {
        guard writer.status == .writing else {
            completion(writer.error ?? RecorderError.cannotStart("skriveren var ikke aktiv"))
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [writer] in
            completion(writer.status == .completed ? nil : writer.error)
        }
    }

    func cancel() {
        writer.cancelWriting()
    }
}

// MARK: - Innstillinger

enum WriterSettings {
    static func colorProperties(_ s: VideoStandard) -> [String: Any] {
        [
            AVVideoColorPrimariesKey: s == .pal ? AVVideoColorPrimaries_EBU_3213 : AVVideoColorPrimaries_SMPTE_C,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_601_4
        ]
    }

    static func pixelAspect(_ s: VideoStandard) -> [String: Any] {
        [
            AVVideoPixelAspectRatioHorizontalSpacingKey: s.pixelAspect.h,
            AVVideoPixelAspectRatioVerticalSpacingKey: s.pixelAspect.v
        ]
    }

    static func h264(_ s: VideoStandard, quality: VideoQuality, full: Bool) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: quality.bitrate,
            AVVideoMaxKeyFrameIntervalKey: Int(s.fps.rounded()) * 2
        ]
        if full {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoExpectedSourceFrameRateKey] = Int(s.fps.rounded())
            compression[AVVideoAllowFrameReorderingKey] = true
        }
        var d: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: s.width,
            AVVideoHeightKey: s.height,
            AVVideoCompressionPropertiesKey: compression
        ]
        if full {
            d[AVVideoPixelAspectRatioKey] = pixelAspect(s)
            d[AVVideoColorPropertiesKey] = colorProperties(s)
        }
        return d
    }

    static func proRes(_ s: VideoStandard, full: Bool) -> [String: Any] {
        var d: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes422,
            AVVideoWidthKey: s.width,
            AVVideoHeightKey: s.height
        ]
        if full {
            d[AVVideoPixelAspectRatioKey] = pixelAspect(s)
            d[AVVideoColorPropertiesKey] = colorProperties(s)
        }
        return d
    }

    static func aac(sampleRate: Double, channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels >= 2 ? 192_000 : 128_000
        ]
    }

    static func pcm24(sampleRate: Double, channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }
}
