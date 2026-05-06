import Foundation
import Combine

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []

    @Published var autoPullOnLaunch: Bool {
        didSet { UserDefaults.standard.set(autoPullOnLaunch, forKey: "autoPullOnLaunch") }
    }

    @Published var autoPullOnInterval: Bool {
        didSet { UserDefaults.standard.set(autoPullOnInterval, forKey: "autoPullOnInterval") }
    }

    @Published var autoPullIntervalSeconds: Double {
        didSet { UserDefaults.standard.set(autoPullIntervalSeconds, forKey: "autoPullIntervalSeconds") }
    }

    @Published var autoPushOnSave: Bool {
        didSet { UserDefaults.standard.set(autoPushOnSave, forKey: "autoPushOnSave") }
    }

    private let storeURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("OverleafDesktop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("projects.json")

        let defaults = UserDefaults.standard
        self.autoPullOnLaunch = defaults.object(forKey: "autoPullOnLaunch") as? Bool ?? false
        self.autoPullOnInterval = defaults.object(forKey: "autoPullOnInterval") as? Bool ?? false
        self.autoPullIntervalSeconds = (defaults.object(forKey: "autoPullIntervalSeconds") as? Double) ?? 30.0
        self.autoPushOnSave = defaults.object(forKey: "autoPushOnSave") as? Bool ?? false

        load()
    }

    func add(_ project: Project) {
        projects.append(project)
        save()
    }

    func update(_ project: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx] = project
        save()
    }

    func remove(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        save()
    }

    func touchSync(_ project: Project) {
        var p = project
        p.lastSync = Date()
        update(p)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        if let decoded = try? JSONDecoder().decode([Project].self, from: data) {
            projects = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(projects) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}
