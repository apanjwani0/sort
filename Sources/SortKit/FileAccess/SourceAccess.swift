import Foundation

/// The read-only boundary. **The central promise of `sort`: source files are never written,
/// moved, renamed, or deleted, and no sidecar files are ever created inside a scanned tree.**
///
/// All access to a user's photos goes through here. There is intentionally no write method.
public enum SourceAccess {
    /// Read a source file's bytes without mutating it (read-only memory map when safe).
    public static func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url, options: .mappedIfSafe)
    }
}
