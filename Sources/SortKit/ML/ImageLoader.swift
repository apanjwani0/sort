import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

public enum ImageError: Error, CustomStringConvertible {
    case cannotDecode(URL)
    case cannotDecodeData
    case cannotCreatePixelBuffer

    public var description: String {
        switch self {
        case .cannotDecode(let u): return "Cannot decode image: \(u.path)"
        case .cannotDecodeData: return "Cannot decode image data"
        case .cannotCreatePixelBuffer: return "Cannot create pixel buffer"
        }
    }
}

/// Read-only image decode via ImageIO. All bytes are read through `SourceAccess`, and decoding never
/// writes back to the source file. Detection runs on a downsampled copy to stay fast on 100k+ photos.
public enum ImageLoader {
    /// Decode an image, optionally downsampling so the longest edge is `maxPixelSize`.
    public static func load(_ url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        try decode(try source(for: url), maxPixelSize: maxPixelSize)
    }

    /// Read a source file's bytes (read-only) into a reusable `CGImageSource`. Building this once and
    /// passing it to `decode`/`metadata`/`dHash` means a photo is read from disk exactly once per scan
    /// instead of 3–4 times — the main per-photo I/O cost on large libraries.
    public static func source(for url: URL) throws -> CGImageSource {
        let data = try SourceAccess.read(url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageError.cannotDecode(url)
        }
        return source
    }

    /// Decode (optionally downsampling so the longest edge is `maxPixelSize`) from an existing source.
    public static func decode(_ source: CGImageSource, maxPixelSize: Int? = nil) throws -> CGImage {
        let image: CGImage?
        if let maxPixelSize {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,   // respect EXIF orientation
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: false,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        guard let image else { throw ImageError.cannotDecodeData }
        return image
    }

    public struct Metadata: Sendable, Equatable {
        public var takenAt: Double?     // EXIF DateTimeOriginal (epoch seconds, local tz)
        public var gpsLat: Double?      // signed (S/W negative) — drives the Places category
        public var gpsLon: Double?
        public var width: Int?
        public var height: Int?
    }

    /// Read capture date, GPS, and pixel size from a photo's header — no full decode. Drives the
    /// Places category (GPS) and date-sorted browsing (takenAt). Read-only; never writes the file.
    public static func metadata(_ url: URL) -> Metadata {
        (try? source(for: url)).map(metadata(source:)) ?? Metadata()
    }

    /// Header metadata from an already-read source (no re-read).
    public static func metadata(source: CGImageSource) -> Metadata {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return Metadata() }

        var m = Metadata()
        m.width = props[kCGImagePropertyPixelWidth] as? Int
        m.height = props[kCGImagePropertyPixelHeight] as? Int

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let lat = gps[kCGImagePropertyGPSLatitude] as? Double {
                m.gpsLat = (gps[kCGImagePropertyGPSLatitudeRef] as? String == "S") ? -lat : lat
            }
            if let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
                m.gpsLon = (gps[kCGImagePropertyGPSLongitudeRef] as? String == "W") ? -lon : lon
            }
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            m.takenAt = exifDate(s)
        }
        return m
    }

    /// 64-bit perceptual difference-hash (dHash): downscale to 9×8 grayscale, then for each row emit
    /// a bit per adjacent-pixel comparison. Robust to resize/recompression, so near-equal hashes mean
    /// the same photo (duplicate/burst). Hamming distance between two hashes = how different they are.
    public static func dHash(_ url: URL) -> Int64? {
        (try? source(for: url)).flatMap(dHash(source:))
    }

    /// dHash from an already-read source (no re-read).
    public static func dHash(source src: CGImageSource) -> Int64? {
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 32,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }

        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var hash: UInt64 = 0, bit: UInt64 = 0
        for row in 0..<h {
            for col in 0..<(w - 1) {
                if pixels[row * w + col] > pixels[row * w + col + 1] { hash |= (1 << bit) }
                bit += 1
            }
        }
        return Int64(bitPattern: hash)
    }

    /// Bit difference between two perceptual hashes (0 = identical).
    public static func hammingDistance(_ a: Int64, _ b: Int64) -> Int {
        (UInt64(bitPattern: a) ^ UInt64(bitPattern: b)).nonzeroBitCount
    }

    /// Parse an EXIF "yyyy:MM:dd HH:mm:ss" timestamp. EXIF carries no timezone, so assume local.
    static func exifDate(_ s: String) -> Double? {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)?.timeIntervalSince1970
    }

    /// Write a CGImage to a PNG (used by tests and, later, the thumbnail cache — NEVER the source tree).
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageError.cannotDecode(url)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ImageError.cannotDecode(url) }
    }
}
