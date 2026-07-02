import Foundation

/// The single sanctioned WRITE to the source tree (decision D7). Everything else stays read-only
/// (`SourceAccess` has no write API). Trashing moves a file to the user's Trash — it never edits a
/// file in place, never renames, and never touches sibling files. Deletions are therefore explicit
/// and recoverable.
///
/// Injectable so tests can verify deletion behavior without polluting the real Trash.
public protocol FileTrashing: Sendable {
    /// Move the file at `url` to the Trash. Returns its new location if the system reports one.
    @discardableResult
    func trash(_ url: URL) throws -> URL?
}

/// Production trasher: macOS Trash (per-volume `.Trashes` for external drives), fully recoverable.
public struct SystemTrash: FileTrashing {
    public init() {}

    @discardableResult
    public func trash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}
