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

    /// Stages everything (excluding embedded git worktrees / nested repos), commits if
    /// there's anything actually staged, and returns whether a commit was made.
    static func commitAll(at path: URL, message: String) throws -> Bool {
        // Build pathspec excludes for embedded git worktrees (e.g. Claude Code's
        // .claude/worktrees/...). `git add -A` would otherwise treat these as gitlinks
        // and either commit phantom submodule pointers or leave the index in a state
        // where the next status check is misleading.
        let embedded = embeddedGitWorktreePaths(at: path)
        var addArgs = ["add", "-A"]
        if !embedded.isEmpty {
            addArgs.append("--")
            for relative in embedded {
                addArgs.append(":(exclude)\(relative)")
            }
        }
        let addResult = run(addArgs, cwd: path, withToken: nil)
        if !addResult.ok { throw GitError.commandFailed("git add failed:\n\(addResult.combined)") }

        // Gate the commit on what's actually STAGED. `git status --porcelain` would also
        // count untracked files (including the worktrees we just excluded above) and lead
        // us to attempt empty commits.
        let stagedResult = run(["diff", "--cached", "--name-only"], cwd: path, withToken: nil)
        if stagedResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }

        let commitResult = run(["commit", "-m", message], cwd: path, withToken: nil)
        if !commitResult.ok { throw GitError.commandFailed("git commit failed:\n\(commitResult.combined)") }
        return true
    }

    /// Parse `git status --porcelain` output and report whether any line refers to a path
    /// outside the given embedded-worktree paths. Used so the dirty/clean badge ignores
    /// nested-repo noise we would never commit anyway.
    static func hasMeaningfulChanges(porcelain: String, excluding embedded: [String]) -> Bool {
        let lines = porcelain
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard !lines.isEmpty else { return false }

        for line in lines {
            // Format: "XY path" — first 2 chars are status codes, then a space, then path.
            // We tolerate any amount of leading whitespace before the path.
            guard line.count > 3 else { continue }
            let pathStart = line.index(line.startIndex, offsetBy: 3)
            var pathPart = String(line[pathStart...])
            // Renames look like "XY old -> new"; only the new name matters for filtering.
            if let arrow = pathPart.range(of: " -> ") {
                pathPart = String(pathPart[arrow.upperBound...])
            }
            // Strip optional surrounding quotes (git quotes paths with special chars).
            if pathPart.hasPrefix("\"") && pathPart.hasSuffix("\"") {
                pathPart = String(pathPart.dropFirst().dropLast())
            }
            let isEmbedded = embedded.contains { embeddedPath in
                pathPart == embeddedPath
                    || pathPart.hasPrefix(embeddedPath + "/")
            }
            if !isEmbedded { return true }
        }
        return false
    }

    /// Returns the relative paths (from `path`) of any embedded git worktrees / nested
    /// repos under the work tree — i.e. directories whose immediate child is a `.git`
    /// file or directory. Excludes the project's own root `.git`.
    static func embeddedGitWorktreePaths(at path: URL) -> [String] {
        // `find . -mindepth 2 -name .git` lists every nested .git, then we strip the
        // trailing "/.git" to get the embedded-repo's parent dir.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        process.arguments = [".", "-mindepth", "2", "-name", ".git", "-not", "-path", "./.git/*"]
        process.currentDirectoryURL = path
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch { return [] }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return stdout
            .split(separator: "\n")
            .map { String($0) }
            .compactMap { line -> String? in
                // line looks like "./.claude/worktrees/foo/.git" — strip leading "./" and trailing "/.git"
                var s = line
                if s.hasPrefix("./") { s.removeFirst(2) }
                guard s.hasSuffix("/.git") else { return nil }
                s.removeLast("/.git".count)
                return s.isEmpty ? nil : s
            }
    }

    static func status(at path: URL) -> GitStatus {
        let isRepoResult = run(["rev-parse", "--is-inside-work-tree"], cwd: path, withToken: nil)
        guard isRepoResult.ok else {
            return GitStatus(isRepo: false, dirty: false, ahead: 0, behind: 0, branch: "", inConflict: false)
        }

        let branchResult = run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: path, withToken: nil)
        let branch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        // "dirty" should reflect whether there's anything we'd actually commit. Filter out
        // lines that refer to embedded git worktrees we exclude from `git add -A`, otherwise
        // a Claude Code worktree leaves the badge stuck on orange forever.
        let porcelain = run(["status", "--porcelain"], cwd: path, withToken: nil)
        let embedded = embeddedGitWorktreePaths(at: path)
        let dirty = hasMeaningfulChanges(porcelain: porcelain.stdout, excluding: embedded)

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

    /// True if `.git/rebase-merge` / `rebase-apply` / `MERGE_HEAD` exists on disk.
    /// Distinct from `isInConflict` because it ignores stray unmerged-index entries.
    static func hasInProgressRebaseOrMerge(at path: URL) -> Bool {
        let gitDir = path.appendingPathComponent(".git", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-merge").path) { return true }
        if fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-apply").path) { return true }
        if fm.fileExists(atPath: gitDir.appendingPathComponent("MERGE_HEAD").path) { return true }
        return false
    }

    /// Continue an in-progress rebase. Returns a human-readable result. If no rebase is
    /// in progress (e.g. the user resolved externally), returns a "nothing to do" message
    /// rather than failing — the manager reconciles UI state by re-checking the disk.
    static func rebaseContinue(at path: URL) throws -> String {
        guard hasInProgressRebaseOrMerge(at: path) else {
            return "No rebase or merge in progress."
        }

        // Stage everything first so the user doesn't have to remember.
        let addResult = run(["add", "-A"], cwd: path, withToken: nil)
        if !addResult.ok { throw GitError.commandFailed("git add failed:\n\(addResult.combined)") }

        let unresolved = conflictedFiles(at: path)
        if !unresolved.isEmpty {
            throw GitError.stillConflicted(files: unresolved)
        }

        var env = ProcessInfo.processInfo.environment
        env["GIT_EDITOR"] = "true" // accept the default commit message non-interactively
        env["GIT_TERMINAL_PROMPT"] = "0"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rebase", "--continue"]
        process.currentDirectoryURL = path
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
            // If the metadata is gone now, the rebase actually finished — treat as success.
            if !hasInProgressRebaseOrMerge(at: path) {
                return stdout + "\n" + stderr
            }
            if isInConflict(at: path) {
                throw GitError.stillConflicted(files: conflictedFiles(at: path))
            }
            throw GitError.commandFailed("git rebase --continue failed:\n\(stdout)\n\(stderr)")
        }
        return stdout + "\n" + stderr
    }

    /// Abort an in-progress rebase or merge. If nothing's in progress, returns a no-op message.
    static func rebaseAbort(at path: URL) throws -> String {
        guard hasInProgressRebaseOrMerge(at: path) else {
            return "Nothing to abort."
        }
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
