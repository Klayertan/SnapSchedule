import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// A piece of text and where it sits on the page (0–1, origin top-left).
struct TextChunk {
    var text: String
    var rect: CGRect
}

/// A picture or PDF the user handed over, decoded once.
struct ScanInput {
    static let maxPages = 6

    let preview: CGImage
    /// One image per page (a single entry for pictures).
    let pages: [CGImage]
    /// The original file when it is a PDF.
    let pdfData: Data?
    /// Text taken from the PDF's own text layer; empty for pictures and scanned PDFs.
    private let embeddedText: [[TextChunk]]

    init?(data: Data) {
        if data.starts(with: Data("%PDF".utf8)) {
            guard let document = PDFDocument(data: data) else { return nil }
            let pdfPages = (0..<min(document.pageCount, Self.maxPages)).compactMap(document.page(at:))
            let images = pdfPages.compactMap { Self.render($0) }
            guard let first = images.first, images.count == pdfPages.count else { return nil }
            preview = first
            pages = images
            pdfData = data
            embeddedText = pdfPages.map(Self.textChunks(in:))
        } else {
            guard let image = Self.decodeImage(data) else { return nil }
            preview = image
            pages = [image]
            pdfData = nil
            embeddedText = []
        }
    }

    var pageJPEGs: [Data] { pages.compactMap(Self.jpegData) }

    /// Positioned text for every page: the PDF text layer when there is one, otherwise OCR.
    func textChunks() async throws -> [[TextChunk]] {
        if embeddedText.contains(where: { !$0.isEmpty }) { return embeddedText }
        var result: [[TextChunk]] = []
        for page in pages {
            result.append(try await OnDeviceExtractor.recognizeText(in: page))
        }
        return result
    }

    // MARK: Decoding

    private static func decodeImage(_ data: Data, maxPixelSize: Int = 2000) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func jpegData(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func displaySize(of page: PDFPage) -> CGSize {
        let size = page.bounds(for: .mediaBox).size
        return page.rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    private static func render(_ page: PDFPage, maxPixelSize: CGFloat = 2600) -> CGImage? {
        let size = displaySize(of: page)
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = maxPixelSize / max(size.width, size.height)
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// Splits the page's text into fragments that sit next to each other, so each table cell
    /// keeps its own position instead of being merged with its neighbours.
    private static func textChunks(in page: PDFPage) -> [TextChunk] {
        let string = (page.string ?? "") as NSString
        let size = displaySize(of: page)
        let transform = page.transform(for: .mediaBox)
        guard size.width > 0, size.height > 0 else { return [] }
        var chunks: [TextChunk] = []

        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byLines) { _, lineRange, _, _ in
            var line: [(text: String, rect: CGRect)] = []
            // Words first, then glue back together the ones that are close enough to be one phrase.
            var location = lineRange.location
            for word in string.substring(with: lineRange).components(separatedBy: .whitespaces) {
                let length = (word as NSString).length
                defer { location += length + 1 }
                guard length > 0,
                      let selection = page.selection(for: NSRange(location: location, length: length)) else { continue }
                let rect = selection.bounds(for: page).applying(transform)
                guard !rect.isEmpty else { continue }
                if let last = line.last,
                   abs(rect.midY - last.rect.midY) < max(rect.height, last.rect.height) * 0.6,
                   rect.minX - last.rect.maxX < max(rect.height, last.rect.height) * 0.8,
                   rect.minX - last.rect.maxX > -max(rect.height, last.rect.height) {
                    line[line.count - 1] = (last.text + " " + word, last.rect.union(rect))
                } else {
                    line.append((word, rect))
                }
            }
            chunks += line.map { item in
                TextChunk(text: item.text, rect: CGRect(
                    x: item.rect.minX / size.width, y: 1 - item.rect.maxY / size.height,
                    width: item.rect.width / size.width, height: item.rect.height / size.height))
            }
        }
        return chunks
    }
}

extension [[TextChunk]] {
    /// The layout as text a language model can reason over: one fragment per line with its position.
    var layoutDescription: String {
        enumerated().map { index, chunks in
            let lines = chunks
                .sorted { ($0.rect.midY, $0.rect.minX) < ($1.rect.midY, $1.rect.minX) }
                .map { chunk in
                    let y = Int((chunk.rect.midY * 1000).rounded())
                    let x1 = Int((chunk.rect.minX * 1000).rounded())
                    let x2 = Int((chunk.rect.maxX * 1000).rounded())
                    return "y=\(y) x=\(x1)-\(x2) | \(chunk.text)"
                }
            return "## Page \(index + 1)\n" + lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    var plainLines: [String] { flatMap { $0.map(\.text) } }
}
