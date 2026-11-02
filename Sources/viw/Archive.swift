import Foundation

/// One entry of a zip, or a folder implied by the entries' paths, in the tree the archive
/// view shows. Folders come first among siblings, then files, each sorted by name.
final class ArchiveNode: NSObject { // NSObject: NSOutlineView keys its rows by item identity
    let name: String            // last path component
    let path: String            // the zip entry name ("docs/inner.md"; folders end in "/")
    let isDirectory: Bool
    let entry: ZipArchive.Entry? // nil for a folder that has no entry of its own
    private(set) weak var parent: ArchiveNode?
    private(set) var children: [ArchiveNode] = []
    private(set) var fileCount = 0
    private(set) var size = 0   // files: uncompressed bytes; folders: the sum below

    init(name: String, path: String, isDirectory: Bool, entry: ZipArchive.Entry?) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.entry = entry
        if !isDirectory { fileCount = 1; size = entry?.uncompressedSize ?? 0 }
        super.init()
    }

    fileprivate func add(_ child: ArchiveNode) {
        child.parent = self
        children.append(child)
    }

    fileprivate func finish() {
        children.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        for c in children {
            c.finish()
            fileCount += c.fileCount
            size += c.size
        }
    }

    /// The folders above this node, outermost first (the root is left out).
    var ancestors: [ArchiveNode] {
        var out: [ArchiveNode] = []
        var p = parent
        while let node = p, node.parent != nil { out.append(node); p = node.parent }
        return out.reversed()
    }

    /// Every node below this one, depth first (the order the expanded tree shows).
    var descendants: [ArchiveNode] { children.flatMap { [$0] + $0.descendants } }
}

/// A zip opened for browsing: the entries as a tree, a text preview of one entry, and
/// extraction of one entry to a temporary directory so it opens in a tab of its own (any
/// kind viw knows, nested zips included).
final class ArchiveBrowser {
    static let extensions: Set<String> = ["zip", "jar", "whl", "egg", "war"]
    static let previewBytes = 4096

    let url: URL
    let zip: ZipArchive
    let root: ArchiveNode

    init(url: URL) throws {
        self.url = url
        zip = try ZipArchive(url: url)
        root = Self.tree(of: zip)
    }

    var entryCount: Int { root.fileCount }
    var totalSize: Int { root.size }

    static func tree(of zip: ZipArchive) -> ArchiveNode {
        let root = ArchiveNode(name: "", path: "", isDirectory: true, entry: nil)
        var folders: [String: ArchiveNode] = ["": root]
        func folder(_ path: String) -> ArchiveNode { // "a/b/" → node, creating the chain
            if let f = folders[path] { return f }
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            let parentPath = parts.dropLast().map { $0 + "/" }.joined()
            let node = ArchiveNode(name: String(parts.last ?? ""), path: path, isDirectory: true, entry: zip.entries[path])
            folders[path] = node
            folder(parentPath).add(node)
            return node
        }
        for name in zip.names {
            if name.hasSuffix("/") { _ = folder(name); continue }
            let parts = name.split(separator: "/", omittingEmptySubsequences: true)
            guard let last = parts.last else { continue }
            let parentPath = parts.dropLast().map { $0 + "/" }.joined()
            folder(parentPath).add(ArchiveNode(name: String(last), path: name, isDirectory: false, entry: zip.entries[name]))
        }
        root.finish()
        return root
    }

    /// The first `previewBytes` of a text entry; nil for folders, binary data, and entries that cannot be read.
    func preview(_ node: ArchiveNode) -> String? {
        guard !node.isDirectory, let data = try? zip.data(for: node.path) else { return nil }
        let head = data.prefix(Self.previewBytes)
        guard !head.contains(0), let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .shiftJIS) else { return nil }
        return data.count > head.count ? text + "\n…" : text
    }

    /// Extract one entry under a temporary directory (keeping its path) and return the file.
    func extract(_ node: ArchiveNode) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viw-zip-" + String(url.path.hashValue, radix: 36), isDirectory: true)
        // A name with ".." could escape the directory: keep only the path's own components.
        let safe = node.path.split(separator: "/").filter { $0 != ".." && $0 != "." }.joined(separator: "/")
        guard !node.isDirectory, !safe.isEmpty else { throw ZipArchive.Error.entryNotFound(node.path) }
        let file = dir.appendingPathComponent(safe)
        let data = try zip.data(for: node.path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }
}
