import Foundation
import Combine

/// State per project visible to the UI.
struct SyncState: Equatable {
    var busy: Bool = false
    var inConflict: Bool = false
    var conflictedFiles: [String] = []
    var lastError: String?
    var lastEvent: String?       // human-readable last sync event
    var lastEventAt: Date?
}

@MainActor
final class AutoSyncManager: ObservableObject {
    /// State by project id. UI observes this dictionary for changes.
    @Published private(set) var states: [UUID: SyncState] = [:]

    private weak var store: ProjectStore?
    private var watchers: [UUID: FSEventsWatcher] = [:]
    private var pullLoopTask: Task<Void, Never>?
    private var settingsObserver: AnyCancellable?

    init(store: ProjectStore) {
        self.store = store
        // Initialize empty state for any pre-existing projects.
        for project in store.projects {
            states[project.id] = SyncState()
            refreshConflictState(project)
        }
        applySettings()

        // Re-evaluate watchers / pull loop whenever settings or project list change.
        settingsObserver = Publishers.CombineLatest3(
            store.$projects,
            store.$autoPullOnInterval,
            store.$autoPushOnSave
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _ in
            self?.applySettings()
        }
    }

    // MARK: - Public actions

    func pull(_ project: Project, source: SyncSource = .manual) async {
        guard acquireLock(project) else { return }
        defer { releaseLock(project) }

        do {
            let outcome = try await runDetached { try GitService.pull(at: project.localURL) }
            switch outcome {
            case .upToDate:
                if source == .manual {
                    setEvent(project, "Already up to date")
                }
            case .fastForward(_), .rebased(_):
                setEvent(project, "Pulled new changes")
            case .conflict(let files):
                setConflict(project, files: files,
                            error: "Pull paused: conflicts in \(files.count) file\(files.count == 1 ? "" : "s").")
                return
            }
            store?.touchSync(project)
            updateState(project) { $0.lastError = nil }
        } catch let error as GitError {
            updateState(project) { $0.lastError = error.errorDescription }
        } catch {
            updateState(project) { $0.lastError = error.localizedDescription }
        }
    }

    func push(_ project: Project, source: SyncSource = .manual, autoCommit: Bool = true) async {
        guard acquireLock(project) else { return }
        defer { releaseLock(project) }

        do {
            if autoCommit {
                let didCommit = try await runDetached {
                    try GitService.commitAll(at: project.localURL,
                                             message: source == .auto ? "Auto-sync from Overleaf Desktop" : "Update from Overleaf Desktop")
                }
                if !didCommit && source == .auto {
                    // Nothing to push, no event noise.
                    return
                }
            }
            _ = try await runDetached { try GitService.push(at: project.localURL) }
            setEvent(project, source == .auto ? "Auto-pushed" : "Pushed")
            store?.touchSync(project)
            updateState(project) { $0.lastError = nil }
        } catch let error as GitError {
            // A push failure on a non-fast-forward is the typical "someone else committed" case.
            // Try a pull, then re-push, but only on auto-push (manual users probably want to know).
            if source == .auto, let msg = error.errorDescription, msg.contains("non-fast-forward") || msg.contains("rejected") {
                releaseLock(project)
                await pull(project, source: .auto)
                await push(project, source: .auto, autoCommit: false)
                return
            }
            updateState(project) { $0.lastError = error.errorDescription }
        } catch {
            updateState(project) { $0.lastError = error.localizedDescription }
        }
    }

    func continueRebase(_ project: Project) async {
        guard acquireLock(project) else { return }
        defer { releaseLock(project) }

        do {
            _ = try await runDetached { try GitService.rebaseContinue(at: project.localURL) }
            // Refresh conflict state.
            let stillConflict = await runDetached { GitService.isInConflict(at: project.localURL) }
            updateState(project) {
                $0.inConflict = stillConflict
                $0.conflictedFiles = stillConflict ? GitService.conflictedFiles(at: project.localURL) : []
                $0.lastError = nil
            }
            if !stillConflict {
                setEvent(project, "Conflict resolved")
                store?.touchSync(project)
            }
        } catch let error as GitError {
            if case .stillConflicted(let files) = error {
                setConflict(project, files: files, error: error.errorDescription)
            } else {
                updateState(project) { $0.lastError = error.errorDescription }
            }
        } catch {
            updateState(project) { $0.lastError = error.localizedDescription }
        }
    }

    func abortRebase(_ project: Project) async {
        guard acquireLock(project) else { return }
        defer { releaseLock(project) }
        do {
            _ = try await runDetached { try GitService.rebaseAbort(at: project.localURL) }
            updateState(project) {
                $0.inConflict = false
                $0.conflictedFiles = []
                $0.lastError = nil
                $0.lastEvent = "Pull aborted; local changes restored"
                $0.lastEventAt = Date()
            }
        } catch {
            updateState(project) { $0.lastError = error.localizedDescription }
        }
    }

    /// Re-check whether a project is currently in conflict (e.g. on startup).
    func refreshConflictState(_ project: Project) {
        let inConflict = GitService.isInConflict(at: project.localURL)
        let files = inConflict ? GitService.conflictedFiles(at: project.localURL) : []
        updateState(project) {
            $0.inConflict = inConflict
            $0.conflictedFiles = files
        }
    }

    // MARK: - Settings application

    private func applySettings() {
        guard let store else { return }
        // Ensure each project has a state entry.
        for project in store.projects where states[project.id] == nil {
            states[project.id] = SyncState()
            refreshConflictState(project)
        }
        // Drop entries for projects that were removed.
        let liveIDs = Set(store.projects.map(\.id))
        states = states.filter { liveIDs.contains($0.key) }

        // Pull loop
        if store.autoPullOnInterval {
            startPullLoop(intervalSeconds: max(10, store.autoPullIntervalSeconds))
        } else {
            stopPullLoop()
        }

        // File watchers
        if store.autoPushOnSave {
            for project in store.projects {
                ensureWatcher(for: project)
            }
            // Drop watchers for removed projects
            let removed = Set(watchers.keys).subtracting(liveIDs)
            for id in removed {
                watchers.removeValue(forKey: id)
            }
        } else {
            watchers.removeAll()
        }
    }

    private func startPullLoop(intervalSeconds: Double) {
        pullLoopTask?.cancel()
        pullLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
                if Task.isCancelled { return }
                guard let self else { return }
                guard let projects = await self.currentProjects() else { return }
                for project in projects {
                    let inConflict = await self.isInConflict(project.id)
                    if inConflict { continue }
                    await self.pull(project, source: .auto)
                }
            }
        }
    }

    private func stopPullLoop() {
        pullLoopTask?.cancel()
        pullLoopTask = nil
    }

    private func ensureWatcher(for project: Project) {
        if watchers[project.id] != nil { return }
        let id = project.id
        let watcher = FSEventsWatcher(path: project.localPath, debounceSeconds: 3.0) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let p = self.store?.projects.first(where: { $0.id == id }) else { return }
                let state = self.states[id] ?? SyncState()
                if state.inConflict || state.busy { return }
                await self.push(p, source: .auto)
            }
        }
        watchers[project.id] = watcher
    }

    // MARK: - State helpers

    private func acquireLock(_ project: Project) -> Bool {
        var s = states[project.id] ?? SyncState()
        if s.busy { return false }
        s.busy = true
        states[project.id] = s
        return true
    }

    private func releaseLock(_ project: Project) {
        var s = states[project.id] ?? SyncState()
        s.busy = false
        states[project.id] = s
    }

    private func setEvent(_ project: Project, _ message: String) {
        updateState(project) {
            $0.lastEvent = message
            $0.lastEventAt = Date()
        }
    }

    private func setConflict(_ project: Project, files: [String], error: String?) {
        updateState(project) {
            $0.inConflict = true
            $0.conflictedFiles = files
            $0.lastError = error
        }
    }

    private func updateState(_ project: Project, _ mutate: (inout SyncState) -> Void) {
        var s = states[project.id] ?? SyncState()
        mutate(&s)
        states[project.id] = s
    }

    private func currentProjects() async -> [Project]? {
        store?.projects
    }

    private func isInConflict(_ id: UUID) async -> Bool {
        states[id]?.inConflict ?? false
    }

    private func runDetached<T: Sendable>(_ body: @Sendable @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try body()
        }.value
    }

    private func runDetached<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
        await Task.detached(priority: .userInitiated) {
            body()
        }.value
    }
}

enum SyncSource {
    case manual
    case auto
}
