import Foundation
import CoreServices

/// Wraps FSEventStreamCreate. Watches the given paths recursively and
/// delivers coalesced change events on the main queue with a configurable
/// latency (kernel-level debouncing).
final class FSEventsWatcher {
    typealias EventHandler = (_ paths: [String]) -> Void

    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let latency: CFTimeInterval
    private let handler: EventHandler
    private var lastEventId: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)

    init(paths: [String], latency: CFTimeInterval = 0.15, handler: @escaping EventHandler) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    func start() {
        guard stream == nil else { return }
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // UseCFTypes → eventPaths is a CFArray of CFStrings (clean Swift bridge)
        // FileEvents → per-file granularity (not just directory coalesced)
        // NoDefer → deliver the first event immediately, latency is only for
        //           subsequent coalescing within the window
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info = info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            // With UseCFTypes, eventPaths is a CFArrayRef of CFStrings.
            let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
            let paths = (cfArray as NSArray).compactMap { $0 as? String }
            if !paths.isEmpty {
                watcher.handler(paths)
            }
            _ = numEvents
        }

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            lastEventId,
            latency,
            flags
        ) else {
            return
        }

        stream = newStream
        FSEventStreamSetDispatchQueue(newStream, DispatchQueue.main)
        FSEventStreamStart(newStream)
    }

    func stop() {
        guard let s = stream else { return }
        lastEventId = FSEventStreamGetLatestEventId(s)
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
