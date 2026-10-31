import Foundation

enum VideoStandard: String, CaseIterable, Identifiable {
    case pal, ntsc
    var id: String { rawValue }
    var label: String { self == .pal ? "PAL (Norge/Europa)" : "NTSC (USA/Japan)" }
    var height: Int { self == .pal ? 576 : 480 }
    var width: Int { 720 }
    /// Bilder per sekund som brøk: PAL 25/1, NTSC 30000/1001.
    var frameDuration: (value: Int64, timescale: Int32) { self == .pal ? (1, 25) : (1001, 30000) }
    var fps: Double { self == .pal ? 25.0 : 30000.0 / 1001.0 }
    /// Pikselforhold (ITU-R BT.601) slik at 720 piksler vises som 4:3.
    var pixelAspect: (h: Int, v: Int) { self == .pal ? (12, 11) : (10, 11) }
}

enum VideoInput: String, CaseIterable, Identifiable {
    case composite, svideo
    var id: String { rawValue }
    var label: String { self == .composite ? "Kompositt (gul RCA)" : "S-Video" }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case standard, high, max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: return "Standard (4 Mbit/s)"
        case .high: return "Høy (7 Mbit/s)"
        case .max: return "Maksimal (12 Mbit/s)"
        }
    }
    var bitrate: Int {
        switch self {
        case .standard: return 4_000_000
        case .high: return 7_000_000
        case .max: return 12_000_000
        }
    }
    /// Omtrentlig plassbruk per time (video + lyd) for MP4.
    var gigabytesPerHour: Double { Double(bitrate + 192_000) * 3600 / 8 / 1e9 }
}

enum AudioSource: String, CaseIterable, Identifiable {
    case adapter, mac, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .adapter: return "Fra adapteren (rød/hvit RCA)"
        case .mac: return "Annen lydinngang på Mac-en"
        case .none: return "Ingen lyd"
        }
    }
}

/// Alle brukerinnstillinger, lagret i UserDefaults.
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var standard: VideoStandard { didSet { d.set(standard.rawValue, forKey: "standard") } }
    @Published var input: VideoInput { didSet { d.set(input.rawValue, forKey: "input") } }
    @Published var compositeMode: Int { didSet { d.set(compositeMode, forKey: "compositeMode") } }
    @Published var quality: VideoQuality { didSet { d.set(quality.rawValue, forKey: "quality") } }
    @Published var keepArchive: Bool { didSet { d.set(keepArchive, forKey: "keepArchive") } }
    @Published var audioSource: AudioSource { didSet { d.set(audioSource.rawValue, forKey: "audioSource") } }
    @Published var macAudioDeviceID: String { didSet { d.set(macAudioDeviceID, forKey: "macAudioDeviceID") } }
    @Published var monitorAudio: Bool { didSet { d.set(monitorAudio, forKey: "monitorAudio") } }
    @Published var monitorVolume: Double { didSet { d.set(monitorVolume, forKey: "monitorVolume") } }
    @Published var outputFolderPath: String { didSet { d.set(outputFolderPath, forKey: "outputFolder") } }
    @Published var brightness: Double { didSet { d.set(brightness, forKey: "brightness") } }
    @Published var contrast: Double { didSet { d.set(contrast, forKey: "contrast") } }
    @Published var saturation: Double { didSet { d.set(saturation, forKey: "saturation") } }
    @Published var hue: Double { didSet { d.set(hue, forKey: "hue") } }
    @Published var swapFields: Bool { didSet { d.set(swapFields, forKey: "swapFields") } }
    @Published var deinterlace: Bool { didSet { d.set(deinterlace, forKey: "deinterlace") } }

    static let defaultBrightness = 128.0
    static let defaultContrast = 71.0
    static let defaultSaturation = 64.0
    static let defaultHue = 0.0

    init() {
        standard = VideoStandard(rawValue: d.string(forKey: "standard") ?? "") ?? .pal
        input = VideoInput(rawValue: d.string(forKey: "input") ?? "") ?? .composite
        compositeMode = d.object(forKey: "compositeMode") as? Int ?? 0
        quality = VideoQuality(rawValue: d.string(forKey: "quality") ?? "") ?? .high
        keepArchive = d.object(forKey: "keepArchive") as? Bool ?? false
        audioSource = AudioSource(rawValue: d.string(forKey: "audioSource") ?? "") ?? .adapter
        macAudioDeviceID = d.string(forKey: "macAudioDeviceID") ?? ""
        monitorAudio = d.object(forKey: "monitorAudio") as? Bool ?? true
        monitorVolume = d.object(forKey: "monitorVolume") as? Double ?? 0.8
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        outputFolderPath = d.string(forKey: "outputFolder") ?? movies.appendingPathComponent("VHS-opptak").path
        brightness = d.object(forKey: "brightness") as? Double ?? Self.defaultBrightness
        contrast = d.object(forKey: "contrast") as? Double ?? Self.defaultContrast
        saturation = d.object(forKey: "saturation") as? Double ?? Self.defaultSaturation
        hue = d.object(forKey: "hue") as? Double ?? Self.defaultHue
        swapFields = d.object(forKey: "swapFields") as? Bool ?? false
        deinterlace = d.object(forKey: "deinterlace") as? Bool ?? true
    }

    var outputFolder: URL { URL(fileURLWithPath: outputFolderPath, isDirectory: true) }

    func resetPicture() {
        brightness = Self.defaultBrightness
        contrast = Self.defaultContrast
        saturation = Self.defaultSaturation
        hue = Self.defaultHue
    }
}
