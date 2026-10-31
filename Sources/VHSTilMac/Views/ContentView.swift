import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var diagnostics: DiagnosticsModel
    @State private var tab: SidebarTab = .settings

    init(diagnostics: DiagnosticsModel) {
        _diagnostics = ObservedObject(wrappedValue: diagnostics)
    }

    enum SidebarTab: String, CaseIterable, Identifiable {
        case settings = "Innstillinger", history = "Historikk", diagnostics = "Diagnose"
        var id: String { rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                StatusPanel()
                PreviewArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                RecordBar()
            }
            .padding(16)
            .frame(minWidth: 560)

            Divider()

            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(SidebarTab.allCases) { t in Text(t.rawValue).tag(t) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(12)
                Divider()
                switch tab {
                case .settings: SettingsPanel()
                case .history: HistoryPanel()
                case .diagnostics: DiagnosticsPanel(diag: diagnostics)
                }
            }
            .frame(width: 360)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }
}

// MARK: - Status

struct StatusPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusRow(title: "USB-adapter", value: model.usbText)
            StatusRow(title: "Videostrøm", value: model.streamText)
            StatusRow(title: "Videosignal", value: model.signalText)
            StatusRow(title: "Lyd", value: model.audioText)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
    }
}

struct StatusRow: View {
    let title: String
    let value: (String, StatusLevel)

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(title).font(.callout.weight(.semibold)).frame(width: 96, alignment: .leading)
            Text(value.0).font(.callout).foregroundColor(.secondary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch value.1 {
        case .good: return .green
        case .warn: return .orange
        case .bad: return .red
        case .neutral: return .gray
        }
    }
}

// MARK: - Opptakslinje

struct RecordBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Button(action: { model.toggleRecording() }) {
                    HStack(spacing: 8) {
                        Image(systemName: model.isRecording ? "stop.fill" : "record.circle")
                        Text(model.isRecording ? "Stopp opptak" : (model.isFinishing ? "Lagrer …" : "Start opptak"))
                    }
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .foregroundColor(.white)
                    .background(RoundedRectangle(cornerRadius: 8).fill(model.isRecording ? Color.gray : Color.red))
                }
                .buttonStyle(.plain)
                .disabled(model.isFinishing)
                .help("Start eller stopp opptak (⌘R)")

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isRecording ? formatDuration(model.recordingElapsed) : "0:00:00")
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                    Text(model.isRecording
                         ? "\(model.recordingFileName) · \(HistoryStore.size(model.recordingBytes))"
                         : "Lagres som MP4 (H.264) i «\(settings.outputFolder.lastPathComponent)»" + (settings.keepArchive ? " + ProRes-arkiv" : ""))
                        .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button(action: { model.openFolder() }) {
                    Label("Åpne opptaksmappe", systemImage: "folder")
                }
            }
            if let w = model.recordingWarning {
                Label(w, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundColor(.orange)
            }
        }
    }
}

// MARK: - Innstillinger

struct SettingsPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox(label: Label("Video", systemImage: "video")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Inngang", selection: $settings.input) {
                            ForEach(VideoInput.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("TV-standard", selection: $settings.standard) {
                            ForEach(VideoStandard.allCases) { Text($0.label).tag($0) }
                        }
                        .disabled(model.isRecording)
                        Toggle("Fjern linjefletting (anbefalt for MP4)", isOn: $settings.deinterlace)
                        Text("VHS er linjeflettet (50 halvbilder/s). Arkivkopien beholder alltid originalen.")
                            .font(.caption).foregroundColor(.secondary)
                    }.padding(6)
                }

                GroupBox(label: Label("Opptak", systemImage: "record.circle")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Kvalitet", selection: $settings.quality) {
                            ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
                        }
                        .disabled(model.isRecording)
                        Text(String(format: "Ca. %.1f GB per time i MP4.", settings.quality.gigabytesPerHour))
                            .font(.caption).foregroundColor(.secondary)
                        Toggle("Lagre også arkivkopi (ProRes 422, .mov)", isOn: $settings.keepArchive)
                            .disabled(model.isRecording)
                        if settings.keepArchive {
                            Text("Linjeflettet original med 24-bit lyd. Ca. 18 GB per time.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        HStack {
                            Text(settings.outputFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Velg …") { model.chooseFolder() }.disabled(model.isRecording)
                        }
                    }.padding(6)
                }

                GroupBox(label: Label("Lyd", systemImage: "speaker.wave.2")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Kilde", selection: $settings.audioSource) {
                            ForEach(AudioSource.allCases) { Text($0.label).tag($0) }
                        }
                        .disabled(model.isRecording)
                        if settings.audioSource == .mac {
                            HStack {
                                Picker("Inngang", selection: $settings.macAudioDeviceID) {
                                    Text("Standard").tag("")
                                    ForEach(model.macAudioDevices) { Text($0.name).tag($0.id) }
                                }
                                Button(action: { model.refreshMacAudioDevices() }) { Image(systemName: "arrow.clockwise") }
                                    .help("Oppdater listen")
                            }
                            .disabled(model.isRecording)
                            if let e = model.macAudioError {
                                Text(e).font(.caption).foregroundColor(.red)
                            }
                        }
                        if settings.audioSource == .adapter {
                            Toggle("Lytt på lyden mens du ser", isOn: $settings.monitorAudio)
                            HStack {
                                Image(systemName: "speaker.fill").foregroundColor(.secondary)
                                Slider(value: $settings.monitorVolume, in: 0...1)
                                Image(systemName: "speaker.wave.3.fill").foregroundColor(.secondary)
                            }
                            .disabled(!settings.monitorAudio)
                        }
                    }.padding(6)
                }

                GroupBox(label: Label("Bilde", systemImage: "slider.horizontal.3")) {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledSlider(title: "Lysstyrke", value: $settings.brightness, range: 0...255)
                        LabeledSlider(title: "Kontrast", value: $settings.contrast, range: 0...127)
                        LabeledSlider(title: "Fargemetning", value: $settings.saturation, range: 0...127)
                        LabeledSlider(title: "Fargetone", value: $settings.hue, range: -128...127)
                        Button("Tilbakestill bilde") { settings.resetPicture() }
                    }.padding(6)
                }

                GroupBox(label: Label("Avansert", systemImage: "gearshape")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Forhåndsvisning på", isOn: Binding(get: { model.previewEnabled },
                                                                    set: { model.setPreview($0) }))
                            .disabled(model.isRecording)
                        Toggle("Bytt rekkefølge på halvbilder", isOn: $settings.swapFields)
                        Text("Prøv dette hvis bevegelser ser «hakkete» eller stripete ut.")
                            .font(.caption).foregroundColor(.secondary)
                        Stepper("Kompositt-kanal: \(settings.compositeMode)", value: $settings.compositeMode, in: 0...5)
                            .disabled(settings.input != .composite)
                        Text("Normalt 0. Bruk «Finn inngang med signal» under Diagnose hvis bildet mangler.")
                            .font(.caption).foregroundColor(.secondary)
                    }.padding(6)
                }
            }
            .padding(12)
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(title).font(.callout).frame(width: 96, alignment: .leading)
            Slider(value: $value, in: range, step: 1)
            Text("\(Int(value))").font(.system(.caption, design: .monospaced)).frame(width: 34, alignment: .trailing)
        }
    }
}

// MARK: - Historikk

struct HistoryPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var settings: AppSettings

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "nb_NO")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(history.items.count) filer · \(HistoryStore.size(history.totalBytes))")
                    .font(.callout)
                Spacer()
                Button(action: { history.refresh(folder: settings.outputFolder) }) { Image(systemName: "arrow.clockwise") }
                    .help("Oppdater")
            }
            .padding(12)
            if let free = history.freeBytes {
                Text("Ledig plass: \(HistoryStore.size(free))")
                    .font(.caption).foregroundColor(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            if history.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "film").font(.largeTitle).foregroundColor(.secondary)
                    Text("Ingen opptak ennå").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(history.items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        HStack {
                            Text(Self.df.string(from: item.date))
                            Text("·")
                            Text(HistoryStore.size(item.bytes))
                            if item.isArchive { Text("· arkiv") }
                            Spacer()
                            Button("Åpne") { history.open(item) }.buttonStyle(.link)
                            Button("Vis") { history.reveal(item) }.buttonStyle(.link)
                        }
                        .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

// MARK: - Diagnose

struct DiagnosticsPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var log: LogStore
    @ObservedObject var diag: DiagnosticsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Button("1. Les USB-beskrivelser (kun lesing)") { diag.describe() }
                Button("2. Test videostrømmen (5 s)") { diag.streamTest() }
                    .disabled(model.isRecording)
                Button("3. Finn inngang med signal") { diag.searchInputs() }
                    .disabled(model.isRecording)
                HStack {
                    Button("Lagre diagnosepakke …") { diag.exportPackage() }
                    Button("Kopier rapport") { diag.copyReport() }
                }
            }
            .disabled(diag.busy != nil)
            .padding(.horizontal, 12).padding(.top, 12)

            if let b = diag.busy {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                    Text(b).font(.caption)
                }.padding(.horizontal, 12)
            }

            ScrollView {
                Text(diag.report)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(NSColor.textBackgroundColor))
            .frame(minHeight: 180)

            HStack {
                Text("Logg").font(.callout.weight(.semibold))
                Spacer()
                Button("Tøm") { log.clear() }.buttonStyle(.link)
            }.padding(.horizontal, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(log.entries.suffix(400)) { e in
                        Text(LogStore.format(e))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(e.level >= .warning ? (e.level == .error ? .red : .orange) : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .background(Color(NSColor.textBackgroundColor))
            .frame(minHeight: 160)
        }
    }
}
