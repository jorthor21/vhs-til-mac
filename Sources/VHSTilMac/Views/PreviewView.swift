import SwiftUI
import AppKit
import AVFoundation
import CoreMedia

/// Tar imot bilder fra hvilken som helst tråd og viser dem i et AVSampleBufferDisplayLayer.
final class PreviewSink: ObservableObject {
    let layer = AVSampleBufferDisplayLayer()
    @Published var showNoSignal = true
    @Published var aspectStandard: VideoStandard = .pal

    init() {
        // Lagets innhold strekkes til rammen, og rammen holdes i 4:3 av SwiftUI.
        // Slik vises 720x576 (PAL) og 720x480 (NTSC) alltid med riktige proporsjoner.
        layer.videoGravity = .resize
        layer.backgroundColor = NSColor.black.cgColor
    }

    func enqueue(_ pb: CVPixelBuffer) {
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                     formatDescriptionOut: &fmt)
        guard let f = fmt else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sbOut: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                 formatDescription: f, sampleTiming: &timing,
                                                 sampleBufferOut: &sbOut)
        guard let sb = sbOut else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        DispatchQueue.main.async { [layer] in
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sb)
        }
    }

    func flush() {
        DispatchQueue.main.async { [layer] in layer.flushAndRemoveImage() }
    }
}

/// NSView som er vert for forhåndsvisningslaget.
final class PreviewHostView: NSView {
    private let videoLayer: AVSampleBufferDisplayLayer

    init(videoLayer: AVSampleBufferDisplayLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        wantsLayer = true
        root.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) brukes ikke") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}

struct VideoLayerView: NSViewRepresentable {
    let sink: PreviewSink
    func makeNSView(context: Context) -> PreviewHostView { PreviewHostView(videoLayer: sink.layer) }
    func updateNSView(_ nsView: PreviewHostView, context: Context) { nsView.needsLayout = true }
}

struct PreviewArea: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var sink: PreviewSink

    var body: some View {
        ZStack(alignment: .topLeading) {
            VideoLayerView(sink: sink)
            if sink.showNoSignal {
                overlay
            }
            if model.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                    Text("REC " + formatDuration(model.recordingElapsed))
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.black.opacity(0.6))
                .cornerRadius(6)
                .padding(10)
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .background(Color.black)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
        .accessibilityLabel("Forhåndsvisning av video")
    }

    private var overlay: some View {
        let (title, detail, icon) = overlayText
        return VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 42)).foregroundColor(.white.opacity(0.7))
            Text(title).font(.title2.weight(.semibold)).foregroundColor(.white)
            Text(detail).font(.callout).foregroundColor(.white.opacity(0.75))
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.55))
    }

    private var overlayText: (String, String, String) {
        switch model.usbState {
        case .notFound, .searching:
            return ("Ingen adapter", "Koble ezcap Video Grabber til en USB-port. Appen finner den automatisk.", "cable.connector")
        case .unsupported(let s):
            return ("Adapteren støttes ikke", s, "exclamationmark.triangle")
        case .found(_):
            break
        }
        if !model.previewEnabled {
            return ("Forhåndsvisning er av", "Slå på forhåndsvisning under Innstillinger → Avansert.", "pause.circle")
        }
        switch model.streamState {
        case .stopped, .starting:
            return ("Starter …", "Kobler til adapteren og starter videostrømmen.", "hourglass")
        case .failed(let s):
            return ("Videostrømmen kunne ikke startes", s, "exclamationmark.triangle")
        case .streaming:
            break
        }
        switch model.signalState {
        case .noData:
            return ("Ingen data fra adapteren", "Adapteren svarer, men sender ikke data. Kjør diagnosen og send rapporten.", "exclamationmark.triangle")
        case .noSync:
            return ("Ukjent videoformat", "Adapteren sender data, men appen finner ikke et gyldig bilde i dem. Lagre en diagnosepakke under Diagnose.", "questionmark.square.dashed")
        case .noSignal:
            return ("Ingen videosignal",
                    "Start avspilling på kameraet. Sjekk at den gule kabelen går fra kameraets VIDEO/AV OUT til adapterens gule plugg – eller prøv «Finn inngang med signal» under Diagnose.",
                    "play.rectangle")
        case .wrongStandard(let s):
            return ("Feil TV-standard", "Kameraet sender \(s). Bytt TV-standard under Innstillinger → Video.", "tv")
        case .unknown, .locked(_):
            return ("Venter på bilde …", "", "hourglass")
        }
    }
}

func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(t)
    return String(format: "%ld:%02ld:%02ld", s / 3600, (s / 60) % 60, s % 60)
}
