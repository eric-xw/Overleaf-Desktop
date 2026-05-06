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
    let inConflict: Bool
}

enum PullOutcome {
    case upToDate
    case fastForward(String)
    case rebased(String)
    case conflict(files: [String])
}

enum GitError: LocalizedError {
    case noToken
    case commandFailed(String)
    case invalidPath
    case stillConflicted(files: [String])
    var errorDescription: String? {
        switch self {
        case .noToken: return "No Overleaf Git token saved. Open Settings to add one."
        case .commandFailed(let msg): return msg
        case .invalidPath: return "Invalid local path."
        case .stillConflicted(let files):
            return "These files still have unresolved conflict markers:\n  " + files.joined(separator: "\n  ")
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

    /// Pulls with rebase + autostash. Returns a structured outcome including whether
    /// a conflict occurred so the UI can route to the resolution sheet.
    static func pull(at path: URL) throws -> PullOutcome {
        guard let token = KeychainService.loadToken() else { throw GitError.noToken }
        let result = run(["pull", "--rebase", "--autostash"], cwd: path, withToken: token)
        if result.ok {
            let combined = result.combined
            if combined.contains("Already up to date") || combined.contains("Already up-to-date") {
                return .upToDate
            }
            if combined.lowercased().contains("fast-forward") {
                return .fastForward(combined)
            }
            return .rebased(combined)
        }
        // Failed — check whether we landed in a conflict state.
        if isInConflict(at: path) {
            return .conflict(files: conflictedFiles(at: path))
        }
        throw GitError.commandFailed("git pull failed:\n\(result.combined)")
    }

    static func push(at path: URL) throws -> String {
        guard let token = KeychainService.loadToken() else { throw GitError.noToken }
        let result = run(["push"], cwd: path, withToken: token)
        if !result.ok { throw GitError.commandFailed("git push failed:\n\(result.combined)") }
        return result.combined
    }

    /// Stages everything, commits if there's anything to commit, and returns whether a commit was made.
    static func commitAll(at path: URL, message: String) throws -> Bool {
        let addResult = run(["add", "-A"], cwd: path, withToken: nil)
        if !addResult.ok { throw GitError.commandFailed("git add failed:\n\(addResult.combined)") }

        let statusResult = run(["status", "--porcelain"], cwd: path, withToken: nil)
        if statusResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }

        let commitResult = run(["commit", "-m", message], cwd: path, withToken: nil)
        if !commitResult.ok { throw GitError.commandFailed("git commit failed:\n\(commitResult.combined)") }
        return true
    }

    static func status(at path: URL) -> GitStatus {
        let isRepoResult = run(["rev-parse", "--is-inside-work-tree"], cwd: path, withToken: nil)
        guard isRepoResult.ok else {
            return GitStatus(isRepo: false, dirty: false, ahead: 0, behind: 0, branch: "", inConflict: false)
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
        return GitStatus(isRepo: true, dirty: dirty, ahead: ahead, behind: behind, branch: branch, inConflict: isInConflict(at: path))
    }

    // MARK: - Conflict handling

    static func isInConflict(at path: URL) -> Bool {
        let gitDir = path.appendingPathComponent(".git", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-merge").path) { return true }
        if fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-apply").path) { return true }
        if fm.fileExists(atPath: gitDir.appendingPathComponent("MERGE_HEAD").path) { return true }
        // Also: any unmerged paths reported by git
        let result = run(["diff", "--name-only", "--diff-filter=U"], cwd: path, withToken: nil)
        return result.ok && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func conflictedFiles(at path: URL) -> [String] {
        let result = run(["diff", "--name-only", "--diff-filter=U"], cwd: path, withToken: nil)
        guard result.ok else { return [] }
        return result.stdout
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Continue an in-progress rebase. Throws if files still have unresolved conflicts.
    static func rebaseContinue(at path: URL) throws -> String {
        guard let token = KeychainService.loadToken() else { throw GitError.noToken }
        // Stage everything first so the user doesn't have to remember.
        let addResult = run(["add", "-A"], cwd: path, withToken: nil)
        if !addResult.ok { throw GitError.commandFailed("git add failed:\n\(addResult.combined)") }

        let unresolved = conflictedFiles(at: path)
        if !unresolved.isEmpty {
            throw GitError.stillConflicted(files: unresolved)
        }

        var env = ProcessInfo.processInfo.environment
        env["GIT_EDITOR"] = "true" // accept the default commit message non-interactively
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rebase", "--continue"]
        process.currentDirectoryURL = path
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = ""
        _ = token // unused for the continue itself
        process.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch {
            throw GitError.commandFailed("git rebase --continue launch failed: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            // Could still be in conflict if `git add -A` swept in something that re-conflicted (rare)
            if isInConflict(at: path) {
                throw GitError.stillConflicted(files: conflictedFiles(at: path))
            }
            throw GitError.commandFailed("git rebase --continue failed:\n\(stdout)\n\(stderr)")
        }
        return stdout + "\n" + stderr
    }

    /// Abort an in-progress rebase or merge, restoring the pre-pull working tree.
    static func rebaseAbort(at path: URL) throws -> String {
        let gitDir = path.appendingPathComponent(".git", isDirectory: true)
        let fm = FileManager.default
        let isRebase = fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-merge").path)
            || fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-apply").path)
        let args = isRebase ? ["rebase", "--abort"] : ["merge", "--abort"]
        let result = run(args, cwd: path, withToken: nil)
        if !result.ok { throw GitError.commandFailed("git \(args.joined(separator: " ")) failed:\n\(result.combined)") }
        return result.combined
    }
}
