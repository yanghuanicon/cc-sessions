import AppKit
import Combine

/// 面板的数据源：开着的会话、历史索引、搜索结果，以及跳转 / 恢复 / 改名等动作。
final class SessionStore: ObservableObject {
    @Published private(set) var live: [LiveSession] = []
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var indexing = true
    /// 搜索结果；nil 表示没在搜索。
    @Published private(set) var results: [HistoryEntry]?
    @Published private(set) var snippets: [String: String] = [:]
    @Published private(set) var liveMatches: Set<String>?
    @Published var notice: String?
    /// 每次打开面板加一，视图据此把焦点放回搜索框。
    @Published var focusToken = 0

    var panelOpen = false { didSet { if panelOpen { refreshLive(); refreshHistory(); refreshBackground() } } }
    var onBadgeChange: ((Int) -> Void)?
    var closePanel: (() -> Void)?

    private let indexer = HistoryIndexer()
    private let indexQueue = DispatchQueue(label: "cc-sessions.index", qos: .utility)
    private let liveQueue = DispatchQueue(label: "cc-sessions.live", qos: .userInitiated)
    private let registryDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions")
    private var backgroundSessions: [LiveSession] = []
    private var registrySessions: [LiveSession] = []
    private var titles: [String: HistoryEntry] = [:]
    private var tickCount = 0
    private var searchGeneration = 0
    private var noticeTimer: Timer?

    var waitingCount: Int { live.filter { $0.state == .waiting }.count }

    func start() {
        refreshLive()
        refreshHistory()
        refreshBackground()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: - 刷新

    private func tick() {
        tickCount += 1
        // 面板开着时刷得勤；收起时只为菜单栏数字低频刷新。
        if panelOpen || tickCount % 5 == 0 { refreshLive() }
        if panelOpen && tickCount % 3 == 0 { refreshHistory() }
        if tickCount % 15 == 0 { refreshBackground() }
    }

    func refreshLive() {
        liveQueue.async { [weak self] in
            guard let self else { return }
            let sessions = self.readRegistry()
            DispatchQueue.main.async {
                self.registrySessions = sessions
                self.mergeLive()
            }
        }
    }

    func refreshHistory() {
        indexQueue.async { [weak self] in
            guard let self else { return }
            let list = self.indexer.refresh()
            DispatchQueue.main.async {
                self.history = list
                self.titles = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                self.indexing = false
                self.mergeLive()
            }
        }
    }

    /// 后台会话不在 ~/.claude/sessions 登记表里，只能靠 `claude agents --json`；它要起 node，所以低频调用。
    func refreshBackground() {
        liveQueue.async { [weak self] in
            guard let self, let claude = Shell.claudePath,
                  let out = Shell.run(claude, ["agents", "--json"], env: Shell.claudeEnv, timeout: 15),
                  let data = out.data(using: .utf8),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            let sessions: [LiveSession] = items.compactMap { item in
                guard item["kind"] as? String == "background",
                      let sessionId = item["sessionId"] as? String,
                      let shortId = item["id"] as? String else { return nil }
                let rawState = (item["state"] as? String ?? item["status"] as? String ?? "").lowercased()
                let state: LiveState = rawState == "blocked" || rawState.contains("wait") ? .waiting
                    : (rawState == "idle" || rawState == "done" ? .idle : .busy)
                let cwd = item["cwd"] as? String ?? ""
                let started = (item["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
                return LiveSession(id: sessionId, pid: nil, name: item["name"] as? String ?? String(shortId),
                                   cwd: cwd, state: state, host: .background(shortId: shortId),
                                   updatedAt: started, branch: Git.branch(at: cwd))
            }
            DispatchQueue.main.async {
                self.backgroundSessions = sessions
                self.mergeLive()
            }
        }
    }

    private func readRegistry() -> [LiveSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: registryDir, includingPropertiesForKeys: nil)) ?? []
        var raw: [(pid: Int32, obj: [String: Any])] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value ?? Int32(obj["pid"] as? String ?? ""),
                  Self.isAlive(pid) else { continue }
            raw.append((pid, obj))
        }
        let ttys = Shell.ttys(for: raw.map(\.pid))
        return raw.compactMap { pid, obj in
            guard let sessionId = obj["sessionId"] as? String else { return nil }
            let cwd = obj["cwd"] as? String ?? ""
            let entry = obj["entrypoint"] as? String ?? "cli"
            let host: SessionHost = entry == "claude-desktop" ? .desktop : (entry.hasPrefix("sdk") ? .sdk : .terminal(tty: ttys[pid]))
            let status = (obj["status"] as? String ?? "").lowercased()
            let state: LiveState = status == "busy" ? .busy : (status == "idle" ? .idle : .waiting)
            let updated = (obj["updatedAt"] as? NSNumber)?.doubleValue ?? Double(obj["updatedAt"] as? String ?? "") ?? 0
            var name = obj["name"] as? String ?? ""
            // 系统派生的名字（claude-31 这种）没信息量，交给历史标题兜底。
            if obj["nameSource"] as? String != "user" { name = "" }
            return LiveSession(id: sessionId, pid: pid, name: name, cwd: cwd, state: state, host: host,
                               updatedAt: Date(timeIntervalSince1970: updated / 1000), branch: Git.branch(at: cwd),
                               waitingFor: obj["waitingFor"] as? String)
        }
    }

    private func mergeLive() {
        var seen = Set<String>()
        let merged = (registrySessions + backgroundSessions).compactMap { session -> LiveSession? in
            guard seen.insert(session.id).inserted else { return nil }
            var s = session
            if s.name.isEmpty {
                s.name = titles[s.id]?.title ?? Format.shortDir(s.cwd)
            }
            return s
        }
        live = merged.sorted { ($0.state.rawValue, -$0.updatedAt.timeIntervalSince1970) < ($1.state.rawValue, -$1.updatedAt.timeIntervalSince1970) }
        onBadgeChange?(waitingCount)
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: - 搜索

    func search(_ query: String) {
        searchGeneration += 1
        let generation = searchGeneration
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            results = nil; snippets = [:]; liveMatches = nil
            return
        }
        let pool = history
        let liveIds = Set(live.map(\.id))
        let liveInfo = live.map { ($0.id, "\($0.name) \($0.cwd) \($0.branch ?? "")") }
        indexQueue.async { [weak self] in
            var found: [HistoryEntry] = []
            var snippets: [String: String] = [:]
            for entry in pool {
                let head = "\(entry.title) \(entry.cwd) \(entry.branch)"
                if head.range(of: q, options: .caseInsensitive) != nil {
                    found.append(entry)
                } else if let range = entry.searchText.range(of: q, options: .caseInsensitive) {
                    found.append(entry)
                    snippets[entry.id] = Self.snippet(entry.searchText, around: range)
                }
            }
            var liveHit = Set(liveInfo.filter { $0.1.range(of: q, options: .caseInsensitive) != nil }.map(\.0))
            liveHit.formUnion(found.map(\.id).filter { liveIds.contains($0) })
            DispatchQueue.main.async {
                guard let self, generation == self.searchGeneration else { return }
                self.results = Array(found.filter { !liveIds.contains($0.id) }.prefix(60))
                self.snippets = snippets
                self.liveMatches = liveHit
            }
        }
    }

    private static func snippet(_ text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -18, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 30, limitedBy: text.endIndex) ?? text.endIndex
        let piece = text[start..<end].split(whereSeparator: \.isNewline).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + piece + (end < text.endIndex ? "…" : "")
    }

    // MARK: - 动作

    func open(_ session: LiveSession) {
        switch session.host {
        case .terminal(let tty):
            guard let tty else { return say("这个会话没有终端（tty），无法跳转") }
            switch ITerm.focus(tty: tty) {
            case .ok: closePanel?()
            case .notFound: say("这个会话不在 iTerm 里（\(tty)），可能开在 IDEA 或其他终端中")
            case .failed(let message): say(message)
            }
        case .background(let shortId):
            runInNewTab("claude attach \(shortId)")
        case .desktop:
            say("这个会话开在 Claude 桌面端里，请到桌面端查看")
        case .sdk:
            say("这个会话由程序启动（如飞书机器人），没有终端窗口")
        }
    }

    /// 历史会话：还开着就直接跳过去，否则新开标签页在原目录恢复。
    func open(_ entry: HistoryEntry) {
        if let session = live.first(where: { $0.id == entry.id }) { return open(session) }
        guard !entry.cwd.isEmpty else { return say("这个会话没有记录工作目录，无法恢复") }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: entry.cwd, isDirectory: &isDir) || !isDir.boolValue {
            closePanel?()
            let alert = NSAlert()
            alert.messageText = "原目录已不存在"
            alert.informativeText = "\(Format.tildePath(entry.cwd))\n\nclaude --resume 需要在原目录下执行才能找到这个会话。要在原路径重建一个空目录再恢复吗？聊天记录都在，只是原来的文件没了。"
            alert.addButton(withTitle: "重建目录并恢复")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try FileManager.default.createDirectory(atPath: entry.cwd, withIntermediateDirectories: true)
            } catch {
                return say("重建目录失败：\(error.localizedDescription)")
            }
        }
        runInNewTab(resumeCommand(entry))
    }

    func resumeCommand(_ entry: HistoryEntry) -> String {
        "cd \(Format.shellQuote(entry.cwd)) && claude --resume \(entry.id)"
    }

    func copyResume(_ entry: HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resumeCommand(entry), forType: .string)
        say("已复制恢复命令")
    }

    func copyResume(_ session: LiveSession) {
        let command: String
        if case .background(let shortId) = session.host {
            command = "claude attach \(shortId)"
        } else {
            command = "cd \(Format.shellQuote(session.cwd)) && claude --resume \(session.id)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        say("已复制：\(command)")
    }

    func reveal(_ path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return say("目录不存在：\(Format.tildePath(path))") }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// 改名。开着的会话每轮都会把内存里的名字写回记录，只改文件会被覆盖，所以要让会话自己执行 /rename。
    func rename(id: String, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let session = live.first(where: { $0.id == id }) {
            switch session.host {
            case .terminal(let tty?) where session.state == .idle:
                switch ITerm.send(text: "/rename \(name)", tty: tty) {
                case .ok:
                    if let i = live.firstIndex(where: { $0.id == id }) { live[i].name = name }
                    say("已向 iTerm 发送 /rename \(name)")
                case .notFound: say("这个会话不在 iTerm 里，无法代为改名，请在它所在的终端里执行 /rename")
                case .failed(let message): say(message)
                }
            case .terminal:
                // 正在运行或正在等你回答时往里输入，会被当成对问题的回答。
                say(session.state == .busy ? "会话正在运行，等它空闲后再改名" : "会话正在等你回答，先处理完再改名")
            case .background(let shortId):
                say("后台会话请 claude attach \(shortId) 后执行 /rename")
            case .desktop, .sdk:
                say("这个会话不在终端里，请在它所在的应用里改名")
            }
            return
        }
        guard let entry = history.first(where: { $0.id == id }) else { return }
        indexQueue.async { [weak self] in
            let ok = self?.indexer.appendTitle(name, sessionId: entry.id, path: entry.path) ?? false
            DispatchQueue.main.async {
                self?.say(ok ? "已改名为「\(name)」" : "改名失败：无法写入会话记录")
                self?.refreshHistory()
            }
        }
    }

    private func runInNewTab(_ command: String) {
        switch ITerm.openTab(command: command) {
        case .ok, .notFound: closePanel?()
        case .failed(let message): say(message)
        }
    }

    func say(_ text: String) {
        notice = text
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in self?.notice = nil }
    }
}

extension SessionStore {
    /// `cc-sessions --dump`：不启动界面，把读到的会话打印出来，用于排查数据问题。
    func dump() {
        let live = readRegistry()
        print("== 开着的会话（登记表）\(live.count) 个")
        for s in live { print("  [\(s.state)] \(s.name.isEmpty ? "(无名)" : s.name) | \(Format.tildePath(s.cwd)) | ⎇ \(s.branch ?? "-") | \(s.host)") }
        print("== claude 路径：\(Shell.claudePath ?? "未找到")")
        refreshBackground()
        liveQueue.sync {}
        Thread.sleep(forTimeInterval: 0.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        print("== 后台会话 \(backgroundSessions.count) 个")
        for s in backgroundSessions { print("  [\(s.state)] \(s.name) | \(Format.tildePath(s.cwd)) | \(s.host)") }
        let list = indexer.refresh()
        print("== 历史会话 \(list.count) 个，最近 5 个：")
        for h in list.prefix(5) { print("  \(h.title) | \(Format.tildePath(h.cwd)) | ⎇ \(h.branch) | \(h.turns) 轮") }
    }
}
