import SwiftUI
import AppKit

@main
struct VHSTilMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    @StateObject private var diagnostics: DiagnosticsModel

    init() {
        let m = AppModel()
        _model = StateObject(wrappedValue: m)
        _diagnostics = StateObject(wrappedValue: DiagnosticsModel(model: m))
        AppDelegate.shared = m
    }

    var body: some Scene {
        WindowGroup("VHS til Mac") {
            ContentView(diagnostics: diagnostics)
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.history)
                .environmentObject(model.log)
                .environmentObject(model.preview)
                .frame(minWidth: 960, minHeight: 680)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Opptak") {
                Button("Start / stopp opptak") { model.toggleRecording() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Åpne opptaksmappe") { model.openFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppDelegate.shared else { return .terminateNow }
        model.finishForQuit { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
