import Foundation
import AppKit
import CoreImage
import CoreVideo

/// Diagnose i trinn: (1) les USB-beskrivelser (kun lesing), (2) strømmetest,
/// (3) søk etter inngang med signal, og eksport av en diagnosepakke.
final class DiagnosticsModel: ObservableObject {
    @Published var report = "Trykk «Les USB-beskrivelser» for å starte. Det første trinnet er kun lesing og sender ingen kommandoer til adapteren."
    @Published var busy: String?
    private var describeText = ""
    private var streamText = ""
    private var searchText = ""
    private var rawData = Data()
    private unowned let model: AppModel

    init(model: AppModel) { self.model = model }

    func describe() {
        busy = "Leser USB-beskrivelser …"
        model.engine.describeDevices { [weak self] text in
            guard let self = self else { return }
            self.describeText = text
            self.busy = nil
            self.rebuild()
        }
    }

    func streamTest() {
        busy = "Tester videostrømmen i 5 sekunder …"
        model.engine.runStreamTest(seconds: 5) { [weak self] text, data in
            guard let self = self else { return }
            self.streamText = text
            self.rawData = data
            self.busy = nil
            self.rebuild()
        }
    }

    func searchInputs() {
        busy = "Søker etter signal på alle innganger (ca. 10 s) …"
        model.engine.searchInputs { [weak self] text, found in
            guard let self = self else { return }
            self.searchText = text
            self.busy = nil
            if let f = found {
                self.model.settings.input = f.0
                if f.0 == .composite { self.model.settings.compositeMode = f.1 }
            }
            self.rebuild()
        }
    }

    private func rebuild() {
        report = fullReport()
    }

    func fullReport() -> String {
        let s = model.settings
        let m = model.metrics
        var parts: [String] = []
        let standard = s.standard == .pal ? "PAL" : "NTSC"
        let input = s.input == .svideo ? "S-Video" : "kompositt modus \(s.compositeMode)"
        var measured = String(format: "%.2f MB/s, %.1f bilder/s (+%.1f ufullstendige/s), linjer %ld/%ld, iso-feil %llu, lydblokker %.0f/s, luma snitt %.0f spredning %.0f, droppet i app %ld",
                              m.megabytesPerSecond, m.framesPerSecond, m.partialFramesPerSecond, m.linesField1, m.linesField2,
                              m.isoErrors, m.audioBlocksPerSecond, m.meanLuma, m.lumaSpread, m.droppedInApp)
        if let st = m.decoderStatus { measured += String(format: ", dekoderstatus 0x%02x", st) }
        let header: [String] = [
            "VHS til Mac – diagnoserapport",
            "Tidspunkt: \(ISO8601DateFormatter().string(from: Date()))",
            "App: \(Bundle.main.appVersion), SMI-kjerne \(model.engine.coreVersion)",
            "System: \(SystemInfo.summary)",
            "",
            "Innstillinger: \(standard), \(input), lyd: \(s.audioSource.rawValue), linjefletting fjernes: \(s.deinterlace), byttede halvbilder: \(s.swapFields)",
            "Status: USB=\(model.usbText.0) | Strøm=\(model.streamText.0) | Signal=\(model.signalText.0) | Lyd=\(model.audioText.0)",
            "Målinger: \(measured)"
        ]
        parts.append(header.joined(separator: "\n"))
        if !describeText.isEmpty { parts.append("=== 1. USB-beskrivelser og tilgang ===\n" + describeText) }
        if !streamText.isEmpty { parts.append("=== 2. Strømmetest ===\n" + streamText) }
        if !searchText.isEmpty { parts.append("=== 3. Søk etter inngang ===\n" + searchText) }
        return parts.joined(separator: "\n\n")
    }

    func copyReport() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(fullReport() + "\n\n=== Logg ===\n" + model.log.exportText(), forType: .string)
    }

    /// Lagrer rapport, logg, stillbilde og rå USB-data i en mappe + ZIP-fil.
    func exportPackage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Lagre her"
        panel.message = "Velg hvor diagnosepakken skal lagres (f.eks. Skrivebord)"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let base = panel.url else { return }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = base.appendingPathComponent("VHS-diagnose \(df.string(from: Date()))", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fullReport().write(to: folder.appendingPathComponent("rapport.txt"), atomically: true, encoding: .utf8)
            try model.log.exportText().write(to: folder.appendingPathComponent("logg.txt"), atomically: true, encoding: .utf8)
            if !rawData.isEmpty {
                try rawData.write(to: folder.appendingPathComponent("usb-raadata.bin"))
            }
            var frame: CVPixelBuffer?
            model.engine.videoQueue.sync { frame = model.engine.lastRawFrame }
            if let f = frame, let png = DiagnosticsModel.png(from: f) {
                try png.write(to: folder.appendingPathComponent("stillbilde.png"))
            }
            let zip = base.appendingPathComponent(folder.lastPathComponent + ".zip")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
            try? p.run()
            p.waitUntilExit()
            let target = fm.fileExists(atPath: zip.path) ? zip : folder
            NSWorkspace.shared.activateFileViewerSelecting([target])
            model.log.info("Diagnosepakke lagret: \(target.path)")
        } catch {
            model.alert = AppAlert(title: "Kunne ikke lagre diagnosepakken", message: error.localizedDescription)
        }
    }

    /// Stillbilde som PNG, skalert til 4:3 visningsstørrelse.
    static func png(from pb: CVPixelBuffer) -> Data? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let targetW = Double(h) * 4.0 / 3.0
        let img = CIImage(cvPixelBuffer: pb).transformed(by: CGAffineTransform(scaleX: targetW / Double(w), y: 1))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(img, from: img.extent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}
