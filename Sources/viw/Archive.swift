import Foundation

/// A zip opened for browsing: its entries as a table (name, size, packed size, modified, method),
/// a text preview of an entry for the detail pane, and extraction of one entry to a temporary
/// directory so it opens in a tab of its own (any kind viw knows, nested zips included).
final class ArchiveBrowser {
    static let extensions: Set<String> = ["zip", "jar", "whl", "egg", "war"]
    static let previewBytes = 4096

    let url: URL
    let zip: ZipArchive
    let names: [String]

    init(url: URL) throws {
        self.url = url
        zip = try ZipArchive(url: url)
        names = zip.names
    }

    var entryCount: Int { names.filter { !$0.hasSuffix("/") }.count }
    var totalSize: Int { names.compactMap { zip.entries[$0]?.uncompressedSize }.reduce(0, +) }

    func table() -> TableData {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var rows: [[String]] = []
        for name in names {
            guard let e = zip.entries[name] else { continue }
            let directory = name.hasSuffix("/")
            let kind = directory ? "folder" : e.encrypted ? "encrypted" : e.method == 0 ? "stored" : e.method == 8 ? "deflate" : "method \(e.method)"
            rows.append([
                name,
                directory ? "" : String(e.uncompressedSize),
                directory ? "" : String(e.compressedSize),
                e.modified.map { f.string(from: $0) } ?? "",
                kind,
            ])
        }
        var t = TableData(header: ["Name", "Size", "Packed", "Modified", "Method"], rows: rows, totalRows: rows.count + 1)
        t.inferTypes()
        t.preview = { [weak self] row in self?.preview(row) }
        t.activate = { [weak self] row in self?.extract(row) }
        return t
    }

    /// The first `previewBytes` of a text entry; nil for folders, binary data, and entries that cannot be read.
    func preview(_ row: Int) -> String? {
        guard names.indices.contains(row), !names[row].hasSuffix("/"), let data = try? zip.data(for: names[row]) else { return nil }
        let head = data.prefix(Self.previewBytes)
        guard !head.contains(0), let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .shiftJIS) else { return nil }
        return data.count > head.count ? text + "\n…" : text
    }

    /// Extract one entry under a temporary directory (keeping its path) and return the file.
    func extract(_ row: Int) -> URL? {
        guard names.indices.contains(row), !names[row].hasSuffix("/") else { return nil }
        let name = names[row]
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viw-zip-" + String(url.path.hashValue, radix: 36), isDirectory: true)
        // A name with ".." could escape the directory: keep only the path's own components.
        let safe = name.split(separator: "/").filter { $0 != ".." && $0 != "." }.joined(separator: "/")
        guard !safe.isEmpty else { return nil }
        let file = dir.appendingPathComponent(safe)
        do {
            let data = try zip.data(for: name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            return file
        } catch {
            FileHandle.standardError.write("viw: \(name): \(error)\n".data(using: .utf8)!)
            return nil
        }
    }
}
