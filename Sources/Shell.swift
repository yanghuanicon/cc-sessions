import Foundation

enum Shell {
    /// 同步执行命令并返回标准输出；超时或失败返回 nil。
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], env: [String: String]? = nil, timeout: TimeInterval = 10) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        if let env { process.environment = env }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        // 在后台读完输出，避免输出填满管道缓冲导致子进程卡住。
        var data = Data()
        let reading = DispatchGroup()
        DispatchQueue.global().async(group: reading) {
            data = out.fileHandleForReading.readDataToEndOfFile()
        }
        if reading.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// GUI 应用拿不到终端里的 PATH，claude 装在 nvm 目录下，只能借登录 shell 找一次。
    static let claudePath: String? = {
        for flags in ["-lc", "-lic"] {
            if let out = run("/bin/zsh", [flags, "command -v claude"], timeout: 8)?
                .split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespaces),
               out.hasPrefix("/") {
                return out
            }
        }
        return nil
    }()

    /// claude 是 node 脚本，PATH 里要带上它所在的 nvm bin 目录。
    static var claudeEnv: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let bin = claudePath.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        env["PATH"] = [bin, "/usr/local/bin", "/usr/bin", "/bin"].filter { !$0.isEmpty }.joined(separator: ":")
        return env
    }

    /// 批量查进程的 tty，返回 pid -> /dev/ttysNNN。
    static func ttys(for pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty,
              let out = run("/bin/ps", ["-o", "pid=,tty=", "-p", pids.map(String.init).joined(separator: ",")]) else { return [:] }
        var result: [Int32: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]), parts[1] != "??" else { continue }
            result[pid] = "/dev/" + parts[1]
        }
        return result
    }
}

enum Git {
    /// 直接读 .git/HEAD 拿当前分支，比起 git 进程轻得多；兼容 worktree 的 .git 文件。
    static func branch(at dir: String) -> String? {
        var url = URL(fileURLWithPath: dir)
        let fm = FileManager.default
        for _ in 0..<12 {
            let dotGit = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue,
                   let text = try? String(contentsOf: dotGit, encoding: .utf8),
                   let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") {
                    let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = URL(fileURLWithPath: target, relativeTo: url).standardizedFileURL
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst("ref: refs/heads/".count)) }
                return String(head.prefix(8))
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }
}
