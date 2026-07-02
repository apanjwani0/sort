import Foundation

/// Creates and resolves **read-write** security-scoped bookmarks so a folder/SSD the user grants
/// (via NSOpenPanel) survives relaunches under the App Sandbox — read + write (so photos can be moved
/// to the Trash), with no re-prompting and no Full Disk Access.
public enum BookmarkStore {
    /// Create a read-write security-scoped bookmark for a user-granted folder URL.
    public static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public struct Resolved: Sendable {
        public var url: URL
        public var isStale: Bool
    }

    /// Resolve a bookmark back to a URL. `isStale` means the bookmark should be recreated
    /// (e.g. the SSD was reformatted or the folder moved).
    public static func resolve(_ data: Data) throws -> Resolved {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return Resolved(url: url, isStale: stale)
    }
}
