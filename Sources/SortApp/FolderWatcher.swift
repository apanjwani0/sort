import Foundation
import CoreServices

/// Watches folders for on-disk changes via FSEvents and fires a debounced callback — used to
/// auto-rescan tracked sources while the app is open (the "watch sources" setting). The callback runs
/// on the FSEvents queue; callers hop to their own actor. `@unchecked Sendable`: the stream is created
/// on `start`/torn down on `stop` (main), and events are delivered on the private serial `queue`.
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.apanjwani.sort.folderwatcher")
    private var debounce: DispatchWorkItem?
    private let latency: CFTimeInterval
    private let debounceSeconds: TimeInterval
    private let onChange: @Sendable ([String]) -> Void

    /// `onChange` is called with the changed paths after `debounceSeconds` of quiet — a burst (e.g.
    /// copying many files) coalesces into a single callback.
    init(latency: CFTimeInterval = 1.0, debounceSeconds: TimeInterval = 2.0,
         onChange: @escaping @Sendable ([String]) -> Void) {
        self.latency = latency
        self.debounceSeconds = debounceSeconds
        self.onChange = onChange
    }

    func start(paths: [String]) {
        stop()
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, fsEventsCallback, &ctx, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        debounce?.cancel()
        debounce = nil
    }

    deinit { stop() }

    /// Called from the FSEvents queue for each change batch; debounces before invoking `onChange`.
    fileprivate func handle(paths changed: [String]) {
        debounce?.cancel()
        let cb = onChange
        let work = DispatchWorkItem { cb(changed) }
        debounce = work
        queue.asyncAfter(deadline: .now() + debounceSeconds, execute: work)
    }
}

/// Non-capturing C callback. With `UseCFTypes`, `eventPaths` is a CFArray of CFString.
private func fsEventsCallback(stream: ConstFSEventStreamRef, info: UnsafeMutableRawPointer?,
                              count: Int, eventPaths: UnsafeMutableRawPointer,
                              flags: UnsafePointer<FSEventStreamEventFlags>,
                              ids: UnsafePointer<FSEventStreamEventId>) {
    guard let info else { return }
    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
    let paths = (unsafeBitCast(eventPaths, to: CFArray.self) as? [String]) ?? []
    watcher.handle(paths: paths)
}
