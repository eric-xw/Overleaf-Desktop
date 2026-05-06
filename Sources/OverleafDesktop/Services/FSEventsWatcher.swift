import Foundation
import CoreServices

/// Watches a directory tree (recursively) for any filesystem change.
/// Coalesces bursts of events and calls `onSettled` after `debounceSeconds`
/// of filesystem quiet. Ignores `.git/` paths so commits don't retrigger.
final class FSEventsWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.local.overleafdesktop.fsevents")
    private let path: String
    private let debounceSeconds: TimeInterval
    private let onSettled: () -> Void
    private var debounceTask: Task<Void, Never>?

    init(path: String, debounceSeconds: TimeInterval = 3.0, onSettled: @escaping () -> Void) {
        self.path = path
        self.debounceSeconds = debounceSeconds
        self.onSettled = onSettled
        start()
    }

    deinit {
        stop()
    }

    private func start() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (_, info, numEvents, eventPaths, _, _) in
            guard let info = info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let pathsArray = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else {
                watcher.scheduleSettle()
                return
            }
            // Filter out .git/ traffic so that our own commits don't loop back.
            let interesting = pathsArray.contains { p in
                let lower = p.lowercased()
                return !lower.contains("/.git/") && !lower.hasSuffix("/.git")
            }
            if interesting {
                watcher.scheduleSettle()
            }
        }

        let pathsToWatch = [path] as CFArray
        let flags: UInt32 = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot
        )
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        self.stream = s
    }

    private func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    fileprivate func scheduleSettle() {
        debounceTask?.cancel()
        let delay = debounceSeconds
        let action = onSettled
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run { action() }
        }
    }
}
