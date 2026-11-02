import AppKit

/// Word 97 (`.doc`), RTF / RTFD and OpenDocument text, read with the importers
/// NSAttributedString ships with. Nothing is parsed here; the result is only tidied for the
/// viewer: the document's fonts stay, its sizes are scaled so a 12 pt body matches the
/// Markdown body size, and black-on-white colours give way to the theme so dark mode is
/// readable. Colours an author chose (red, blue) are kept.
enum RichDocument {
    /// `.docx` is also `.document`, but goes through `DOCX` (Markdown) rather than the importer.
    static let extensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt"]

    /// Point size a document is assumed to be written at (Word's default body is 11–12 pt).
    static let nominalSize: CGFloat = 12

    static func read(url: URL) throws -> NSAttributedString {
        var attributes: NSDictionary?
        return try NSAttributedString(url: url, options: [:], documentAttributes: &attributes)
    }

    /// `source` with text colours darker than `textLuminance` replaced by `text`, light
    /// backgrounds dropped, and every font scaled by `scale`.
    static func restyle(_ source: NSAttributedString, text: NSColor, scale: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: source)
        let whole = NSRange(location: 0, length: out.length)
        out.beginEditing()
        out.enumerateAttributes(in: whole, options: []) { attrs, range, _ in
            if let c = attrs[.foregroundColor] as? NSColor, isDark(c) {
                out.addAttribute(.foregroundColor, value: text, range: range)
            } else if attrs[.foregroundColor] == nil {
                out.addAttribute(.foregroundColor, value: text, range: range)
            }
            if let b = attrs[.backgroundColor] as? NSColor, luminance(of: b) > 0.85 {
                out.removeAttribute(.backgroundColor, range: range)
            }
            if scale != 1, let f = attrs[.font] as? NSFont {
                out.addAttribute(.font, value: NSFont(descriptor: f.fontDescriptor, size: (f.pointSize * scale).rounded()) ?? f, range: range)
            }
        }
        out.endEditing()
        return out
    }

    /// Black or a dark grey: every channel low (a saturated dark red or blue is the author's colour and stays).
    static func isDark(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return false }
        return max(c.redComponent, c.greenComponent, c.blueComponent) < 0.35
    }

    /// Relative luminance in sRGB (0 black … 1 white); pattern and catalog colours count as mid-grey.
    static func luminance(of color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return 0.5 }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }
}
