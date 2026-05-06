import Foundation

struct GitResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { exitCode == 0 }
    var combined: String {
        let parts = [stdout, stderr].filter { !$0.isEmpty }
        return parts.joined(separator: "\n")
    }
}

struct GitStatus {
    let isRepo: Bool
    let dirty: Bool
    let ahead: Int
    let behind: Int
    let branch: String
}

enum GitError: LocalizedError {
    case noToken
    case commandFailed(String)
    case invalidPath
    var errorDescription: String? {
        switch self {
        case .noToken: return "No Overleaf Git token saved. Open Settings to add one."
        case .commandFailed(let msg): return msg
        case .invalidPath: return "Invalid local path."
        }
    }
}

enum GitService {
    private static func makeAskpassScript() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("overleaf-askpass-\(UUID().uuidString).sh")
        let body = "#!/bin/sh\nprintf '%s' \"$OVERLEAF_GIT_TOKEN\"\n"
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp.path)
        return tmp
    }

    private static func run(_ args: [String], cwd: URL?, withToken token: String?) -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }

        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"

        var askpassURL: URL?
        if let token {
            do {
                let url = try makeAskpassScript()
                askpassURL = url
                env["GIT_ASKPASS"] = url.path
                env["OVERLEAF_GIT_TOKEN"] = token
            } catch {
                return GitResult(exitCode: -1, stdout: "", stderr: "askpass setup failed: \(error.localizedDescription)")
            }
        }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return GitResult(exitCode: -1, stdout: "", stderr: "git launch failed: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        if let askpassURL { try? FileManager.default.removeItem(at: askpassURL) }

        return GitResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    static func clone(remote: String, into parent: URL, name: String) throws -> URL {
        guard let token = KeychainService.loadToken() else { throw GitError.noToken }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) {
            throw GitError.commandFailed("A folder already exists at \(target.path)")
        }
        let result = run(["clone", remote, target.path], cwd: parent, withToken: token)
        if !result.ok {
            throw GitError.commandFailed("git clone failed:\n\(result.combined)")
        }
        return target
    }

    static func pull(at path: URL) throws -> String {
        guard let token = KeychainService.loadToken() else { throw GitError.noToken }
        let result = run(["pull", "--rebase", "--autostash"], cwd: path, withToken: token)
        if !result.ok { throw GitError.commandFailed("git pull failed:\n\(result.combined)") }
        return result.combined
    }

    static func push(at path: URL) throws -> String {
        guard let token = KeychainService.loadToken() else { throw GitError.noToken }
        let result = run(["push"], cwd: path, withToken: token)
        if !result.ok { throw GitError.commandFailed("git push failed:\n\(result.combined)") }
        return result.combined
    }

    static func commitAll(at path: URL, message: String) throws -> String {
        let addResult = run(["add", "-A"], cwd: path, withToken: nil)
        if !addResult.ok { throw GitError.commandFailed("git add failed:\n\(addResult.combined)") }

        let statusResult = run(["status", "--porcelain"], cwd: path, withToken: nil)
        if statusResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Nothing to commit."
        }

        let commitResult = run(["commit", "-m", message], cwd: path, withToken: nil)
        if !commitResult.ok { throw GitError.commandFailed("git commit failed:\n\(commitResult.combined)") }
        return commitResult.combined
    }

    static func status(at path: URL) -> GitStatus {
        let isRepoResult = run(["rev-parse", "--is-inside-work-tree"], cwd: path, withToken: nil)
        guard isRepoResult.ok else {
            return GitStatus(isRepo: false, dirty: false, ahead: 0, behind: 0, branch: "")
        }

        let branchResult = run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: path, withToken: nil)
        let branch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let porcelain = run(["status", "--porcelain"], cwd: path, withToken: nil)
        let dirty = !porcelain.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let counts = run(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], cwd: path, withToken: nil)
        var ahead = 0
        var behind = 0
        if counts.ok {
            let parts = counts.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
            if parts.count == 2 {
                ahead = Int(parts[0]) ?? 0
                behind = Int(parts[1]) ?? 0
            }
        }
        return GitStatus(isRepo: true, dirty: dirty, ahead: ahead, behind: behind, branch: branch)
    }
}
