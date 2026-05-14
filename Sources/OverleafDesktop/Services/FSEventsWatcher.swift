import Foundation
import CoreFoundation
import CoreServices

/// Watches a directory tree (recursively) for any filesystem change.
/// Coalesces bursts of events and calls `onSettled` after `debounceSeconds`
/// of filesystem quiet. Ignores `.git/` paths so commits don't retrigger.
final class FSEventsWatcher {
    private var stream: FSEventStreamRef?

    /// FSEvents expects `Stop` / `Invalidate` / `Release` on the **same** dispatch queue used for delivery.
    private let watcherQueue = DispatchQueue(label: "com.local.overleafdesktop.fsevents")
    private let watcherQueueMarker = NSObject()

    private let path: String
    private let debounceSeconds: TimeInterval
    private let onSettled: () -> Void
    private var debounceTask: Task<Void, Never>?

    init(path: String, debounceSeconds: TimeInterval = 3.0, onSettled: @escaping () -> Void) {
        self.path = path
        self.debounceSeconds = debounceSeconds
        self.onSettled = onSettled

        watcherQueue.setSpecific(key: watcherQueueIdentityKey, value: watcherQueueMarker)
        watcherQueue.sync { setupStream_onWatcherQueue() }
    }

    deinit {
        stop()
    }

    /// Must run exclusively on `watcherQueue`.
    private func setupStream_onWatcherQueue() {
        guard stream == nil else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (_, info, numEvents, eventPathsRaw, _, _) in
            guard let info else { return }
            guard numEvents > 0 else { return }
            guard UInt(bitPattern: eventPathsRaw) != 0 else { return }

            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()

            // Path strings only live for this callback — copy eagerly (no lazy ObjC bridging).
            // https://github.com/eric-xw/Overleaf-Desktop/issues/1
            let cfArray = unsafeBitCast(eventPathsRaw, to: CFArray.self)
            let count = CFArrayGetCount(cfArray)
            guard count > 0 else { return }

            let limit = min(Int(count), Int(numEvents))
            var paths: [String] = []
            paths.reserveCapacity(limit)
            for i in 0 ..< limit {
                guard let elem = CFArrayGetValueAtIndex(cfArray, CFIndex(i)) else { continue }
                guard CFGetTypeID(unsafeBitCast(elem, to: CFTypeRef.self)) == CFStringGetTypeID() else { continue }
                let cfStr = unsafeBitCast(elem, to: CFString.self)
                paths.append(String(cfStr))
            }

            let interesting = paths.contains { p in
                let lower = p.lowercased()
                return !lower.contains("/.git/") && !lower.hasSuffix("/.git")
            }
            if interesting {
                watcher.scheduleSettle()
            }
        }

        let pathsToWatch = [path] as CFArray
        // Without `UseCFTypes`, paths may be legacy Carbon types (wrapped C strings), not CFStringRefs.
        // Treating those as CFString + bridging to Swift `String` faults in objc_msgSend(retain).
        let flags: UInt32 = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
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

        FSEventStreamSetDispatchQueue(s, watcherQueue)
        FSEventStreamStart(s)
        stream = s
    }

    /// Tear down delivery on `watcherQueue` (avoid races with concurrent callbacks).
    private func stop() {
        debounceTask?.cancel()
        debounceTask = nil

        let s = stream
        stream = nil
        guard let s else { return }

        let teardown = {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }

        if DispatchQueue.getSpecific(key: watcherQueueIdentityKey) === watcherQueueMarker {
            teardown()
        } else {
            watcherQueue.sync(execute: teardown)
        }
    }

    fileprivate func scheduleSettle() {
        debounceTask?.cancel()
        let delay = debounceSeconds
        let action = onSettled
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { action() }
        }
    }
}

private let watcherQueueIdentityKey = DispatchSpecificKey<NSObject>()
