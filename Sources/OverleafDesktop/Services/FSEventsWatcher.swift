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

        let callback: FSEventStreamCallback = { (_, info, _, eventPaths, _, _) in
            guard let info = info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()

            // The CFArray that FSEvents hands us, and the CFString path elements
            // inside it, are only guaranteed valid for the duration of this
            // callback. Lazy ObjC→Swift bridging via `as? [String]` defers the
            // per-element bridge until access time — by which point the C string
            // buffers have already been freed, causing EXC_BAD_ACCESS in
            // objc_msgSend. We must copy each path into Swift-owned storage
            // eagerly, inside the callback scope.
            //
            // Bug report: https://github.com/eric-xw/Overleaf-Desktop/issues/1
            let nsArray = unsafeBitCast(eventPaths, to: NSArray.self)
            let paths: [String] = nsArray.compactMap { elem in
                guard let nsStr = elem as? NSString else { return nil }
                return String(nsStr)   // initializer copies bytes into Swift String storage
            }

            // Filter out .git/ traffic so that our own commits don't loop back.
            let interesting = paths.contains { p in
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
