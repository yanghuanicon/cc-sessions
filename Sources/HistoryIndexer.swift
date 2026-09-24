import Foundation

/// 解析 ~/.claude/projects 下的会话记录并维护索引。
/// jsonl 只会追加，所以每个文件记住解析到的字节位置，下次只读新增部分；索引缓存到磁盘，重启不必全量重扫。
final class HistoryIndexer {
    private let projectsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    private let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("cc-sessions")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index-v2.json")
    }()
    /// 超过这个长度的行基本是图片或大段工具输出，跳过不解析。
    private let maxLineBytes = 512 * 1024
    private let searchTextLimit = 300_000
    private let chunkBytes = 4 * 1024 * 1024

    private var entries: [String: HistoryEntry] = [:]
    private var dirty = false

    init() {
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = Dictionary(uniqueKeysWithValues: cached.map { ($0.path, $0) })
        }
    }

    /// 扫一遍目录，解析新增内容，返回按最后活动时间倒序的会话列表。
    func refresh() -> [HistoryEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var seen = Set<String>()
        let projectDirs = (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? []
        for dir in projectDirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let path = file.path
                seen.insert(path)
                guard let values = try? file.resourceValues(forKeys: Set(keys)),
                      let modified = values.contentModificationDate,
                      let size = values.fileSize.map(UInt64.init) else { continue }
                var entry = entries[path] ?? HistoryEntry(id: file.deletingPathExtension().lastPathComponent, path: path)
                if entry.size == size && entry.modifiedAt == modified { continue }
                if size < entry.offset {
                    entry = HistoryEntry(id: entry.id, path: path)
                }
                parse(&entry, upTo: size)
                entry.size = size
                entry.modifiedAt = modified
                entries[path] = entry
                dirty = true
            }
        }
        for path in entries.keys where !seen.contains(path) {
            entries[path] = nil
            dirty = true
        }
        if dirty { save() }
        return entries.values.filter { $0.turns > 0 }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// 追加一条 custom-title 记录来改历史会话的名字；只追加，不改动已有内容。
    func appendTitle(_ title: String, sessionId: String, path: String) -> Bool {
        let record: [String: Any] = ["type": "custom-title", "customTitle": title, "sessionId": sessionId]
        guard var line = try? JSONSerialization.data(withJSONObject: record),
              let handle = FileHandle(forUpdatingAtPath: path) else { return false }
        defer { try? handle.close() }
        let end = handle.seekToEndOfFile()
        if end > 0 {
            handle.seek(toFileOffset: end - 1)
            if handle.readData(ofLength: 1) != Data([0x0A]) { line.insert(0x0A, at: 0) }
        }
        line.append(0x0A)
        handle.seekToEndOfFile()
        handle.write(line)
        return true
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(entries.values)) else { return }
        try? data.write(to: cacheURL, options: .atomic)
        dirty = false
    }

    private func parse(_ entry: inout HistoryEntry, upTo size: UInt64) {
        guard let handle = FileHandle(forReadingAtPath: entry.path) else { return }
        defer { try? handle.close() }
        handle.seek(toFileOffset: entry.offset)
        var pending = Data()
        // pending 第一个字节在文件里的位置。
        var pendingStart = entry.offset
        var searchParts: [String] = []
        while pendingStart + UInt64(pending.count) < size {
            let chunk = handle.readData(ofLength: chunkBytes)
            if chunk.isEmpty { break }
            pending.append(chunk)
            // 只处理完整的行，最后半行留到下次（文件可能正在被写）。
            guard let lastNewline = pending.lastIndex(of: 0x0A) else {
                // 超长的行（图片等）不需要内容，丢掉已读部分，只保持位置正确。
                if pending.count > maxLineBytes {
                    pendingStart += UInt64(pending.count)
                    pending.removeAll(keepingCapacity: true)
                }
                continue
            }
            let complete = pending[pending.startIndex...lastNewline]
            // JSONSerialization 产生大量临时对象，按块及时释放，否则首次建索引时内存会冲到几百 MB。
            autoreleasepool {
                for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    handleLine(Data(line), into: &entry, search: &searchParts)
                }
            }
            pendingStart += UInt64(complete.count)
            entry.offset = pendingStart
            pending = Data(pending[(lastNewline + 1)...])
        }
        if !searchParts.isEmpty {
            var text = entry.searchText + "\n" + searchParts.joined(separator: "\n")
            if text.count > searchTextLimit { text = String(text.suffix(searchTextLimit)) }
            entry.searchText = text
        }
    }

    private func handleLine(_ line: Data, into entry: inout HistoryEntry, search: inout [String]) {
        guard line.count <= maxLineBytes,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return }
        if entry.cwd.isEmpty, let cwd = obj["cwd"] as? String { entry.cwd = cwd }
        // 非 git 目录或 detached 时记录的是 HEAD，不能覆盖掉真实分支名。
        if let branch = obj["gitBranch"] as? String, !branch.isEmpty, branch != "HEAD" { entry.branch = branch }
        switch type {
        case "custom-title":
            entry.customTitle = obj["customTitle"] as? String ?? entry.customTitle
        case "ai-title":
            entry.aiTitle = obj["aiTitle"] as? String ?? entry.aiTitle
        case "user":
            guard let text = Self.userText(obj) else { return }
            entry.turns += 1
            if entry.firstPrompt.isEmpty { entry.firstPrompt = Self.oneLine(text) }
            search.append(text)
        case "assistant":
            guard obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { return }
            let text = blocks.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            entry.lastReply = String(Self.oneLine(text).prefix(200))
            search.append(text)
        default:
            return
        }
    }

    /// 只保留用户真正输入的话：去掉系统注入、工具结果、斜杠命令回显。
    private static func userText(_ obj: [String: Any]) -> String? {
        guard obj["isMeta"] as? Bool != true, obj["isSidechain"] as? Bool != true,
              let message = obj["message"] as? [String: Any] else { return nil }
        var text = ""
        if let s = message["content"] as? String {
            text = s
        } else if let blocks = message["content"] as? [[String: Any]] {
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.hasPrefix("<") || text.hasPrefix("Caveat:") { return nil }
        return text
    }

    private static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
