import Foundation
import Vision
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Classifies a photo into a coarse scene category on-device (D8 "full classifier", implemented with
/// Apple Vision — no model to download): "screenshot", "document", or "other". People and Places are
/// derived elsewhere (faces table / GPS). Read-only: only reads the file.
public struct PhotoClassifier: Sendable {
    public init() {}

    public func classify(url: URL) -> String {
        classify(isScreenshot: Self.looksLikeScreenshot(url),
                 handler: VNImageRequestHandler(url: url, options: [:]))
    }

    /// Classify from an already-decoded image + its source (no re-read/re-decode of the file). Used by
    /// the scan loop, which decodes each photo once and reuses it across face/pet/classify.
    public func classify(image: CGImage, source: CGImageSource, filename: String) -> String {
        classify(isScreenshot: Self.looksLikeScreenshot(filename: filename, source: source),
                 handler: VNImageRequestHandler(cgImage: image, options: [:]))
    }

    private func classify(isScreenshot: Bool, handler: VNImageRequestHandler) -> String {
        let isDocLike = Self.looksLikeDocument(handler)
        // OCR only when document-like, so it stays cheap and never runs on every general screenshot.
        let hasIdentity = isDocLike && Self.containsIdentityKeywords(handler)
        return Self.category(isScreenshot: isScreenshot, isDocLike: isDocLike, hasIdentity: hasIdentity)
    }

    /// Pure category decision from the three signals (separated so it's unit-testable without Vision).
    /// Priority: **identity** (an ID document — including a screenshot of one) → **screenshot** →
    /// **document** → other. Screenshot beating document is the fix for general screenshots leaking
    /// into Documents: a full-frame screenshot reads as one big "document" rectangle to Vision, so once
    /// it's recognized as a screenshot it must win over the document bucket.
    static func category(isScreenshot: Bool, isDocLike: Bool, hasIdentity: Bool) -> String {
        if hasIdentity { return "identity" }
        if isScreenshot { return "screenshot" }
        if isDocLike { return "document" }
        return "other"
    }

    /// Paper/card-like via Vision's document segmentation, falling back to scene labels.
    private static func looksLikeDocument(_ handler: VNImageRequestHandler) -> Bool {
        let docReq = VNDetectDocumentSegmentationRequest()
        if (try? handler.perform([docReq])) != nil,
           let rect = docReq.results?.first, rect.confidence >= 0.75 {
            return true
        }
        let classify = VNClassifyImageRequest()
        if (try? handler.perform([classify])) != nil, let results = classify.results {
            let strong = Set(results.filter { $0.confidence >= 0.6 }.map { $0.identifier })
            if !strong.isDisjoint(with: documentLabels) { return true }
        }
        return false
    }

    /// On-device animal detection (Apple Vision). Returns "cat" / "dog" for the most confident animal,
    /// or nil. From an already-decoded image (no re-read/re-decode); used by the scan loop. Per-individual
    /// pet identity (grouping Loki vs Star) is a separate, larger feature.
    public static func detectPet(image: CGImage) -> String? {
        detectPet(handler: VNImageRequestHandler(cgImage: image, options: [:]))
    }

    private static func detectPet(handler: VNImageRequestHandler) -> String? {
        let req = VNRecognizeAnimalsRequest()
        guard (try? handler.perform([req])) != nil, let obs = req.results else { return nil }
        guard let best = obs.compactMap({ $0.labels.first }).max(by: { $0.confidence < $1.confidence }),
              best.confidence >= 0.6 else { return nil }
        let id = best.identifier.lowercased()
        if id.contains("cat") { return "cat" }
        if id.contains("dog") { return "dog" }
        return nil
    }

    /// Fast on-device OCR; true if the text contains ID-document markers (Aadhaar/PAN/passport/…).
    static func containsIdentityKeywords(_ handler: VNImageRequestHandler) -> Bool {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .fast
        req.usesLanguageCorrection = false
        guard (try? handler.perform([req])) != nil, let obs = req.results else { return false }
        let text = obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        guard !text.isEmpty else { return false }
        return identityKeywords.contains { text.contains($0) }
    }

    // Physical-document labels only. Deliberately excludes "text"/"menu"/"whiteboard"/"poster"/
    // "newspaper"/"spreadsheet"/"book_jacket" — those fire on text-heavy UI screenshots and were a
    // source of general screenshots landing in Documents.
    private static let documentLabels: Set<String> = [
        "document", "paper", "receipt", "letter", "envelope",
        "passport", "business_card", "form", "invoice", "id_card", "credit_card",
    ]

    /// Markers found on common ID documents (India-focused per the request, plus generic ones).
    static let identityKeywords: [String] = [
        "aadhaar", "aadhar", "uidai", "unique identification",
        "permanent account number", "income tax department",          // PAN
        "passport", "republic of india", "type p<",
        "driving licence", "driving license", "transport department",
        "voter", "election commission", "identity card", "id card",
    ]

    /// Screenshots: filename markers, a PNG with no camera metadata, or — to catch mobile
    /// screenshots (often JPEG) — a no-camera image with a phone-screen aspect ratio.
    static func looksLikeScreenshot(_ url: URL) -> Bool {
        looksLikeScreenshot(filename: url.lastPathComponent,
                            source: CGImageSourceCreateWithURL(url as CFURL, nil))
    }

    static func looksLikeScreenshot(filename: String, source src: CGImageSource?) -> Bool {
        let name = filename.lowercased()
        for marker in ["screenshot", "screen shot", "screen-shot", "scrnshot", "screen recording",
                       "screen_recording", "cleanshot"] where name.contains(marker) { return true }

        guard let src,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return false }

        let isPNG = (CGImageSourceGetType(src) as String?) == UTType.png.identifier
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let hasCamera = tiff?[kCGImagePropertyTIFFMake] != nil
            || exif?[kCGImagePropertyExifLensMake] != nil
            || exif?[kCGImagePropertyExifDateTimeOriginal] != nil
        guard !hasCamera else { return false }   // a real photo → never a screenshot

        if isPNG { return true }   // a PNG with no camera EXIF is a screen capture / synthetic, not a photo

        // Mobile screenshots are frequently JPEG with no camera EXIF. A phone-screen aspect ratio
        // (tall portrait or wide landscape, long:short ≈ 1.7–2.3) is the tell.
        if let w = props[kCGImagePropertyPixelWidth] as? Double,
           let h = props[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0 {
            let ratio = max(w, h) / min(w, h)
            if ratio >= 1.7 && ratio <= 2.3 { return true }
        }
        return false
    }
}
