import Foundation
import AppKit

/// Opptakshistorikk: video-filer i opptaksmappen.
final class HistoryStore: ObservableObject {
    struct Item: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let name: String
        let date: Date
        let bytes: Int64
        let isArchive: Bool
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var freeBytes: Int64?

    func refresh(folder: URL) {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                    options: [.skipsHiddenFiles])) ?? []
            var list: [Item] = []
            for u in urls where ["mp4", "mov", "m4v"].contains(u.pathExtension.lowercased()) {
                let v = try? u.resourceValues(forKeys: Set(keys))
                guard v?.isRegularFile ?? true else { continue }
                list.append(Item(url: u, name: u.lastPathComponent,
                                 date: v?.contentModificationDate ?? .distantPast,
                                 bytes: Int64(v?.fileSize ?? 0),
                                 isArchive: u.pathExtension.lowercased() == "mov"))
            }
            list.sort { $0.date > $1.date }
            let total = list.reduce(Int64(0)) { $0 + $1.bytes }
            let free = HistoryStore.freeSpace(at: folder)
            DispatchQueue.main.async {
                self.items = list
                self.totalBytes = total
                self.freeBytes = free
            }
        }
    }

    static func freeSpace(at folder: URL) -> Int64? {
        var probe = folder
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func open(_ item: Item) { NSWorkspace.shared.open(item.url) }
    func reveal(_ item: Item) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
}
