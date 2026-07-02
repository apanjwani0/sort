import Foundation
import CoreGraphics

/// Produces a normalized square face crop.
///
/// `embeddingCrop` warps the face onto the canonical 112×112 ArcFace 5-point template via a
/// least-squares similarity transform (rotation + uniform scale + translation) — this is what
/// ArcFace was trained on; an unaligned bbox crop wrecks identity separation. `alignedCrop` keeps the
/// looser bbox-plus-margin crop for display (avatars), where canonical alignment isn't needed.
public struct FaceAligner: Sendable {
    public var outputSize: Int
    public var margin: CGFloat

    public init(outputSize: Int = 112, margin: CGFloat = 0.2) {
        self.outputSize = outputSize
        self.margin = margin
    }

    /// ArcFace canonical 5-point destination, defined for a 112×112 crop (top-left origin):
    /// image-left eye, image-right eye, nose, image-left mouth corner, image-right mouth corner.
    static let template112: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366), CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// Pet 3-point template (left eye, right eye, nose) in a 112×112 crop (top-left origin).
    static let petTemplate3: [CGPoint] = [
        CGPoint(x: 38, y: 48), CGPoint(x: 74, y: 48), CGPoint(x: 56, y: 78),
    ]

    /// Aligned pet-face crop from 3 head joints (eyes + nose). Points are Vision-normalized
    /// (origin bottom-left, as `VNDetectAnimalBodyPoseRequest` returns them). Mirrors `embeddingCrop`
    /// but with a 3-point template — there's no pet mouth landmark.
    public func petCrop(from image: CGImage, leftEye: CGPoint, rightEye: CGPoint, nose: CGPoint) -> CGImage? {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let s = CGFloat(outputSize) / 112.0
        let eyes = [leftEye, rightEye].sorted { $0.x < $1.x }   // assign by image x
        let src = [eyes[0], eyes[1], nose].map { CGPoint(x: $0.x * W, y: $0.y * H) }   // bottom-left px
        let dst = Self.petTemplate3.map { CGPoint(x: $0.x * s, y: CGFloat(outputSize) - $0.y * s) }
        guard let t = Self.similarityTransform(from: src, to: dst) else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: outputSize, height: outputSize, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.concatenate(t)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        return ctx.makeImage()
    }

    /// Aligned crop for the embedder: similarity-warp the 5 landmarks onto the ArcFace template.
    /// Falls back to the bbox crop when landmarks are missing or the transform is degenerate.
    public func embeddingCrop(from image: CGImage, face: DetectedFace) -> CGImage? {
        guard let lm = face.landmarks5, lm.count == 5 else { return alignedCrop(from: image, face: face) }
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let s = CGFloat(outputSize) / 112.0

        // landmarks5 (top-left normalized) order = [leftEye, rightEye, nose, leftMouth, rightMouth] by
        // Vision's *anatomical* naming, which is mirrored vs the template's *image-side* convention.
        // Assign eyes & mouth corners by image x so a frontal face can't get flipped/rotated 180°.
        let eyes = [lm[0], lm[1]].sorted { $0.x < $1.x }
        let mouth = [lm[3], lm[4]].sorted { $0.x < $1.x }
        let srcNorm = [eyes[0], eyes[1], lm[2], mouth[0], mouth[1]]

        // Both sides into CGContext bottom-left pixel space.
        let src = srcNorm.map { CGPoint(x: $0.x * W, y: (1 - $0.y) * H) }
        let dst = Self.template112.map { CGPoint(x: $0.x * s, y: CGFloat(outputSize) - $0.y * s) }

        guard let t = Self.similarityTransform(from: src, to: dst) else {
            return alignedCrop(from: image, face: face)
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: outputSize, height: outputSize, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.concatenate(t)           // maps source pixels → template positions
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        return ctx.makeImage()
    }

    /// Least-squares 2D similarity transform mapping `src` onto `dst` (no reflection). Solves for
    /// p = [a, b, tx, ty] where dst.x = a·x − b·y + tx and dst.y = b·x + a·y + ty.
    static func similarityTransform(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform? {
        guard src.count == dst.count, src.count >= 2 else { return nil }
        var ata = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        var atb = [Double](repeating: 0, count: 4)
        func accumulate(_ row: [Double], _ target: Double) {
            for i in 0..<4 {
                atb[i] += row[i] * target
                for j in 0..<4 { ata[i][j] += row[i] * row[j] }
            }
        }
        for k in 0..<src.count {
            let x = Double(src[k].x), y = Double(src[k].y)
            accumulate([x, -y, 1, 0], Double(dst[k].x))
            accumulate([y,  x, 0, 1], Double(dst[k].y))
        }
        guard let p = solve4x4(ata, atb) else { return nil }
        return CGAffineTransform(a: p[0], b: p[1], c: -p[1], d: p[0], tx: p[2], ty: p[3])
    }

    /// Gaussian elimination with partial pivoting for a 4×4 system. Returns nil if singular.
    static func solve4x4(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        var a = matrix, b = rhs
        for col in 0..<4 {
            var pivot = col
            for r in (col + 1)..<4 where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
            guard abs(a[pivot][col]) > 1e-12 else { return nil }
            if pivot != col { a.swapAt(pivot, col); b.swapAt(pivot, col) }
            let d = a[col][col]
            for r in 0..<4 where r != col {
                let f = a[r][col] / d
                guard f != 0 else { continue }
                for c in col..<4 { a[r][c] -= f * a[col][c] }
                b[r] -= f * b[col]
            }
        }
        return (0..<4).map { b[$0] / a[$0][$0] }
    }

    public func alignedCrop(from image: CGImage, face: DetectedFace) -> CGImage? {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let bb = face.boundingBox

        // Vision bbox → pixel rect (origin bottom-left), expanded by margin.
        var x = bb.minX * W
        var yBottom = bb.minY * H
        var bw = bb.width * W
        var bh = bb.height * H
        let mx = bw * margin, my = bh * margin
        x -= mx; yBottom -= my; bw += 2 * mx; bh += 2 * my

        // Convert to top-left origin for CGImage cropping, then clamp to the image.
        var rect = CGRect(x: x, y: H - (yBottom + bh), width: bw, height: bh)
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        rect = rect.integral

        guard let cropped = image.cropping(to: rect) else { return nil }
        return Self.resize(cropped, to: outputSize)
    }

    static func resize(_ image: CGImage, to side: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }
}
