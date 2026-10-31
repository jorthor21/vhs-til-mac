import Foundation
import AppKit
import AVFoundation
import Combine
import CoreVideo

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Samler adapter, forhåndsvisning, opptak, lyd og innstillinger.
final class AppModel: ObservableObject {
    let settings = AppSettings()
    let log = LogStore()
    let history = HistoryStore()
    let preview = PreviewSink()
    lazy var engine = CaptureEngine(log: log)
    lazy var monitor = AudioMonitor(log: log)
    lazy var macAudio = MacAudioInput(log: log)

    @Published var usbState: USBState = .searching
    @Published var streamState: StreamState = .stopped
    @Published var signalState: SignalState = .unknown
    @Published var adapterAudioState: AdapterAudioState = .off
    @Published var metrics = StreamMetrics()
    @Published var previewEnabled = true

    @Published private(set) var isRecording = false
    @Published private(set) var isFinishing = false
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published private(set) var recordingFileName = ""
    @Published private(set) var recordingBytes: Int64 = 0
    @Published private(set) var recordingWarning: String?
    @Published var alert: AppAlert?
    @Published var macAudioDevices: [MacAudioInput.Device] = []
    @Published var macAudioError: String?

    private var session: RecordingSession?          // brukes på engine.videoQueue
    private var recordingURL: URL?
    private var recordingStart = Date()
    private var uiTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var lastConfig: CaptureConfig?
    private var lastFrameHost: Double = 0

    init() {
        log.info("VHS til Mac \(Bundle.main.appVersion) startet på \(SystemInfo.summary)")
        wireEngine()
        settings.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.uiTick() }
        refreshMacAudioDevices()
        settingsChanged()
        engine.setPreviewWanted(true)
        engine.startMonitoring()
        history.refresh(folder: settings.outputFolder)
    }

    // MARK: Oppkobling

    private func wireEngine() {
        engine.onStateChange = { [weak self] usb, stream, signal, audio, m in
            guard let self = self else { return }
            if self.usbState != usb { self.usbState = usb }
            if self.streamState != stream { self.streamState = stream; self.updateAudioRouting() }
            if self.signalState != signal { self.signalState = signal }
            if self.adapterAudioState != audio { self.adapterAudioState = audio }
            self.metrics = m
            let noSignal = !self.hasPicture
            if self.preview.showNoSignal != noSignal { self.preview.showNoSignal = noSignal }
        }
        engine.onVideo = { [weak self] raw, display, host, complete in
            guard let self = self else { return }
            self.lastFrameHost = host
            self.preview.enqueue(display)
            self.session?.addVideo(raw: raw, display: display, host: host, complete: complete)
        }
        engine.onAdapterAudio = { [weak self] samples, frames, host in
            guard let self = self else { return }
            self.monitor.feed(samples, frames: frames)
            self.session?.addAdapterAudio(samples, frames: frames, host: host)
        }
        engine.onDeviceLost = { [weak self] in
            guard let self = self else { return }
            if self.isRecording {
                self.stopRecording()
                self.alert = AppAlert(title: "Adapteren ble koblet fra",
                                      message: "Opptaket er stoppet og lagret frem til tidspunktet adapteren forsvant.")
            }
        }
        macAudio.onSample = { [weak self] sb in
            guard let self = self else { return }
            self.engine.videoQueue.async { self.session?.addMacAudio(sb) }
        }
    }

    var hasPicture: Bool {
        if case .locked(_) = signalState { return true }
        if case .wrongStandard(_) = signalState { return metrics.framesPerSecond > 1 }
        return false
    }

    // MARK: Innstillinger

    private func makeConfig() -> CaptureConfig {
        var c = CaptureConfig()
        c.standard = settings.standard
        c.input = settings.input
        c.compositeMode = settings.compositeMode
        c.adapterAudio = settings.audioSource == .adapter
        c.brightness = UInt8(clamping: Int(settings.brightness.rounded()))
        c.contrast = UInt8(clamping: Int(settings.contrast.rounded()))
        c.saturation = UInt8(clamping: Int(settings.saturation.rounded()))
        c.hue = Int8(clamping: Int(settings.hue.rounded()))
        c.swapFields = settings.swapFields
        c.deinterlace = settings.deinterlace
        return c
    }

    func settingsChanged() {
        let c = makeConfig()
        if c != lastConfig {
            if isRecording, let l = lastConfig, c.standard != l.standard || c.adapterAudio != l.adapterAudio {
                // Ikke bytt format midt i et opptak.
                log.warn("TV-standard og lydkilde kan ikke endres under opptak.")
            } else {
                lastConfig = c
                engine.apply(c)
            }
        }
        preview.aspectStandard = settings.standard
        monitor.volume = Float(settings.monitorVolume)
        updateAudioRouting()
        history.refresh(folder: settings.outputFolder)
    }

    private func updateAudioRouting() {
        let wantMonitor = settings.monitorAudio && settings.audioSource == .adapter && streamState == .streaming
        if wantMonitor { monitor.start() } else { monitor.stop() }

        if settings.audioSource == .mac {
            let id = settings.macAudioDeviceID.isEmpty ? (macAudioDevices.first?.id ?? "") : settings.macAudioDeviceID
            if macAudio.currentDeviceID != id || !macAudio.isRunning {
                switch MacAudioInput.permission {
                case .authorized:
                    macAudioError = macAudio.start(deviceID: id)
                case .notDetermined:
                    MacAudioInput.requestPermission { [weak self] ok in
                        guard let self = self else { return }
                        if ok { self.macAudioError = self.macAudio.start(deviceID: id) }
                        else { self.macAudioError = "Mikrofontilgang ble avslått. Slå den på i Systeminnstillinger → Personvern og sikkerhet → Mikrofon." }
                    }
                default:
                    macAudioError = "Mikrofontilgang er avslått. Slå den på i Systeminnstillinger → Personvern og sikkerhet → Mikrofon."
                }
            }
        } else if macAudio.isRunning {
            macAudio.stop()
            macAudioError = nil
        }
    }

    func refreshMacAudioDevices() {
        macAudioDevices = MacAudioInput.availableDevices()
    }

    func setPreview(_ on: Bool) {
        previewEnabled = on
        engine.setPreviewWanted(on)
        if !on { preview.flush() }
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = "Velg mappe"
        p.message = "Velg mappen der VHS-opptakene skal lagres"
        p.directoryURL = settings.outputFolder
        if p.runModal() == .OK, let url = p.url {
            settings.outputFolderPath = url.path
            log.info("Opptaksmappe: \(url.path)")
        }
    }

    func openFolder() {
        let f = settings.outputFolder
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        NSWorkspace.shared.open(f)
    }

    // MARK: Opptak

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard !isRecording, !isFinishing else { return }
        guard streamState == .streaming else {
            alert = AppAlert(title: "Ingen video", message: "Videostrømmen fra adapteren kjører ikke. Sjekk at adapteren er koblet til, og se Status øverst.")
            return
        }
        if !hasPicture {
            let a = NSAlert()
            a.messageText = "Ingen videosignal"
            a.informativeText = "Adapteren ser ikke noe videosignal akkurat nå. Start avspilling på kameraet og sjekk kabelen. Vil du starte opptaket likevel?"
            a.addButton(withTitle: "Avbryt")
            a.addButton(withTitle: "Ta opp likevel")
            if a.runModal() == .alertFirstButtonReturn { return }
        }

        var audioMode: RecordingSession.AudioMode = .none
        switch settings.audioSource {
        case .none:
            audioMode = .none
        case .adapter:
            if adapterAudioState != .receiving {
                let a = NSAlert()
                a.messageText = "Adapteren sender ikke lyd"
                a.informativeText = "Appen har ikke mottatt lyd fra adapteren de siste sekundene. Du kan ta opp uten lyd, eller velge en annen lydinngang på Mac-en under Lyd."
                a.addButton(withTitle: "Avbryt")
                a.addButton(withTitle: "Ta opp uten lyd")
                if a.runModal() == .alertFirstButtonReturn { return }
                audioMode = .none
            } else {
                audioMode = .adapter
            }
        case .mac:
            guard macAudio.isRunning, let f = macAudio.format else {
                alert = AppAlert(title: "Mac-lydinngangen er ikke klar",
                                 message: macAudioError ?? "Velg en lydinngang under Lyd, eller velg «Ingen lyd».")
                return
            }
            audioMode = .mac(sampleRate: f.mSampleRate, channels: Int(f.mChannelsPerFrame))
        }

        let folder = settings.outputFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            alert = AppAlert(title: "Kan ikke lagre", message: "Mappen \(folder.path) kan ikke opprettes: \(error.localizedDescription)")
            return
        }
        if let free = HistoryStore.freeSpace(at: folder), free < 2_000_000_000 {
            alert = AppAlert(title: "For lite ledig plass",
                             message: "Det er bare \(HistoryStore.size(free)) ledig. Frigjør plass eller velg en annen mappe.")
            return
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'kl.' HH.mm.ss"
        let base = "VHS \(df.string(from: Date()))"
        do {
            let s = try RecordingSession(folder: folder, baseName: base, standard: settings.standard,
                                         quality: settings.quality, keepArchive: settings.keepArchive,
                                         audioMode: audioMode, log: log)
            recordingURL = s.mp4.url
            recordingFileName = s.mp4.url.lastPathComponent
            engine.videoQueue.sync { self.session = s }
            recordingStart = Date()
            recordingElapsed = 0
            recordingBytes = 0
            recordingWarning = audioMode.isNone ? "Tar opp uten lyd" : nil
            isRecording = true
        } catch {
            alert = AppAlert(title: "Opptaket kunne ikke starte", message: error.localizedDescription)
            log.error("Opptak kunne ikke starte: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        isFinishing = true
        engine.videoQueue.async { [weak self] in
            guard let self = self else { return }
            guard let s = self.session else {
                DispatchQueue.main.async { self.isFinishing = false }
                return
            }
            self.session = nil
            s.finish { urls, errors in
                self.isFinishing = false
                if !errors.isEmpty {
                    self.alert = AppAlert(title: "Problem ved lagring", message: errors.joined(separator: "\n"))
                    self.log.error("Lagring: \(errors.joined(separator: "; "))")
                }
                for u in urls { self.log.info("Lagret: \(u.path)") }
                self.history.refresh(folder: self.settings.outputFolder)
            }
        }
    }

    /// Brukes når appen avsluttes: venter (maks 10 s) til filene er ferdigskrevet.
    func finishForQuit(_ done: @escaping () -> Void) {
        if isRecording {
            stopRecording()
        }
        let deadline = Date().addingTimeInterval(10)
        func wait() {
            if !isFinishing || Date() > deadline {
                monitor.stop(); macAudio.stop(); engine.shutdown(); done()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { wait() }
            }
        }
        wait()
    }

    private func uiTick() {
        guard isRecording else { return }
        recordingElapsed = Date().timeIntervalSince(recordingStart)
        if let u = recordingURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
           let size = attrs[.size] as? NSNumber {
            recordingBytes = size.int64Value
        }
        if settings.audioSource == .adapter, adapterAudioState == .missing {
            recordingWarning = "Lyden fra adapteren har stoppet"
        } else if case .noSignal = signalState {
            recordingWarning = "Ingen videosignal"
        } else if recordingWarning != "Tar opp uten lyd" {
            recordingWarning = nil
        }
        if let free = HistoryStore.freeSpace(at: settings.outputFolder), free < 500_000_000 {
            log.error("Disken er nesten full – opptaket stoppes.")
            stopRecording()
            alert = AppAlert(title: "Disken er full", message: "Opptaket ble stoppet fordi det er mindre enn 500 MB ledig.")
        }
    }

    // MARK: Tekst for status

    var usbText: (String, StatusLevel) {
        switch usbState {
        case .searching: return ("Søker etter adapter …", .neutral)
        case .notFound: return ("Ikke funnet – koble til ezcap-adapteren", .bad)
        case .found(let s): return (s, .good)
        case .unsupported(let s): return (s, .bad)
        }
    }

    var streamText: (String, StatusLevel) {
        switch streamState {
        case .stopped: return (previewEnabled ? "Venter på adapter" : "Stoppet", .neutral)
        case .starting: return ("Starter videostrøm …", .neutral)
        case .streaming: return (String(format: "Strømmer – %.1f MB/s", metrics.megabytesPerSecond),
                                 metrics.megabytesPerSecond > 1 ? .good : .warn)
        case .failed(let s): return (s, .bad)
        }
    }

    var signalText: (String, StatusLevel) {
        guard streamState == .streaming else { return ("–", .neutral) }
        switch signalState {
        case .unknown: return ("Undersøker …", .neutral)
        case .noData: return ("Ingen data fra adapteren", .bad)
        case .noSync: return ("Data mottas, men uten gyldig bilde", .bad)
        case .noSignal: return ("Ingen videosignal – start avspilling på kameraet", .warn)
        case .locked(let s): return (String(format: "Signal: %@, %.0f bilder/s", s, metrics.framesPerSecond), .good)
        case .wrongStandard(let s): return ("Signalet er \(s) – bytt TV-standard", .warn)
        }
    }

    var audioText: (String, StatusLevel) {
        switch settings.audioSource {
        case .none: return ("Lyd av", .neutral)
        case .mac:
            if let e = macAudioError { return (e, .bad) }
            return (macAudio.isRunning ? "Mac-lydinngang aktiv" : "Mac-lydinngang ikke startet", macAudio.isRunning ? .good : .warn)
        case .adapter:
            switch adapterAudioState {
            case .off: return ("–", .neutral)
            case .waiting: return ("Venter på lyd fra adapteren …", .neutral)
            case .receiving: return ("Lyd mottas fra adapteren", .good)
            case .missing: return ("Adapteren sender ikke lyd", .warn)
            }
        }
    }
}

enum StatusLevel { case good, warn, bad, neutral }

extension Bundle {
    var appVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "utvikling"
    }
}

enum SystemInfo {
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        let ok = buf.withUnsafeMutableBytes { sysctlbyname(name, $0.baseAddress, &size, nil, 0) == 0 }
        guard ok else { return nil }
        return String(cString: buf)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return Int(v)
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64 (Apple Silicon)"
        #else
        return sysctlInt("sysctl.proc_translated") == 1 ? "x86_64 via Rosetta" : "x86_64 (Intel)"
        #endif
    }

    static var summary: String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let model = sysctlString("hw.model") ?? "ukjent modell"
        return "macOS \(os), \(model), \(architecture)"
    }
}
