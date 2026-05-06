import Foundation

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var overleafID: String
    var name: String
    var localPath: String
    var lastSync: Date?

    init(id: UUID = UUID(), overleafID: String, name: String, localPath: String, lastSync: Date? = nil) {
        self.id = id
        self.overleafID = overleafID
        self.name = name
        self.localPath = localPath
        self.lastSync = lastSync
    }

    var localURL: URL { URL(fileURLWithPath: localPath) }

    var gitRemoteURL: String { "https://git@git.overleaf.com/\(overleafID)" }

    var webURL: String { "https://www.overleaf.com/project/\(overleafID)" }
}
