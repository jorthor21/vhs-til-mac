import AVFoundation

/// Alternativ lydkilde: en lydinngang på Mac-en (f.eks. en USB-lydplugg eller
/// linjeinngang). Brukes når adapteren ikke leverer lyd.
/// Krever mikrofontillatelse – macOS spør første gang (kun når denne kilden velges).
final class MacAudioInput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "vhs.macaudio")
    private let log: LogStore
    private(set) var currentDeviceID: String?
    private(set) var format: AudioStreamBasicDescription?

    /// Kalles på 'queue' med lyd i vertstid.
    var onSample: ((CMSampleBuffer) -> Void)?

    init(log: LogStore) {
        self.log = log
        super.init()
        output.setSampleBufferDelegate(self, queue: queue)
    }

    static func availableDevices() -> [Device] {
        AVCaptureDevice.devices(for: .audio).map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    }

    /// Starter opptak fra valgt enhet. Returnerer feilmelding ved problemer.
    func start(deviceID: String) -> String? {
        stop()
        let devices = AVCaptureDevice.devices(for: .audio)
        guard let dev = devices.first(where: { $0.uniqueID == deviceID }) ?? AVCaptureDevice.default(for: .audio) else {
            return "Fant ingen lydinngang på Mac-en."
        }
        do {
            let input = try AVCaptureDeviceInput(device: dev)
            session.beginConfiguration()
            for i in session.inputs { session.removeInput(i) }
            guard session.canAddInput(input) else { session.commitConfiguration(); return "Kan ikke bruke \(dev.localizedName)." }
            session.addInput(input)
            if !session.outputs.contains(output) {
                guard session.canAddOutput(output) else { session.commitConfiguration(); return "Kan ikke lese lyd fra \(dev.localizedName)." }
                session.addOutput(output)
            }
            session.commitConfiguration()
            let desc = dev.activeFormat.formatDescription
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                format = asbd.pointee
            }
            session.startRunning()
            currentDeviceID = dev.uniqueID
            log.info("Mac-lydinngang startet: \(dev.localizedName)" +
                     (format.map { String(format: " (%.0f Hz, %u kanaler)", $0.mSampleRate, $0.mChannelsPerFrame) } ?? ""))
            return nil
        } catch {
            return "Kunne ikke åpne \(dev.localizedName): \(error.localizedDescription)"
        }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
        currentDeviceID = nil
    }

    var isRunning: Bool { session.isRunning }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
            format = asbd.pointee
        }
        onSample?(sampleBuffer)
    }
}
