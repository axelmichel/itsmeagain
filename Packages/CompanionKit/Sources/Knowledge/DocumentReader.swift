import AppKit
import Foundation
import PDFKit
import Tools

/// Turns a local file into plain text for indexing.
public enum DocumentReader {
    static let plainTextExtensions: Set<String> = [
        "txt", "md", "markdown", "mdx", "rst", "org", "tex", "csv", "tsv", "log", "ini", "conf",
        "json", "yaml", "yml", "toml", "xml",
        "swift", "py", "js", "mjs", "ts", "tsx", "jsx", "java", "kt", "go", "rs", "c", "h", "cpp", "hpp",
        "m", "mm", "rb", "php", "sh", "zsh", "sql", "css", "scss", "vue", "svelte",
    ]
    static let htmlExtensions: Set<String> = ["html", "htm"]
    /// Read through NSAttributedString (Cocoa text system importers).
    static let richTextExtensions: Set<String> = ["rtf", "rtfd", "docx", "doc", "odt"]

    public static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return plainTextExtensions.contains(ext) || htmlExtensions.contains(ext)
            || richTextExtensions.contains(ext) || ext == "pdf"
    }

    public static func read(_ url: URL) throws -> (title: String, text: String) {
        let ext = url.pathExtension.lowercased()
        let title = url.deletingPathExtension().lastPathComponent
        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else { throw CocoaError(.fileReadCorruptFile) }
            let pdfTitle = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
            return (pdfTitle.flatMap { $0.isEmpty ? nil : $0 } ?? title, document.string ?? "")
        }
        if htmlExtensions.contains(ext) {
            let html = try String(contentsOf: url, encoding: .utf8)
            let page = try HTMLText.extract(html, baseURL: url)
            return (page.title.isEmpty ? title : page.title, page.text)
        }
        if richTextExtensions.contains(ext) {
            let string = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
            return (title, string)
        }
        let data = try Data(contentsOf: url)
        // Not every text file is UTF-8; fall back to Latin-1, which never fails.
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return (title, text)
    }
}
