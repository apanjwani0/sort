import Foundation
import CoreGraphics
@testable import SortKit

enum TestImage {
    /// A solid-color image, optionally with a contrasting square block to add structure.
    static func make(width: Int, height: Int,
                     rgb: (CGFloat, CGFloat, CGFloat),
                     block: (rect: CGRect, rgb: (CGFloat, CGFloat, CGFloat))? = nil) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let block {
            ctx.setFillColor(CGColor(red: block.rgb.0, green: block.rgb.1, blue: block.rgb.2, alpha: 1))
            ctx.fill(block.rect)
        }
        return ctx.makeImage()!
    }
}
