import Foundation

/// Jupyter notebooks (`.ipynb`, nbformat 4), converted to Markdown and rendered like a `.md`
/// file: Markdown cells as they are, code cells as fenced blocks in the kernel's language,
/// followed by their outputs (text in plain blocks, pictures extracted to a temporary
/// directory, errors with the ANSI colours stripped). Raw cells are shown as written.
enum Notebook {
    struct Result {
        var markdown: String
        var mediaDirectory: URL?
    }

    struct Error: Swift.Error, CustomStringConvertible {
        let description: String
    }

    static func markdown(url: URL) throws -> Result {
        guard let data = FileManager.default.contents(atPath: url.path) else { throw Error(description: "cannot read \(url.path)") }
        return try markdown(data: data, source: url)
    }

    static func markdown(data: Data, source: URL) throws -> Result {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cells = root["cells"] as? [[String: Any]] else {
            throw Error(description: "not a notebook (no cells)")
        }
        let metadata = root["metadata"] as? [String: Any]
        let language = ((metadata?["kernelspec"] as? [String: Any])?["language"] as? String)
            ?? ((metadata?["language_info"] as? [String: Any])?["name"] as? String) ?? ""
        var out: [String] = []
        var mediaDirectory: URL?
        var pictures = 0

        func fence(_ body: String, language: String = "") -> String {
            // A fence longer than any backtick run inside keeps the block intact.
            var ticks = "```"
            while body.contains(ticks) { ticks += "`" }
            return "\(ticks)\(language)\n\(body)\n\(ticks)"
        }
        func save(_ base64: String, ext: String) -> String? {
            guard let bytes = Data(base64Encoded: base64.replacingOccurrences(of: "\n", with: ""), options: .ignoreUnknownCharacters) else { return nil }
            if mediaDirectory == nil {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("viw-ipynb-" + String(source.path.hashValue, radix: 36), isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                mediaDirectory = dir
            }
            guard let dir = mediaDirectory else { return nil }
            pictures += 1
            let file = dir.appendingPathComponent("output-\(pictures).\(ext)")
            guard (try? bytes.write(to: file)) != nil else { return nil }
            return "![output \(pictures)](\(file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path))"
        }

        for cell in cells {
            let src = text(cell["source"])
            switch cell["cell_type"] as? String {
            case "markdown":
                out.append(src)
            case "raw":
                out.append(fence(src))
            case "code":
                let count = (cell["execution_count"] as? Int).map(String.init) ?? " "
                out.append("`In [\(count)]:`")
                out.append(fence(src, language: language))
                for output in cell["outputs"] as? [[String: Any]] ?? [] {
                    switch output["output_type"] as? String {
                    case "stream":
                        out.append(fence(trimmed(text(output["text"]))))
                    case "execute_result", "display_data":
                        let data = output["data"] as? [String: Any] ?? [:]
                        if let png = data["image/png"] as? String, let md = save(png, ext: "png") {
                            out.append(md)
                        } else if let jpeg = data["image/jpeg"] as? String, let md = save(jpeg, ext: "jpg") {
                            out.append(md)
                        } else if let svg = data["image/svg+xml"], let md = save(Data(text(svg).utf8).base64EncodedString(), ext: "svg") {
                            out.append(md)
                        } else if let md = data["text/markdown"] {
                            out.append(text(md))
                        } else if let plain = data["text/plain"] {
                            out.append(fence(trimmed(text(plain))))
                        } else if data["text/html"] != nil {
                            out.append("*[html output]*")
                        } else if let kind = data.keys.sorted().first {
                            out.append("*[\(kind) output]*")
                        }
                    case "error":
                        let lines = (output["traceback"] as? [String])?.map(stripANSI) ?? []
                        let body = lines.isEmpty ? "\(output["ename"] ?? "Error"): \(output["evalue"] ?? "")" : lines.joined(separator: "\n")
                        out.append(fence(trimmed(body)))
                    default:
                        break
                    }
                }
            default:
                break
            }
        }
        return Result(markdown: out.joined(separator: "\n\n") + "\n", mediaDirectory: mediaDirectory)
    }

    /// nbformat stores text either as one string or as a list of lines (newlines included).
    static func text(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let lines = value as? [String] { return lines.joined() }
        return ""
    }

    static func trimmed(_ s: String) -> String {
        var t = s
        while t.hasSuffix("\n") { t.removeLast() }
        return t
    }

    /// Drop terminal colour / cursor sequences (`ESC [ … m` and friends).
    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}
